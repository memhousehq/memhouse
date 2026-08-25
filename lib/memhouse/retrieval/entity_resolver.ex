# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.EntityResolver do
  @moduledoc """
  Rebuilds the private entity-and-mention index from active statements.

  These rows are rebuildable caches: missing data may reduce recall but never correctness. Never
  expose entity ids, canonical names, aliases, or surface forms; retrieval returns authorized
  statements only.

  Resolution tries case-insensitive aliases, then uses vector similarity to select a candidate
  for model confirmation. It uses short read and write transactions around an in-memory/model
  phase; never hold a database connection during model calls. Failures skip a form without
  blocking rebuild.
  """

  alias MemHouse.Clock
  alias MemHouse.Context.{ProjectionInputs, ProjectionLock}
  alias MemHouse.DataLayer
  alias MemHouse.Knowledge.{Entity, EntityMention}
  alias MemHouse.Memory.Visibility
  alias MemHouse.Model.{Embedding, Gateway}
  alias MemHouse.Retrieval.{LexicalQueryAnalyzer, Vector}

  require Ash.Query

  # Cosine similarity selects candidates only. It measures relatedness, so even a high score
  # cannot prove identity. False merges cross identities; duplicates only reduce recall.
  @reject_threshold 0.72

  # Horizontal space is deliberate. `\s` joins names across sentence and line boundaries.
  @mention_regex ~r/\b(?:[A-Z][[:alnum:]@._-]*)(?:[ \t]+[A-Z][[:alnum:]@._-]*){0,3}\b/u
  @email_regex ~r/\b[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}\b/u
  @timezone_abbreviations MapSet.new(
                            ~w(UTC GMT CET CEST EET EEST EST EDT CST CDT MST MDT PST PDT)
                          )
  @sentence_noise MapSet.new(
                    ~w(also because but can could did do does finally first here how however if in it keep meanwhile next no now on or please she so still then there these they this those thus today tomorrow tonight we what when where which who why wow yesterday you your)
                  )
  @non_person_names MapSet.new(
                      ~w(January February March April May June July August September October November December Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
                    )

  @doc """
  Rebuilds the entity index for one scope from scratch.

  Deletes every existing mention in the scope, re-derives mentions from the
  scope's approved statements, and then removes any entity in the Account left
  with no mentions at all. Rebuilding rather than patching is what makes it
  replay-safe: running it twice gives the same result, and it is the correct
  response to an erasure, an import, or a suspected stale index.

  Every durable change happens in the final transaction, so a failure anywhere
  — including inside the embedder or the reasoning model — leaves the previous
  index untouched rather than half-cleared. Clearing and re-deriving stay in
  that one transaction together, in that order; any other order would leave
  duplicate mentions for statements that are resolved again.

  Expiry is also a fail-closed commit boundary. If a selected statement expires
  during model work or the final write, the rebuild returns a stale-snapshot
  error and rolls back instead of persisting a derived mention from an already
  invisible source. Callers may retry from a fresh source snapshot.

  Note the asymmetry: mentions are cleared per scope, but orphan entities are
  pruned Account-wide, because an entity is shared across scopes and only the
  full mention set can show it has become unreferenced. Final Account-wide
  entity writes serialize and revalidate the entity snapshot so a rebuild in
  one scope cannot overwrite newer shared state from another.

  Returns `{:ok, %{statements: n, mentions: n}}`, or
  `{:error, :stale_projection_snapshot}` when a projection-shaping input changes
  during model work. Raises if a read or write fails; individual embedding or
  model failures do not raise, they just leave that surface form unresolved.
  """
  def rebuild_scope(account_id, scope_id) do
    {drafts, statements, actor, input_generation, entity_signature, valid_until} =
      read_scope!(account_id, scope_id)

    {drafts, mentions} = resolve_statements(drafts, statements, account_id, actor)

    case write_index!(
           drafts,
           mentions,
           account_id,
           scope_id,
           input_generation,
           entity_signature,
           valid_until
         ) do
      :ok -> {:ok, %{statements: length(statements), mentions: length(mentions)}}
      {:error, :stale_projection_snapshot} = error -> error
    end
  end

  # Phase one. Reads everything the resolution loop needs, so that loop can run
  # with no transaction open: the Account's entities as mutable drafts, and the
  # scope's statements.
  #
  # Only approved, undeleted, unexpired statements feed the index. Proposals under review,
  # erased statements, and rows past their expiry must leave no trace of their names here,
  # even before the lifecycle sweep rewrites the state.
  #
  # The actor is returned too, because phase two needs one to call the model
  # layer. That is safe: an actor is a plain struct naming the Account and the
  # authorization role, so it stays valid after the transaction that produced
  # it ends, and the model layer scopes its own configuration read and usage
  # write.
  defp read_scope!(account_id, scope_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        input_generation = ProjectionLock.capture!(account_id, scope_id)
        entities = entities!(account_id, actor)
        drafts = Enum.map(entities, &draft/1)

        statements =
          [scope_id]
          |> Visibility.knowledge_query("active", actor, true)
          |> Ash.Query.filter(state == "active")
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read!(actor: actor)

        {drafts, statements, actor, input_generation, entity_snapshot_signature(entities),
         Visibility.earliest_boundary(statements, & &1.expires_at)}
      end
    )
  end

  # Phase two. Walks every statement and every surface form, calling the
  # embedder and — for an ambiguous match only — the reasoning model, with no
  # transaction open. Nothing here writes: it returns the drafts in their final
  # shape plus the mentions to create, both for phase three.
  #
  # Order is load-bearing. Each surface form resolves against the drafts left
  # by the ones before it, so an entity invented earlier in this run is
  # matchable later, and an entity that grows an alias is compared by its
  # widened alias embedding from then on. That is what the previous
  # re-read-per-surface-form did against the database.
  defp resolve_statements(drafts, statements, account_id, actor) do
    {drafts, mentions} =
      Enum.reduce(statements, {drafts, []}, fn knowledge, {drafts, mentions} ->
        Enum.reduce(mention_surfaces(knowledge.statement), {drafts, mentions}, fn surface,
                                                                                  {drafts,
                                                                                   mentions} ->
          case resolve_entity(drafts, knowledge, surface, account_id, actor) do
            # Unresolved on purpose: the similarity was ambiguous and the model
            # said no, or embedding failed. Recording no mention is the safe
            # outcome — it costs recall, where a wrong mention would cross
            # names.
            {:skip, drafts} ->
              {drafts, mentions}

            {:ok, drafts, key} ->
              {drafts, [mention(knowledge, key, surface) | mentions]}
          end
        end)
      end)

    {drafts, Enum.reverse(mentions)}
  end

  @doc """
  Returns the bounded surface forms that can enter the private mention index.

  The spotter rejects single characters, reviewed English boilerplate, common sentence-start
  artefacts, and timezone abbreviations. It does not join candidates across line boundaries.
  Results are case-insensitively unique within one statement.
  """
  def mention_surfaces(statement) when is_binary(statement) do
    (Regex.scan(@mention_regex, statement) ++ Regex.scan(@email_regex, statement))
    |> Enum.map(&hd/1)
    |> Enum.flat_map(&String.split(&1, ~r/[.!?][ \t]+/u, trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.map(&drop_leading_noise/1)
    |> Enum.reject(&invalid_surface?/1)
    |> Enum.uniq_by(&String.downcase/1)
  end

  def mention_surfaces(_statement), do: []

  defp invalid_surface?(nil), do: true
  defp invalid_surface?(surface), do: String.length(surface) < 2 or non_referential?(surface)

  defp non_referential?(surface) do
    case String.split(surface) do
      [token] ->
        LexicalQueryAnalyzer.boilerplate?(token) or
          MapSet.member?(@timezone_abbreviations, String.upcase(token)) or
          MapSet.member?(@sentence_noise, String.downcase(token))

      _tokens ->
        false
    end
  end

  defp drop_leading_noise(surface) do
    case surface |> String.split() |> Enum.drop_while(&noise_token?/1) do
      [] -> nil
      tokens -> Enum.join(tokens, " ")
    end
  end

  defp noise_token?(token) do
    LexicalQueryAnalyzer.boilerplate?(token) or
      MapSet.member?(@timezone_abbreviations, String.upcase(token)) or
      MapSet.member?(@sentence_noise, String.downcase(token))
  end

  # The mention a resolved surface form will become. It carries the statement's
  # own scope, which is how a mention inherits visibility: retrieval filters
  # mentions through the statement they belong to, never through the shared
  # entity. The confidence is 1.0 because the uncertainty lives in entity
  # resolution, which either committed to a match or returned nothing; the
  # mention itself is not in doubt once it is written.
  defp mention(knowledge, key, surface) do
    %{
      knowledge_item_id: knowledge.id,
      scope_id: knowledge.scope_id,
      entity_key: key,
      surface_form: surface
    }
  end

  # Tier one: an exact, case-folded hit on a canonical name or alias among the
  # drafts resolved so far.
  defp resolve_entity(drafts, knowledge, surface, account_id, actor) do
    folded = String.downcase(surface)

    index =
      Enum.find_index(drafts, fn draft ->
        Enum.any?([draft.canonical_name | draft.aliases], &(String.downcase(&1) == folded))
      end)

    if index,
      do: fold(drafts, index, knowledge.id, surface, account_id, actor),
      else: resolve_by_embedding(drafts, knowledge, surface, account_id, actor)
  end

  # Tiers two and three, reached only when no alias matched exactly. Compares
  # the surface form's embedding against every draft's alias embedding and
  # keeps the single best candidate. The cosine helper returns 0.0 for a
  # missing or differently sized vector, so a draft with no usable embedding
  # simply loses rather than crashing the comparison.
  defp resolve_by_embedding(drafts, knowledge, surface, account_id, actor) do
    context = %{
      account_id: account_id,
      scope_id: knowledge.scope_id,
      actor: actor
    }

    case Embedding.embed([surface], context, input_type: :query) do
      {:ok, result} ->
        [surface_embedding] = result.vectors

        # The empty-list fallback keeps the very first surface form of an
        # Account working, when there is nothing to compare against yet. A
        # `nil` index therefore means "no candidate at all", and note that
        # index 0 is a real candidate — only `nil` is falsy here.
        {index, score} =
          drafts
          |> Enum.with_index()
          |> Enum.map(fn {draft, index} ->
            {index, Vector.cosine(surface_embedding, draft.alias_embedding)}
          end)
          |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0.0} end)

        # Similarity only selects a candidate. Every non-exact merge needs an explicit
        # coreference decision; related names such as two months can otherwise score highly.
        cond do
          index && score >= @reject_threshold &&
              adjudicate?(surface, Enum.at(drafts, index).canonical_name, context) ->
            fold(drafts, index, knowledge.id, surface, account_id, actor)

          index && score >= @reject_threshold ->
            {:skip, drafts}

          true ->
            new_draft(drafts, knowledge, surface, surface_embedding, result)
        end

      # No embedder, no resolution. The statement is still stored, approved,
      # and retrievable by every other strategy; only this recall aid is lost.
      {:error, _error} ->
        {:skip, drafts}
    end
  end

  # Tier three: one bounded structured question to the reasoning model, used
  # only inside the ambiguous similarity band. The schema asks for a single
  # boolean and forbids extra properties. Only an explicit `true` is read as a
  # match; a failure, a malformed answer, or `false` all mean "not the same",
  # so the model can confirm a merge but never provoke one by breaking.
  defp adjudicate?(surface, canonical_name, context) do
    schema = %{
      "type" => "object",
      "required" => ["same_entity"],
      "properties" => %{"same_entity" => %{"type" => "boolean"}},
      "additionalProperties" => false
    }

    messages = [
      %{
        role: "user",
        content:
          "Do these two surface forms identify the same real-world entity? " <>
            "Return only the structured decision. left=#{surface}; right=#{canonical_name}"
      }
    ]

    case Gateway.structured_once(:dream_reasoner, messages, schema, context,
           task: :entity_resolution
         ) do
      {:ok, %{"same_entity" => true}, _config} -> true
      _other -> false
    end
  end

  # An in-memory draft for one existing entity, seeded from its persisted row.
  # `key` is the id it already has; `touched?` starts false and flips to true
  # the moment a surface form folds into it, which is how phase three tells an
  # entity nothing referenced this run from one that needs writing.
  defp draft(entity) do
    %{
      key: entity.id,
      new?: false,
      touched?: false,
      canonical_name: entity.canonical_name,
      kind: entity.kind,
      aliases: entity.aliases,
      alias_embedding: entity.alias_embedding,
      embedding_provider: entity.embedding_provider,
      embedding_model: entity.embedding_model,
      embedding_version: entity.embedding_version,
      embedding_dimensions: entity.embedding_dimensions,
      derived_from: entity.derived_from
    }
  end

  # Drafts a brand-new entity from an unmatched surface form, with no database
  # row yet. `key` is a local reference rather than an id — phase three resolves
  # it to a real id once the entity is created, using the same upsert-on-conflict
  # semantics `create_from_pipeline` always had, so two rebuilds racing on the
  # same new name still converge on one row.
  #
  # The first spelling seen becomes the canonical name, which is arbitrary but
  # harmless: the name is never shown to anyone, and later spellings accumulate
  # as aliases. `derived_from` records which statements produced this entity,
  # which is what lets the prune step and erasure reason about it without
  # re-scanning text.
  defp new_draft(drafts, knowledge, surface, embedding, result) do
    draft = %{
      key: make_ref(),
      new?: true,
      touched?: true,
      canonical_name: surface,
      kind: infer_kind(surface),
      aliases: [surface],
      alias_embedding: embedding,
      embedding_provider: result.provider,
      embedding_model: result.model,
      embedding_version: result.version,
      embedding_dimensions: result.dimensions,
      derived_from: [knowledge.id]
    }

    {:ok, drafts ++ [draft], draft.key}
  end

  # Folds a newly matched surface form into the draft at `index`: appends the
  # alias and records the statement it came from. Both lists are
  # append-and-deduplicate, never replace, so repeated rebuilds converge
  # instead of oscillating.
  defp fold(drafts, index, knowledge_id, surface, account_id, actor) do
    draft = Enum.at(drafts, index)
    aliases = Enum.uniq(draft.aliases ++ [surface])
    derived_from = Enum.uniq(draft.derived_from ++ [knowledge_id])
    context = %{account_id: account_id, actor: actor}

    # The alias embedding covers the canonical name and every alias joined
    # together, so an entity known by several names sits between them in vector
    # space and each of those names matches it. An exact alias hit does not
    # change that text and must not spend another embedder call.
    #
    # A failed embedding leaves the previous vector in place: the alias list
    # still grew, so exact matching improves and only the fuzzy tier lags until
    # the next rebuild.
    embedding_attrs =
      if aliases == draft.aliases do
        %{}
      else
        embed_aliases(draft, aliases, context)
      end

    updated =
      draft
      |> Map.merge(%{aliases: aliases, derived_from: derived_from, touched?: true})
      |> Map.merge(embedding_attrs)

    {:ok, List.replace_at(drafts, index, updated), updated.key}
  end

  defp embed_aliases(draft, aliases, context) do
    case Embedding.embed([Enum.join([draft.canonical_name | aliases], " ")], context) do
      {:ok, result} ->
        %{
          alias_embedding: hd(result.vectors),
          embedding_provider: result.provider,
          embedding_model: result.model,
          embedding_version: result.version,
          embedding_dimensions: result.dimensions
        }

      {:error, _error} ->
        %{}
    end
  end

  # Phase three. Everything durable happens here, in one short transaction with
  # no model call inside it: clear this scope's mentions, persist every draft
  # that a surface form actually touched, write the new mentions against the
  # entities' real ids, and prune whatever is now unreferenced. Untouched
  # drafts are not written at all — nothing this run resolved needs them to
  # change.
  defp write_index!(
         drafts,
         mentions,
         account_id,
         scope_id,
         input_generation,
         entity_signature,
         valid_until
       ) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        ProjectionInputs.serialize_account!(account_id)
        current_generation = ProjectionLock.capture!(account_id, scope_id)
        current_entity_signature = account_id |> entities!(actor) |> entity_snapshot_signature()

        if current_generation == input_generation and
             current_entity_signature == entity_signature and
             Visibility.boundary_visible?(valid_until, Clock.utc_now()) do
          # Clear first, then re-derive in the same transaction. Any other order
          # would leave duplicate mentions for statements that are resolved
          # again, and splitting the clear into its own transaction would expose
          # a window where the scope has no mentions at all.
          clear_mentions!(account_id, scope_id, actor)

          key_to_id =
            drafts
            |> Enum.filter(& &1.touched?)
            |> Map.new(&{&1.key, write_draft!(&1, account_id, actor)})

          Enum.each(mentions, &write_mention!(&1, key_to_id, account_id, actor))

          # Runs last, once the scope's mentions have been rewritten, so an
          # entity that only this scope referenced is now visibly unreferenced.
          prune_entities!(account_id, actor)

          if Visibility.boundary_visible?(valid_until, Clock.utc_now()) do
            :ok
          else
            throw({__MODULE__, :stale_projection_snapshot})
          end
        else
          {:error, :stale_projection_snapshot}
        end
      end
    )
  catch
    {__MODULE__, :stale_projection_snapshot} -> {:error, :stale_projection_snapshot}
  end

  defp entity_snapshot_signature(entities) do
    entities
    |> Enum.map(fn entity ->
      Map.take(entity, [
        :id,
        :canonical_name,
        :kind,
        :aliases,
        :alias_embedding,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
        :embedding_dimensions,
        :derived_from,
        :updated_at
      ])
    end)
    |> Enum.sort_by(& &1.id)
  end

  # Persists one touched draft and returns its real id. A new draft is created
  # outright, relying on the same upsert-on-conflict semantics
  # `create_from_pipeline` always had. An existing entity that a surface form
  # folded into is re-read by id and updated — the read is a plain database
  # query, not a model call, so it stays inside this transaction without
  # reintroducing the problem this rebuild fixes.
  defp write_draft!(%{new?: true} = draft, account_id, actor) do
    create!(
      Entity,
      :create_from_pipeline,
      %{
        canonical_name: draft.canonical_name,
        kind: draft.kind,
        aliases: draft.aliases,
        alias_embedding: draft.alias_embedding,
        embedding_provider: draft.embedding_provider,
        embedding_model: draft.embedding_model,
        embedding_version: draft.embedding_version,
        embedding_dimensions: draft.embedding_dimensions,
        derived_from: draft.derived_from
      },
      account_id,
      actor
    ).id
  end

  defp write_draft!(draft, account_id, actor) do
    attrs = %{
      aliases: draft.aliases,
      derived_from: draft.derived_from,
      alias_embedding: draft.alias_embedding,
      embedding_provider: draft.embedding_provider,
      embedding_model: draft.embedding_model,
      embedding_version: draft.embedding_version,
      embedding_dimensions: draft.embedding_dimensions
    }

    entity =
      Entity
      |> Ash.Query.filter(id == ^draft.key)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    # Phase two carried no loaded struct forward — only the id — so a live one
    # is fetched here to build the changeset from. Raising loudly when it is
    # gone is deliberate: a `nil` handed to `Ash.Changeset.for_update/3` would
    # crash on a confusing `FunctionClauseError` instead of naming the entity
    # that vanished between the read phase and this write.
    if is_nil(entity) do
      raise "entity #{inspect(draft.key)} vanished before its resolved mentions could be written"
    end

    # Authorization is skipped because this runs as the system pipeline actor
    # inside an already Account-scoped transaction. The tenant is still set
    # explicitly, so the write cannot escape the Account.
    entity
    |> Ash.Changeset.for_update(:recompute_from_pipeline, attrs)
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.update!(actor: actor, authorize?: false)
    |> Map.fetch!(:id)
  end

  # Writes one resolved mention, translating the in-memory entity key phase two
  # produced into the real id phase three just wrote. Every key in `mentions`
  # was produced by `fold/6` or `new_draft/5` for a touched draft, so the
  # lookup cannot miss.
  defp write_mention!(mention, key_to_id, account_id, actor) do
    create!(
      EntityMention,
      :create_from_pipeline,
      %{
        knowledge_item_id: mention.knowledge_item_id,
        scope_id: mention.scope_id,
        entity_id: Map.fetch!(key_to_id, mention.entity_key),
        surface_form: mention.surface_form,
        confidence: 1.0
      },
      account_id,
      actor
    )
  end

  # Loads every entity in the Account, not just the current scope's: an entity
  # is Account-wide by design, so the same person mentioned in two scopes
  # resolves to one entity. `alias_embedding` has to be named explicitly here
  # because it is excluded from default selects for its size, and the fuzzy
  # tier cannot compare without it. The embedding-identity columns are
  # selected too, because phase three writes a draft's identity back
  # unconditionally, including for a draft whose embedding failed to change —
  # writing back the value already loaded here is how that draft keeps its
  # previous vector in place, now that the read happens once per rebuild
  # instead of once per surface form.
  defp entities!(account_id, actor) do
    Entity
    |> Ash.Query.select([
      :id,
      :account_id,
      :canonical_name,
      :kind,
      :aliases,
      :alias_embedding,
      :embedding_provider,
      :embedding_model,
      :embedding_version,
      :embedding_dimensions,
      :derived_from,
      :updated_at
    ])
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
  end

  # Deletes this scope's mentions so the rebuild starts from nothing. Hard
  # deletes are correct here: mentions are a cache, they carry no history worth
  # keeping, and a soft-deleted mention would keep an erased name in the index.
  defp clear_mentions!(account_id, scope_id, actor) do
    EntityMention
    |> Ash.Query.filter(scope_id == ^scope_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(fn mention ->
      mention
      |> Ash.Changeset.for_destroy(:erase)
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.destroy!(actor: actor, authorize?: false)
    end)
  end

  # Removes entities no mention points at any more. This is how a name
  # disappears after the statements that introduced it are erased: the mentions
  # go with the statements, and the now-unreferenced entity goes here. The
  # mention set must be read Account-wide, because an entity referenced from
  # another scope is still in use.
  defp prune_entities!(account_id, actor) do
    mention_entity_ids =
      EntityMention
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)
      |> MapSet.new(& &1.entity_id)

    Entity
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.reject(&MapSet.member?(mention_entity_ids, &1.id))
    |> Enum.each(fn entity ->
      entity
      |> Ash.Changeset.for_destroy(:erase)
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.destroy!(actor: actor, authorize?: false)
    end)
  end

  @doc """
  A cheap English-centric guess at what kind of thing a name refers to.

  Returns one of `"person"`, `"org"`, `"system"`, or `"concept"`. The order of the branches is
  the contract: an address that also carries a company suffix stays a person.

  A title-cased name is a person unless it is a calendar name or carries an organization or
  system marker. This makes ordinary human names reachable without a model call. It remains a
  display hint: retrieval never branches on the answer. `MemHouse.Context.EntityLabel` surfaces
  it on a card. Callers must reuse this function rather than copy the rules.
  """
  def infer_kind(surface) do
    cond do
      String.contains?(surface, "@") -> "person"
      String.match?(surface, ~r/\b(?:Inc|LLC|Ltd|Corp|Org)\b/) -> "org"
      String.match?(surface, ~r/\b(?:API|DB|OS|Server|System)\b/) -> "system"
      person_name?(surface) -> "person"
      true -> "concept"
    end
  end

  defp person_name?(surface) do
    tokens = String.split(surface)

    tokens != [] and length(tokens) <= 3 and
      Enum.all?(tokens, &String.match?(&1, ~r/^\p{Lu}[\p{Ll}'-]+$/u)) and
      not Enum.any?(tokens, &MapSet.member?(@non_person_names, &1))
  end

  # Shared create helper. The tenant is set before the changeset is built for
  # the action, so tenant-aware validations see it. Authorization is skipped
  # for the same reason as the updates above: a system pipeline actor inside an
  # Account-scoped transaction.
  defp create!(resource, action, attrs, account_id, actor) do
    resource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(action, attrs)
    |> Ash.create!(actor: actor, authorize?: false)
  end
end
