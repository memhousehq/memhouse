# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.IdentityProfile do
  @moduledoc """
  Deterministically projects a compact identity profile from governed knowledge.

  The profile is not stored and never calls a model. Every item remains a visible
  knowledge statement with a bounded evidence-lineage projection; consumers must
  cite the knowledge id rather than treating profile text as an independent fact.
  """

  alias MemHouse.Knowledge.{KnowledgeItem, Provenance}
  alias MemHouse.Lineage
  alias MemHouse.Memory.Visibility

  require Ash.Query

  @max_items 16
  @max_per_category 4
  @max_statement_chars 240
  @max_total_chars 1_600

  @categories [
    {"name", ~r/\b(?:name is|goes by|is called)\b/iu},
    {"pronouns", ~r/\bpronouns?\b/iu},
    {"occupation", ~r/\b(?:works as|occupation is|profession is|job is)\b/iu},
    {"location", ~r/\b(?:lives in|based in|home is in)\b/iu},
    {"language", ~r/\b(?:speaks|primary language is|language is)\b/iu},
    {"timezone", ~r/\b(?:(?i:time ?zone is)|uses the [A-Z]{2,5} time ?zone)\b/u}
  ]

  @transient ~r/\b(?:today|tonight|tomorrow|yesterday|this (?:week|month|year)|currently|right now|temporarily|for now)\b/iu
  @behavioral ~r/\b(?:usually|often|sometimes|tends? to|habit|routine|prefers?|likes?|dislikes?|enjoys?)\b/iu
  @sensitive ~r/\b(?:diagnos|disab|disease|health|medical|medication|religio|politic|sexual|ethnic|race|pregnan|genetic|income|salary|debt)\w*/iu

  @doc """
  Builds the stable profile for `subject_peer_id` inside already-authorized scopes.

  Active direct facts and that subject's own visible provisional facts are eligible.
  Conflicts remain as separate entries. The `projection_digest` changes exactly when
  the visible selected source set changes.
  """
  def project(account, actor, scopes, subject_peer_id, internal_reader?)
      when is_binary(subject_peer_id) do
    scope_ids = Enum.map(scopes, & &1.id)

    visible =
      account.id
      |> Visibility.readable_knowledge(actor, scope_ids, internal_reader?)
      |> Enum.filter(&(&1.subject_peer_id == subject_peer_id))

    provenance_ids = provenance_ids(account.id, actor, scope_ids, Enum.map(visible, & &1.id))

    {eligible, excluded} =
      Enum.reduce(visible, {[], %{}}, fn item, {accepted, rejected} ->
        case eligibility(item, provenance_ids) do
          {:ok, category} -> {[%{item: item, category: category} | accepted], rejected}
          {:error, reason} -> {accepted, Map.update(rejected, reason, 1, &(&1 + 1))}
        end
      end)

    ordered =
      eligible
      |> Enum.sort_by(&{category_order(&1.category), normalize(&1.item.statement), &1.item.id})
      |> Enum.group_by(& &1.category)
      |> Enum.flat_map(fn {category, rows} ->
        rows
        |> Enum.sort_by(&{normalize(&1.item.statement), &1.item.id})
        |> Enum.take(@max_per_category)
        |> Enum.map(&Map.put(&1, :category, category))
      end)
      |> Enum.sort_by(&{category_order(&1.category), normalize(&1.item.statement), &1.item.id})

    references_by_id =
      Lineage.visible_source_references(Enum.map(ordered, & &1.item), account, actor, scopes)

    {source_backed, unsupported_sources} =
      Enum.reduce(ordered, {[], 0}, fn row, {accepted, rejected} ->
        case Map.fetch!(references_by_id, row.item.id) do
          [] -> {accepted, rejected + 1}
          refs -> {[Map.put(row, :source_references, refs) | accepted], rejected}
        end
      end)

    source_backed = Enum.reverse(source_backed)
    excluded = increment_by(excluded, :unsupported, unsupported_sources)
    conflict_groups = conflict_groups(source_backed)
    {selected, budget_truncated?} = fit_budget(source_backed)
    selected_ids = MapSet.new(selected, & &1.item.id)
    source_truncated? = length(eligible) > length(ordered)

    entries =
      Enum.map(selected, fn row ->
        conflict = Map.get(conflict_groups, row.category)

        %{
          "category" => row.category,
          "knowledge_id" => row.item.id,
          "statement" => row.item.statement,
          "conflict" => not is_nil(conflict),
          "conflict_group" => conflict,
          "lineage" => %{
            "target" => %{"type" => "knowledge", "id" => row.item.id},
            "source_references" => row.source_references
          }
        }
      end)

    digest = projection_digest(selected)

    %{
      "profile_version" => "stable-identity-v1",
      "subject_peer_id" => subject_peer_id,
      "projection_digest" => digest,
      "items" => entries,
      "diagnostic" => %{
        "status" => if(entries == [], do: "empty", else: "ready"),
        "eligible_count" => length(source_backed),
        "excluded_count" => Enum.sum(Map.values(excluded)),
        "excluded_by_reason" => stringify_map(excluded),
        "conflict_group_count" =>
          conflict_groups |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length(),
        "truncated" => source_truncated? or budget_truncated?,
        "returned_count" => MapSet.size(selected_ids),
        "model_calls" => 0
      }
    }
  end

  def project(_account, _actor, _scopes, _subject_peer_id, _internal_reader?) do
    %{
      "profile_version" => "stable-identity-v1",
      "subject_peer_id" => nil,
      "projection_digest" => projection_digest([]),
      "items" => [],
      "diagnostic" => %{
        "status" => "unavailable",
        "eligible_count" => 0,
        "excluded_count" => 0,
        "excluded_by_reason" => %{},
        "conflict_group_count" => 0,
        "truncated" => false,
        "returned_count" => 0,
        "model_calls" => 0
      }
    }
  end

  defp eligibility(%KnowledgeItem{} = item, provenance_ids) do
    cond do
      item.kind != "fact" ->
        {:error, :non_fact}

      item.evidence_level != "direct" ->
        {:error, :unsupported}

      Map.get(provenance_ids, item.id, []) == [] ->
        {:error, :unsupported}

      String.length(item.statement) > @max_statement_chars ->
        {:error, :too_long}

      Regex.match?(@transient, item.statement) ->
        {:error, :transient}

      Regex.match?(@behavioral, item.statement) ->
        {:error, :behavioral}

      Regex.match?(@sensitive, item.statement) ->
        {:error, :sensitive}

      category = category(item.statement) ->
        {:ok, category}

      true ->
        {:error, :not_identity}
    end
  end

  defp category(statement) do
    Enum.find_value(@categories, fn {name, pattern} ->
      if Regex.match?(pattern, statement), do: name
    end)
  end

  defp increment_by(map, _key, 0), do: map
  defp increment_by(map, key, amount), do: Map.update(map, key, amount, &(&1 + amount))

  defp provenance_ids(_account_id, _actor, _scope_ids, []), do: %{}

  defp provenance_ids(account_id, actor, scope_ids, knowledge_ids) do
    Provenance
    |> Ash.Query.filter(scope_id in ^scope_ids and knowledge_item_id in ^knowledge_ids)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.group_by(& &1.knowledge_item_id)
  end

  defp conflict_groups(rows) do
    rows
    |> Enum.group_by(& &1.category)
    |> Map.new(fn {category, category_rows} ->
      statements = category_rows |> Enum.map(&normalize(&1.item.statement)) |> Enum.uniq()

      group =
        if length(statements) > 1 do
          ids = category_rows |> Enum.map(& &1.item.id) |> Enum.sort() |> Enum.join(":")
          digest = :crypto.hash(:sha256, category <> ":" <> ids) |> Base.encode16(case: :lower)
          "identity-conflict-" <> binary_part(digest, 0, 16)
        end

      {category, group}
    end)
  end

  defp fit_budget(rows) do
    Enum.reduce_while(rows, {[], 0}, fn row, {selected, chars} ->
      next = String.length(row.item.statement)

      if length(selected) >= @max_items or chars + next > @max_total_chars do
        {:halt, {Enum.reverse(selected), true}}
      else
        {:cont, {[row | selected], chars + next}}
      end
    end)
    |> case do
      {selected, true} -> {selected, true}
      {selected, _chars} -> {Enum.reverse(selected), false}
    end
  end

  defp projection_digest(rows) do
    material =
      rows
      |> Enum.map(fn row ->
        sources =
          row
          |> Map.get(:source_references, [])
          |> Enum.map(&{&1["type"], &1["id"]})

        {row.category, row.item.id, row.item.statement_hash, row.item.state, sources}
      end)
      |> :erlang.term_to_binary()

    :crypto.hash(:sha256, material) |> Base.encode16(case: :lower)
  end

  defp normalize(statement), do: statement |> String.downcase() |> String.replace(~r/\s+/u, " ")

  defp category_order(category) do
    Enum.find_index(@categories, fn {name, _pattern} -> name == category end) ||
      length(@categories)
  end

  defp stringify_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
