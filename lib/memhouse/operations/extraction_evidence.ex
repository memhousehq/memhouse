# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Operations.ExtractionEvidence do
  @moduledoc """
  Builds a content-safe extraction summary for one scope subtree.

  The summary contains only counts, durations, classifications, and configured
  model identities. It never returns statements, source ids, prompt text,
  completions, credentials, or free-form metadata.
  """

  alias MemHouse.Actor
  alias MemHouse.DataLayer
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Operations.{PipelineRun, UsageEvent}
  alias MemHouse.Topology.Scope

  require Ash.Query

  @schema_version "memhouse-extraction-evidence-1"
  @settled_statuses ~w(completed repairable terminal cancelled discarded)

  @doc """
  Returns extraction evidence for `scope_root` and its descendants.

  Returns `{:error, :not_found}` when the actor cannot read the exact root.
  The caller must treat `accounting.complete == false` as a failed evidence
  export.
  """
  def summary(%Actor{} = actor, scope_root)
      when is_binary(scope_root) and byte_size(scope_root) > 0 do
    DataLayer.in_account_transaction(actor.account_id, fn ->
      scopes = read(Scope, actor)

      if Enum.any?(scopes, &(&1.path == scope_root)) do
        selected = Enum.filter(scopes, &inside?(&1.path, scope_root))
        scope_ids = Enum.map(selected, & &1.id)

        runs =
          PipelineRun
          |> Ash.Query.filter(kind == "extraction" and scope_id in ^scope_ids)
          |> stream(actor)

        usages =
          UsageEvent
          |> Ash.Query.filter(model_role == "ingest_extractor" and scope_id in ^scope_ids)
          |> read(actor)

        statements =
          KnowledgeItem
          |> Ash.Query.filter(scope_id in ^scope_ids)
          |> read(actor)

        {:ok, build(scope_root, selected, runs, usages, statements)}
      else
        {:error, :not_found}
      end
    end)
  end

  def summary(%Actor{}, _scope_root), do: {:error, :not_found}

  defp build(scope_root, scopes, runs, usages, statements) do
    batches = batch_evidence(runs)
    usage_totals = usage_totals(usages)

    %{
      schema_version: @schema_version,
      scope_root: scope_root,
      scopes: %{count: length(scopes)},
      extraction: %{
        anchors: length(runs),
        status_counts: frequencies(runs, & &1.status),
        error_classes: frequencies(runs, & &1.last_error_class),
        job_attempts: Enum.sum(Enum.map(runs, & &1.attempt_count)),
        attempt_count: frequencies(runs, & &1.attempt_count),
        terminal_anchors: Enum.count(runs, &(&1.status == "terminal")),
        admission_identity: frequencies(runs, &get_in(&1.payload, ["admission_identity"])),
        candidate_yield: candidate_yield(runs),
        batches: batch_summary(batches)
      },
      usage:
        Map.merge(usage_totals, %{
          duration_distribution_ms: duration_distribution(usages),
          first_occurred_at: occurred_boundary(usages, :first),
          last_occurred_at: occurred_boundary(usages, :last),
          provenance: usage_provenance(usages)
        }),
      statements: %{
        count: length(statements),
        distributions: %{
          kind: frequencies(statements, & &1.kind),
          sensitivity: frequencies(statements, & &1.sensitivity),
          target_level: frequencies(statements, & &1.target_level),
          state: frequencies(statements, & &1.state),
          prompt_version: frequencies(statements, & &1.prompt_version),
          pipeline_version: frequencies(statements, & &1.pipeline_version),
          valid_time: frequencies(statements, &valid_time_shape/1)
        }
      },
      accounting: accounting(runs, usages, batches)
    }
  end

  defp read(query, actor) do
    query
    |> Ash.Query.set_tenant(actor.account_id)
    |> Ash.read!(actor: actor)
  end

  defp stream(query, actor) do
    query
    |> Ash.Query.set_tenant(actor.account_id)
    |> Ash.stream!(actor: actor, batch_size: 500, stream_with: :keyset)
    |> Enum.to_list()
  end

  defp inside?(path, "/"), do: String.starts_with?(path, "/")
  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp frequencies(rows, mapper) do
    rows
    |> Enum.map(mapper)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  defp candidate_yield(runs) do
    counts =
      runs
      |> Enum.map(&get_in(&1.payload, ["extraction_evidence", "candidate_count"]))
      |> Enum.filter(&(is_integer(&1) and &1 >= 0))
      |> Enum.frequencies_by(fn
        0 -> "zero"
        1 -> "one"
        _many -> "multiple"
      end)

    Map.merge(%{"zero" => 0, "one" => 0, "multiple" => 0}, counts)
  end

  defp batch_evidence(runs) do
    runs
    |> Enum.flat_map(fn run ->
      case get_in(run.payload || %{}, ["extraction_attempts"]) do
        attempts when is_list(attempts) and attempts != [] -> attempts
        _missing -> [extraction_evidence(run)]
      end
    end)
    |> Enum.filter(&valid_batch_evidence?/1)
    |> Enum.group_by(& &1["batch_id"])
    |> Enum.map(fn {_batch_id, copies} -> hd(copies) end)
  end

  defp valid_batch_evidence?(evidence) when is_map(evidence) do
    is_binary(evidence["batch_id"]) and positive_integer?(evidence["anchor_count"]) and
      non_negative_integer?(evidence["provider_attempts"]) and
      non_negative_integer?(evidence["candidate_count"])
  end

  defp valid_batch_evidence?(_evidence), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp batch_summary(batches) do
    %{
      count: length(batches),
      anchor_count: frequencies(batches, &Integer.to_string(&1["anchor_count"])),
      provider_attempts: frequencies(batches, &Integer.to_string(&1["provider_attempts"]))
    }
  end

  defp accounting(runs, usages, batches) do
    present? = runs != []
    settled? = present? and Enum.all?(runs, &(&1.status in @settled_statuses))
    settled_runs = Enum.filter(runs, &(&1.status in @settled_statuses))
    evidence_complete? = Enum.all?(settled_runs, &valid_batch_evidence?(extraction_evidence(&1)))
    evidence_consistent? = consistent_batch_evidence?(settled_runs)
    cardinality_complete? = batch_cardinality_complete?(settled_runs)
    expected_attempts = Enum.sum(Enum.map(batches, & &1["provider_attempts"]))
    unmetered = Enum.count(usages, &unmetered?/1)

    requests_complete? =
      settled? and evidence_complete? and evidence_consistent? and
        cardinality_complete? and
        expected_attempts == length(usages)

    tokens_complete? = requests_complete? and unmetered == 0

    reasons =
      []
      |> add_reason(not present?, "extraction accounting is empty")
      |> add_reason(not settled?, "extraction runs are not settled")
      |> add_reason(
        settled? and not evidence_complete?,
        "settled extraction runs are missing batch evidence"
      )
      |> add_reason(
        settled? and not evidence_consistent?,
        "settled extraction runs disagree about batch evidence"
      )
      |> add_reason(
        settled? and not cardinality_complete?,
        "settled extraction batch cardinality does not match its anchors"
      )
      |> add_reason(
        settled? and evidence_complete? and expected_attempts != length(usages),
        "provider-attempt rows do not match settled batch evidence"
      )
      |> add_reason(unmetered > 0, "provider failures have unknown token usage")

    %{
      complete: reasons == [],
      settled: settled?,
      requests_complete: requests_complete?,
      tokens_complete: tokens_complete?,
      cost_complete: tokens_complete?,
      reasons: reasons
    }
  end

  defp consistent_batch_evidence?(runs) do
    runs
    |> Enum.map(&extraction_evidence/1)
    |> Enum.filter(&valid_batch_evidence?/1)
    |> Enum.group_by(& &1["batch_id"])
    |> Enum.all?(fn {_batch_id, copies} ->
      copies
      |> Enum.map(&Map.take(&1, ["batch_id", "anchor_count", "provider_attempts"]))
      |> Enum.uniq()
      |> length() == 1
    end)
  end

  defp batch_cardinality_complete?(runs) do
    runs
    |> Enum.map(&extraction_evidence/1)
    |> Enum.filter(&valid_batch_evidence?/1)
    |> Enum.group_by(& &1["batch_id"])
    |> Enum.all?(fn {_batch_id, copies} ->
      length(copies) == hd(copies)["anchor_count"]
    end)
  end

  defp extraction_evidence(run),
    do: get_in(run.payload || %{}, ["extraction_evidence"])

  defp add_reason(reasons, true, reason), do: reasons ++ [reason]
  defp add_reason(reasons, false, _reason), do: reasons

  defp usage_totals(usages) do
    %{
      provider_attempts: length(usages),
      errors: Enum.count(usages, &(&1.status == "error")),
      unmetered_attempts: Enum.count(usages, &unmetered?/1),
      input_tokens: Enum.sum(Enum.map(usages, & &1.input_tokens)),
      output_tokens: Enum.sum(Enum.map(usages, & &1.output_tokens)),
      embedding_tokens: Enum.sum(Enum.map(usages, & &1.embedding_tokens)),
      total_tokens:
        Enum.sum(Enum.map(usages, &(&1.input_tokens + &1.output_tokens + &1.embedding_tokens))),
      duration_ms: Enum.sum(Enum.map(usages, & &1.duration_ms))
    }
  end

  defp unmetered?(usage) do
    Map.get(usage.metadata, "metering_status") != "complete"
  end

  defp usage_provenance(usages) do
    usages
    |> Enum.group_by(fn usage ->
      {
        usage.provider,
        usage.model_name,
        usage.model_version,
        usage.prompt_version,
        usage.pipeline_version
      }
    end)
    |> Enum.map(fn {{provider, model, model_version, prompt_version, pipeline_version}, rows} ->
      totals = usage_totals(rows)

      %{
        provider: provider,
        model: model,
        model_version: model_version,
        prompt_version: prompt_version,
        pipeline_version: pipeline_version,
        attempts: totals.provider_attempts,
        errors: totals.errors,
        unmetered_attempts: totals.unmetered_attempts,
        input_tokens: totals.input_tokens,
        output_tokens: totals.output_tokens,
        embedding_tokens: totals.embedding_tokens,
        duration_ms: totals.duration_ms
      }
    end)
    |> Enum.sort_by(&{&1.provider, &1.model, &1.model_version, &1.prompt_version})
  end

  defp duration_distribution([]),
    do: %{count: 0, min: nil, p50: nil, p95: nil, max: nil}

  defp duration_distribution(usages) do
    values = usages |> Enum.map(& &1.duration_ms) |> Enum.sort()

    %{
      count: length(values),
      min: hd(values),
      p50: percentile(values, 0.50),
      p95: percentile(values, 0.95),
      max: List.last(values)
    }
  end

  defp percentile(values, fraction) do
    index = max(ceil(length(values) * fraction) - 1, 0)
    Enum.at(values, index)
  end

  defp occurred_boundary([], _side), do: nil

  defp occurred_boundary(usages, :first),
    do: usages |> Enum.min_by(& &1.occurred_at) |> then(& &1.occurred_at)

  defp occurred_boundary(usages, :last),
    do: usages |> Enum.max_by(& &1.occurred_at) |> then(& &1.occurred_at)

  defp valid_time_shape(%{relevant_from: nil, relevant_until: nil}), do: "none"
  defp valid_time_shape(%{relevant_from: nil}), do: "until_only"
  defp valid_time_shape(%{relevant_until: nil}), do: "from_only"
  defp valid_time_shape(_statement), do: "bounded"
end
