# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.DataLayer do
  @moduledoc """
  Owns Account-scoped PostgreSQL transactions.

  Each helper pins transaction-local Account settings before running caller work, while Ash
  applies actor and tenant filters above forced row-level security. Account selection comes from
  identity or trusted configuration. Keep state, audit, idempotency, and enqueue effects in one
  callback; do not place irreversible provider calls inside it.
  """

  alias MemHouse.Accounts.Account
  alias MemHouse.Actor
  alias MemHouse.Repo

  require Ash.Query

  @doc """
  Looks up which Account owns a raw message, by message id.

  This exists to break a chicken-and-egg problem: opening an Account-scoped
  transaction requires knowing the Account, and an internal caller handed only a
  message id does not yet know it. So this one read deliberately runs *outside*
  such a transaction, before the Account settings exist.

  It is raw SQL rather than an Ash query for the same reason — there is no actor
  to authorize it with yet. That is why it lives in this infrastructure module,
  why the statement is a fixed string with the id passed as a bound parameter
  rather than interpolated, and why it reads one column and writes nothing. No
  externally authenticated request reaches it: an HTTP caller's Account already
  comes from its credential.

  Returns the Account key. Raises `Ecto.NoResultsError` when no such message
  exists, which is the correct outcome — a caller that cannot identify the
  Account must not proceed.
  """
  # sobelow_skip ["SQL.Query"]
  def message_account_key!(message_id) do
    sql = """
    SELECT account.key
    FROM messages AS message
    JOIN accounts AS account ON account.id = message.account_id
    WHERE message.id = $1
    """

    case Ecto.Adapters.SQL.query!(Repo, sql, [Ecto.UUID.dump!(message_id)]) do
      %{rows: [[account_key]]} -> account_key
      %{rows: []} -> raise Ecto.NoResultsError, queryable: sql
    end
  end

  @doc """
  Runs `fun` in a transaction scoped to the Account with this operator-visible key,
  creating that Account if it does not exist yet.

  This is the internal path — background extraction, the evaluation harness,
  migration compatibility — where the caller identifies an Account by its key
  rather than by an authenticated credential. It is not reachable from an HTTP
  request, and it must stay that way: letting a caller name its own Account key
  would put Account selection back into request input.

  `actor_overrides` is merged into the actor handed to `fun`, and is how the
  pipeline asks for `role: :system` and `pipeline?: true`. Those flags unlock
  writing knowledge and erasing rows, so pass them only from internal code.

  `fun` receives the Account record and the actor, and its return value becomes
  this function's return value. The Account row is upserted before the callback
  runs, under a bootstrap actor that can only match the very key already pinned
  for this transaction. No display name is accepted here: one is derived from
  the key by replacing dashes and underscores with spaces.

  Never returns an error tuple. A rolled-back transaction is re-raised here as a
  `RuntimeError` naming the inspected cause, and an exception raised inside
  `fun` propagates unchanged; either way everything the callback wrote is rolled
  back with it.
  """
  def with_account_key(account_key, actor_overrides \\ [], fun)
      when is_binary(account_key) and is_function(fun, 2) do
    case Repo.transaction(fn ->
           set_account_key!(account_key)

           account =
             Account
             |> Ash.Changeset.for_create(:ensure, %{
               key: account_key,
               name: account_name(account_key)
             })
             |> Ash.create!(actor: Actor.bootstrap(account_key))

           set_account_id!(account.id)
           actor = Actor.for_account(account, actor_overrides)
           fun.(account, actor)
         end) do
      {:ok, result} -> result
      {:error, error} -> raise "Account-scoped transaction failed: #{inspect(error)}"
    end
  end

  @doc """
  Runs `fun` in a transaction scoped to this install's single community Account,
  provisioning that Account if it is not there yet.

  The community build hosts exactly one Account, whose key and name come from
  configuration rather than from a caller. This is the first-run path: it claims
  the community edition slot, which a partial unique index in the database
  allows only once, so a second attempt to provision a different Account fails
  at the database rather than quietly creating a second tenant.

  `fun` receives the Account and a `:system`-role actor and its result is
  returned. Raises when provisioning or the callback fails. Use the
  existing-Account variant for anything that must not create an Account as a
  side effect.
  """
  def with_free_account(fun) when is_function(fun, 2) do
    identity_config = Application.fetch_env!(:memhouse, :identity)
    account_key = Keyword.fetch!(identity_config, :account_key)
    account_name = Keyword.fetch!(identity_config, :account_name)

    case Repo.transaction(fn ->
           set_account_key!(account_key)

           account =
             Account
             |> Ash.Changeset.for_create(:provision_free, %{
               key: account_key,
               name: account_name
             })
             |> Ash.create!(actor: Actor.bootstrap(account_key))

           set_account_id!(account.id)
           actor = Actor.for_account(account, role: :system)
           fun.(account, actor)
         end) do
      {:ok, result} -> result
      {:error, error} -> raise "Free Account transaction failed: #{inspect(error)}"
    end
  end

  @doc """
  Runs `fun` against the community Account, requiring that it already exists.

  The non-provisioning counterpart: operator tooling, archive export, and
  administrative commands need the configured Account but must never bring one
  into existence as a side effect of being run against the wrong database. The
  lookup matches both the configured key and the community edition slot, so an
  Account that happens to share the key but was never provisioned as the
  community one does not answer here. The callback may still write; what is
  ruled out is creating the Account.

  `fun` receives the Account and a `:system`-role actor. Raises
  `Ecto.NoResultsError` when the Account is absent, which is the signal that the
  install has not been provisioned yet.
  """
  def with_existing_free_account(fun) when is_function(fun, 2) do
    identity_config = Application.fetch_env!(:memhouse, :identity)
    account_key = Keyword.fetch!(identity_config, :account_key)

    case Repo.transaction(fn ->
           set_account_key!(account_key)
           bootstrap_actor = Actor.bootstrap(account_key)

           account =
             Account
             |> Ash.Query.filter(key == ^account_key and edition_slot == "community-free")
             |> Ash.read_one!(actor: bootstrap_actor)

           if is_nil(account), do: raise(Ecto.NoResultsError, queryable: Account)

           set_account_id!(account.id)
           actor = Actor.for_account(account, role: :system)
           fun.(account, actor)
         end) do
      {:ok, result} -> result
      {:error, %Ecto.NoResultsError{} = error} -> raise error
      {:error, error} -> raise "Free Account lookup failed: #{inspect(error)}"
    end
  end

  @doc """
  Runs `fun` in a transaction scoped to an Account already known by id.

  The path taken by queued work and by internal callers that resolved the
  Account earlier: a job row carries the Account id, so re-deriving it from the
  message would be wasted work. Only the id setting is installed, not the key —
  the key setting exists solely for bootstrapping an Account that has no id yet.

  `actor_overrides` is merged into the actor handed to `fun`; queued pipeline
  work passes `role: :system, pipeline?: true` here. The Account row is loaded
  with an internal actor built for that id, so the callback receives a real
  Account record rather than just the id it was given.

  Raises when the transaction fails. An id that matches no Account also raises,
  but not gracefully: this helper expects ids that came from the system itself,
  never from caller input.
  """
  def with_account_id(account_id, actor_overrides \\ [], fun)
      when is_binary(account_id) and is_function(fun, 2) do
    case Repo.transaction(fn ->
           set_account_id!(account_id)

           bootstrap_actor = %{
             account_id: account_id,
             account_key: nil,
             role: :system,
             scope_ids: :all,
             pipeline?: false
           }

           account =
             Account
             |> Ash.Query.filter(id == ^account_id)
             |> Ash.read_one!(actor: bootstrap_actor)

           actor = Actor.for_account(account, actor_overrides)
           fun.(account, actor)
         end) do
      {:ok, result} -> result
      {:error, error} -> raise "Account-scoped transaction failed: #{inspect(error)}"
    end
  end

  @doc """
  Runs `fun` in a transaction scoped to an already-authenticated caller's Account.

  This is the request path. The actor arrives fully resolved from
  authentication — its Account, peer, credential kind, and per-scope roles were
  all decided before this call — and it is passed through to `fun` untouched.
  Nothing here widens it, which is the point: an HTTP request must act with
  exactly the authority its credential resolved to.

  The Account row is read with that same caller actor, so an actor pointing at
  an Account its policies do not permit gets nothing back rather than a
  privileged read.

  Raises when the transaction fails.
  """
  def with_actor(%Actor{account_id: account_id} = actor, fun)
      when is_binary(account_id) and is_function(fun, 2) do
    case Repo.transaction(fn ->
           set_account_id!(account_id)

           account =
             Account
             |> Ash.Query.filter(id == ^account_id)
             |> Ash.read_one!(actor: actor)

           fun.(account, actor)
         end) do
      {:ok, result} -> result
      {:error, error} -> raise "Identity-scoped transaction failed: #{inspect(error)}"
    end
  end

  @doc """
  Runs `fun` in a transaction carrying nothing but this Account's database settings.

  The other helpers here resolve an Account row and build an actor because their callers are
  about to perform domain work. This one exists for the opposite case: a caller that already
  holds an actor and needs only the transaction-local settings the row-level-security policies
  read.

  Two kinds of caller need exactly that. The model layer uses it to resolve a role's stored
  configuration and to append a usage record, because both run during a provider call and a
  provider call must not happen inside somebody else's transaction. Edge metering uses it
  because it runs *after* the request's transactions have already ended — in a before-send
  callback, or on an operator page — so the connection it lands on has no Account declared
  and every policy would deny.

  ## Why external calls must not hold a transaction

  A transaction owns a pooled database connection for its whole duration. A model call can run
  for minutes across repair attempts, and holding a connection for that long exceeds
  DBConnection's checkout-ownership timeout: the connection is forcibly closed mid-transaction
  and every write in it is lost, including the record of a provider call that already happened
  and was already billed. So the pipeline opens a short transaction to read, closes it, calls
  the model, then opens another short transaction to write — and the two database touches
  inside the model call scope themselves through here.

  ## Nesting

  A transaction is opened unconditionally rather than only when none is already open. Nested,
  it becomes a savepoint and re-installs the same Account, which changes nothing. Branching on
  `Repo.in_transaction?/0` would be cheaper and worse: under the SQL sandbox every test already
  runs inside a transaction, so the branch taken in production would be the one never
  exercised by a test.

  `account_id` must be the Account already in force whenever a transaction is open, since the
  setting installed here survives to the end of the enclosing transaction.

  `fun` takes no arguments and its return value is returned. Raises when the transaction rolls
  back, matching the other helpers here.
  """
  def in_account_transaction(account_id, fun)
      when is_binary(account_id) and is_function(fun, 0) do
    case Repo.transaction(fn ->
           set_account_id!(account_id)
           fun.()
         end) do
      {:ok, result} -> result
      {:error, error} -> raise "Account-scoped transaction failed: #{inspect(error)}"
    end
  end

  @doc """
  Declares an Account to the transaction that is already open on this connection.

  The helpers above all *open* a transaction. This one does not: it is for code that finds
  itself inside a transaction somebody else opened — an Ash action's own — and needs the
  row-level-security settings installed into it before the statement is issued. Background
  jobs are the case that forced this to exist. A job runs with no request behind it, so the
  connection its first query lands on carries no Account at all, and every policy on a tenant
  table then denies: a read comes back empty and a write is refused.

  ## An existing declaration always wins

  The value is only installed when none is present, which is what makes this safe to call
  from an action that may or may not be nested inside an Account-scoped transaction. Calling
  it can therefore never switch, widen, or reinstate tenancy: an outer Account stays in
  force, and if this transaction's work belongs to a different Account, the policies refuse
  it loudly instead of quietly serving the wrong tenant's rows.

  The setting is transaction-local, so it is discarded when the enclosing transaction ends
  and cannot follow a pooled connection to its next user.

  Raises when no transaction is open, because `set_config` with the transaction-local flag
  would otherwise apply to the implicit single-statement transaction of the call itself and
  vanish before the caller's next query — a silent no-op that would look exactly like a
  successful declaration.
  """
  def declare_account!(account_id) when is_binary(account_id) do
    unless Repo.in_transaction?() do
      raise "MemHouse.DataLayer.declare_account!/1 requires an open transaction: " <>
              "a transaction-local setting installed outside one is discarded immediately"
    end

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      SELECT set_config(
               'memhouse.account_id',
               COALESCE(NULLIF(current_setting('memhouse.account_id', true), ''), $1),
               true
             )
      """,
      [account_id]
    )

    :ok
  end

  # Restores a verified archive into a fresh Account, in one transaction.
  #
  # Kept out of the public documentation because nothing outside the archive
  # importer may call it: the actor it builds carries the `:system` role, sees
  # every scope, and has the pipeline flag set, which together unlock the
  # private restore actions that write ids, timestamps, and lifecycle history
  # verbatim. Both Account settings are installed because a restore touches the
  # Accounts row itself as well as its tenanted tables.
  #
  # The whole restore is one transaction on purpose: a partially imported
  # Account would carry an audit chain that no longer verifies. Validation of
  # the archive — checksums, counts, blob hashes, the audit chain — happens
  # before this is called, not inside it.
  @doc false
  def with_portability_import(account_id, account_key, fun)
      when is_binary(account_id) and is_binary(account_key) and is_function(fun, 1) do
    case Repo.transaction(fn ->
           set_account_key!(account_key)
           set_account_id!(account_id)

           actor = %Actor{
             account_id: account_id,
             account_key: account_key,
             identity_kind: :system,
             assurance: :high,
             role: :system,
             scope_ids: :all,
             scope_roles: %{},
             pipeline?: true
           }

           fun.(actor)
         end) do
      {:ok, result} -> result
      {:error, error} -> raise "Portability import transaction failed: #{inspect(error)}"
    end
  end

  # The two settings the database's row-level security policies read. The third
  # argument to `set_config` is what makes them transaction-local: they are
  # discarded at commit or rollback, so a pooled connection can never carry one
  # Account's setting into the next caller's work.
  #
  # The key setting only matters while bootstrapping — the Accounts row can be
  # matched by key before its id is known. Every other table is matched by id.
  defp set_account_key!(account_key) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT set_config('memhouse.account_key', $1, true)",
      [account_key]
    )
  end

  defp set_account_id!(account_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT set_config('memhouse.account_id', $1, true)",
      [account_id]
    )
  end

  # Display name for an Account created by key alone: the key with separators
  # turned into spaces. A cosmetic default, editable afterwards.
  defp account_name(account_key), do: String.replace(account_key, ~r/[-_]+/, " ")
end
