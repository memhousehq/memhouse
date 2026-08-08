# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.Preparations.DeclareAccount do
  @moduledoc """
  Declares the queried Account to the database before a pipeline run is read.

  Job runners read a pipeline run before application code can declare its Account on the pooled
  connection. Without a declaration, RLS hides the row and the runner cancels valid work.

  This preparation installs the declaration in the read action's transaction before the query.

  ## Requirements on the action

  The action must set `transaction? true`; otherwise the transaction-local declaration is lost.

  Reads that already run inside an Account-scoped transaction — the browser console's queue
  page, for example — are unaffected: an existing declaration is never overwritten.
  """

  use Ash.Resource.Preparation

  alias MemHouse.DataLayer

  @doc """
  Adds a before-action hook that declares the query's tenant Account.

  The hook runs inside the read action's transaction and returns the query unchanged. Raises
  when the query carries no tenant, which on a tenant-scoped resource means the caller built
  it wrong; declaring nothing there would turn a caller's mistake into an empty result set.
  """
  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.before_action(query, fn query ->
      case query.tenant do
        tenant when is_binary(tenant) ->
          DataLayer.declare_account!(tenant)
          query

        other ->
          raise "pipeline run read requires a tenant Account, got: #{inspect(other)}"
      end
    end)
  end
end

defmodule MemHouse.Pipeline.Changes.DeclareAccount do
  @moduledoc """
  Declares the run's own Account to the database before a pipeline run is written.

  Background outcome writes also arrive without an Account declaration. RLS then matches no row,
  producing a stale-record error and losing the outcome.

  The declaration uses the loaded row's Account, which is the value RLS compares.

  ## Requirements on the action

  The action must be transactional, which every update here is. The declaration is
  transaction-local and the helper raises if no transaction is open, so a future action that
  turns transactions off will fail loudly rather than silently reintroduce this bug.
  """

  use Ash.Resource.Change

  alias MemHouse.DataLayer

  @doc """
  Adds a before-action hook that declares the updated row's Account.

  The hook runs inside the action's transaction, immediately before the row is written, and
  returns the changeset unchanged.
  """
  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      DataLayer.declare_account!(changeset.data.account_id)
      changeset
    end)
  end
end
