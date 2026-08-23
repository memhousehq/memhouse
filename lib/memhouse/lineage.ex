# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Lineage do
  @moduledoc """
  Builds a bounded evidence graph from canonical governed records.

  The projection contains typed identifiers and operations, never model rationale,
  prompts, or chain-of-thought. Every database read is constrained by the same
  depth, fan-out, and total-node budgets that constrain the response.
  """

  alias MemHouse.Clock
  alias MemHouse.Knowledge.{KnowledgeItem, KnowledgeRelation, Provenance}
  alias MemHouse.Memory.Visibility
  alias MemHouse.Observations.{DocumentVersion, Message}

  require Ash.Query

  @default_depth 3
  @default_fan_out 8
  @default_nodes 40
  @max_depth 8
  @max_fan_out 24
  @max_nodes 100
  @relation_kinds ~w(contradicts derived_from supersedes supports)

  @doc """
  Resolves the bounded direct sources of one knowledge row through their
  canonical resource policies.

  The knowledge row may be an earlier projection. Message ids are therefore
  never trusted on their own, and Provenance's denormalized Account/scope fields
  are never sufficient to publish a document-version id. Each candidate source
  is re-read as a Message or DocumentVersion in the supplied Account and scopes;
  missing, erased, and unauthorized sources are omitted without exposing ids.
  The caller must hold the Account-scoped transaction that also read the
  knowledge row.
  """
  def visible_source_references(%KnowledgeItem{} = item, account, actor, scopes) do
    context = %{
      account_id: account.id,
      actor: actor,
      scope_ids: Enum.map(scopes, & &1.id),
      internal_reader?: false,
      now: Clock.utc_now()
    }

    item
    |> direct_source_references(context, @default_fan_out)
    |> Enum.filter(&(&1.status == "visible" and &1.type in ~w(message document_version)))
    |> Enum.uniq_by(&{&1.type, &1.id})
    |> Enum.sort_by(&{&1.type, &1.id})
    |> Enum.take(@default_fan_out)
    |> Enum.map(&%{"type" => &1.type, "id" => &1.id})
  end

  @doc """
  Projects lineage for one visible knowledge item, message, or document version.

  `attrs` accepts `target_type`, `target_id`, `max_depth`, `max_fan_out`, and
  `max_nodes`. Budgets are clamped and ordering is stable. Missing and unauthorized
  roots share `{:error, :not_found}`.
  """
  def project(account, actor, scopes, attrs, internal_reader?) do
    target_type = Map.get(attrs, "target_type", "knowledge")
    target_id = Map.fetch!(attrs, "target_id")

    with {:ok, target_id} <- cast_uuid(target_id),
         true <- target_type in ~w(knowledge message document_version) do
      budgets = budgets(attrs)

      context = %{
        account_id: account.id,
        actor: actor,
        scope_ids: Enum.map(scopes, & &1.id),
        internal_reader?: internal_reader?,
        now: Clock.utc_now()
      }

      case root(target_type, target_id, context) do
        nil -> {:error, :not_found}
        root -> {:ok, traverse(root, context, budgets)}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp root("knowledge", id, context) do
    case fetch_knowledge(id, context) do
      nil ->
        nil

      item ->
        if Visibility.visible?(item, context.actor, context.internal_reader?, context.now),
          do: item
    end
  end

  defp root("message", id, context), do: fetch_source("message", id, context)

  defp root("document_version", id, context),
    do: fetch_source("document_version", id, context)

  defp traverse(root, context, budgets) do
    state = %{
      queue: :queue.from_list([{root, 0}]),
      # Values are never read. A plain key map keeps the recursive state structural instead of
      # carrying MapSet's opaque internal representation across traversal functions.
      seen: %{},
      nodes: [],
      terminations: empty_counts()
    }

    state = walk(state, context, budgets)

    %{
      "lineage_version" => "evidence-lineage-v1",
      "target" => %{"type" => node_type(root), "id" => root.id},
      "budgets" => stringify_map(budgets),
      "nodes" => Enum.reverse(state.nodes),
      "node_count" => length(state.nodes),
      "terminations" => stringify_map(state.terminations),
      "truncated" => Enum.any?([:depth, :fan_out, :total_nodes], &(state.terminations[&1] > 0))
    }
  end

  defp walk(state, context, budgets) do
    if length(state.nodes) >= budgets.max_nodes and not :queue.is_empty(state.queue) do
      %{state | terminations: increment(state.terminations, :total_nodes)}
    else
      state.queue
      |> :queue.out()
      |> advance(state, context, budgets)
    end
  end

  defp advance({:empty, _queue}, state, _context, _budgets), do: state

  defp advance({{:value, {record, depth}}, queue}, state, context, budgets) do
    key = {node_type(record), record.id}

    if Map.has_key?(state.seen, key) do
      walk(%{state | queue: queue}, context, budgets)
    else
      visit(record, depth, queue, state, context, budgets, key)
    end
  end

  defp visit(record, depth, queue, state, context, budgets, key) do
    seen = Map.put(state.seen, key, true)
    {refs, terminations} = references(record, seen, context, budgets)
    {kept, dropped} = Enum.split(refs, budgets.max_fan_out)

    terminations =
      if dropped == [],
        do: terminations,
        else: Map.update!(terminations, :fan_out, &(&1 + length(dropped)))

    {next, terminations} = enqueue(kept, depth, budgets, terminations)
    node = node(record, depth, kept)

    walk(
      %{
        state
        | queue: Enum.reduce(next, queue, &:queue.in/2),
          seen: seen,
          nodes: [node | state.nodes],
          terminations: merge_counts(state.terminations, terminations)
      },
      context,
      budgets
    )
  end

  defp references(%KnowledgeItem{} = item, seen, context, budgets) do
    read_limit = budgets.max_fan_out + 1

    direct_source_refs = direct_source_references(item, context, read_limit)

    relation_refs =
      KnowledgeRelation
      |> Ash.Query.filter(
        scope_id in ^context.scope_ids and source_knowledge_id == ^item.id and
          kind in ^@relation_kinds
      )
      |> Ash.Query.sort(kind: :asc, target_knowledge_id: :asc, id: :asc)
      |> Ash.Query.limit(read_limit)
      |> Ash.Query.set_tenant(context.account_id)
      |> Ash.read!(actor: context.actor)
      |> Enum.map(&relation_ref(&1, context))

    refs =
      (direct_source_refs ++ relation_refs)
      |> Enum.uniq_by(&{&1.type, &1.operation, &1.id, &1.status})
      |> Enum.sort_by(&{&1.type, &1.operation, &1.id || "", &1.status})

    counts =
      Enum.reduce(refs, empty_counts(), fn ref, acc ->
        cond do
          ref.status == "missing" ->
            increment(acc, :missing)

          ref.status == "lifecycle_hidden" ->
            increment(acc, :lifecycle_hidden)

          ref.status == "authorization_hidden" ->
            increment(acc, :authorization_hidden)

          ref.status == "visible" and Map.has_key?(seen, {ref.type, ref.id}) ->
            increment(acc, :cycle)

          true ->
            acc
        end
      end)

    {refs, counts}
  end

  defp references(_source, _seen, _context, _budgets), do: {[], empty_counts()}

  defp direct_source_references(item, context, read_limit) do
    provenance_refs =
      Provenance
      |> Ash.Query.filter(scope_id in ^context.scope_ids and knowledge_item_id == ^item.id)
      |> Ash.Query.sort(source_type: :asc, message_id: :asc, document_version_id: :asc, id: :asc)
      |> Ash.Query.limit(read_limit)
      |> Ash.Query.set_tenant(context.account_id)
      |> Ash.read!(actor: context.actor)
      |> Enum.map(&provenance_ref(&1, context))

    legacy_message_refs =
      item.source_message_ids
      |> Enum.reject(fn id ->
        Enum.any?(provenance_refs, &(&1.type == "message" and &1.id == id))
      end)
      |> Enum.sort()
      |> Enum.take(read_limit)
      |> Enum.map(&source_ref("message", &1, "extraction", context))

    provenance_refs ++ legacy_message_refs
  end

  defp provenance_ref(%{source_type: "message", message_id: id}, context),
    do: source_ref("message", id, "extraction", context)

  defp provenance_ref(%{source_type: "document", document_version_id: id}, context),
    do: source_ref("document_version", id, "document_extraction", context)

  defp provenance_ref(_provenance, _context),
    do: %{type: "source", id: nil, operation: "extraction", status: "missing", record: nil}

  defp source_ref(type, id, operation, context) do
    case fetch_source(type, id, context) do
      nil -> %{type: type, id: nil, operation: operation, status: "missing", record: nil}
      record -> %{type: type, id: id, operation: operation, status: "visible", record: record}
    end
  end

  defp relation_ref(relation, context) do
    case fetch_knowledge(relation.target_knowledge_id, context) do
      nil ->
        %{
          type: "knowledge",
          id: nil,
          operation: relation.kind,
          status: "missing",
          record: nil
        }

      item ->
        status =
          Visibility.visibility_status(
            item,
            context.actor,
            context.internal_reader?,
            context.now
          )

        %{
          type: "knowledge",
          id: if(status == :visible, do: item.id),
          operation: relation.kind,
          status: Atom.to_string(status),
          record: if(status == :visible, do: item)
        }
    end
  end

  defp enqueue(refs, depth, budgets, terminations) do
    Enum.reduce(refs, {[], terminations}, fn ref, {records, counts} ->
      cond do
        ref.status != "visible" ->
          {records, counts}

        depth >= budgets.max_depth ->
          {records, increment(counts, :depth)}

        ref.record ->
          {[{ref.record, depth + 1} | records], counts}

        true ->
          {records, increment(counts, :missing)}
      end
    end)
    |> then(fn {records, counts} -> {Enum.reverse(records), counts} end)
  end

  defp node(%KnowledgeItem{} = item, depth, refs) do
    %{
      "id" => item.id,
      "type" => "knowledge",
      "derivation_level" => knowledge_level(item, refs),
      "operation" => knowledge_operation(item, refs),
      "traversal_depth" => depth,
      "source_references" => Enum.map(refs, &public_ref/1)
    }
  end

  defp node(%Message{} = message, depth, _refs) do
    %{
      "id" => message.id,
      "type" => "message",
      "derivation_level" => 0,
      "operation" => "observation",
      "traversal_depth" => depth,
      "source_references" => []
    }
  end

  defp node(%DocumentVersion{} = version, depth, _refs) do
    %{
      "id" => version.id,
      "type" => "document_version",
      "derivation_level" => 0,
      "operation" => "document_version",
      "traversal_depth" => depth,
      "source_references" => []
    }
  end

  defp knowledge_level(%{deduction_key: key}, _refs) when is_binary(key), do: 2

  defp knowledge_level(_item, refs),
    do: if(Enum.any?(refs, &(&1.operation == "derived_from")), do: 2, else: 1)

  defp knowledge_operation(%{prompt_version: "reason-synthesis-1"}, _refs),
    do: "reasoning_synthesis"

  defp knowledge_operation(%{deduction_key: key}, _refs) when is_binary(key), do: "deduction"

  defp knowledge_operation(_item, refs) do
    cond do
      Enum.any?(refs, &(&1.operation == "derived_from")) -> "derivation"
      Enum.any?(refs, &(&1.operation == "supersedes")) -> "supersession"
      Enum.any?(refs, &(&1.operation in ["extraction", "document_extraction"])) -> "extraction"
      true -> "governed"
    end
  end

  defp public_ref(ref) do
    %{
      "type" => ref.type,
      "id" => if(ref.status == "visible", do: ref.id),
      "operation" => ref.operation,
      "status" => ref.status
    }
  end

  defp fetch_knowledge(id, context) when is_binary(id) do
    KnowledgeItem
    |> Ash.Query.filter(id == ^id and scope_id in ^context.scope_ids and is_nil(deleted_at))
    |> Ash.Query.limit(1)
    |> Ash.Query.set_tenant(context.account_id)
    |> Ash.read_one!(actor: context.actor)
  end

  defp fetch_knowledge(_id, _context), do: nil

  defp fetch_source("message", id, context),
    do: fetch_source_record(Message, id, context)

  defp fetch_source("document_version", id, context),
    do: fetch_source_record(DocumentVersion, id, context)

  defp fetch_source(_type, _id, _context), do: nil

  defp fetch_source_record(resource, id, context) when is_binary(id) do
    resource
    |> Ash.Query.filter(id == ^id and scope_id in ^context.scope_ids)
    |> Ash.Query.limit(1)
    |> Ash.Query.set_tenant(context.account_id)
    |> Ash.read_one!(actor: context.actor)
  end

  defp fetch_source_record(_resource, _id, _context), do: nil

  defp node_type(%KnowledgeItem{}), do: "knowledge"
  defp node_type(%Message{}), do: "message"
  defp node_type(%DocumentVersion{}), do: "document_version"

  defp budgets(attrs) do
    %{
      max_depth: clamp_int(Map.get(attrs, "max_depth"), @default_depth, 0, @max_depth),
      max_fan_out: clamp_int(Map.get(attrs, "max_fan_out"), @default_fan_out, 1, @max_fan_out),
      max_nodes: clamp_int(Map.get(attrs, "max_nodes"), @default_nodes, 1, @max_nodes)
    }
  end

  defp clamp_int(value, _default, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp clamp_int(value, default, minimum, maximum) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> clamp_int(integer, default, minimum, maximum)
      _ -> default
    end
  end

  defp clamp_int(_value, default, _minimum, _maximum), do: default

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> :error
    end
  end

  defp empty_counts,
    do: %{
      cycle: 0,
      depth: 0,
      fan_out: 0,
      total_nodes: 0,
      missing: 0,
      lifecycle_hidden: 0,
      authorization_hidden: 0
    }

  defp increment(map, key), do: Map.update!(map, key, &(&1 + 1))

  defp merge_counts(left, right),
    do: Map.merge(left, right, fn _key, a, b -> a + b end)

  defp stringify_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
