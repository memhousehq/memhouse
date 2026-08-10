# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.Usage do
  @moduledoc """
  The single durable emission point for model usage.

  Every provider attempt, including failure and repair, appends one model usage row here.
  `Operations.Metering` separately writes HTTP rows as role `"edge"`, provider `"none"`. Traces
  are sampled; this table is the exact ledger.

  ## What a row records

  Account, optional scope and peer attribution, the operation and role, the full
  provider/model/version/prompt/pipeline provenance, input, output, and
  embedding token counts, wall-clock duration, an `ok`/`error` status, a
  timestamp, and a small metadata map.

  ## A row commits on its own

  Each row uses its own short Account transaction. Provider calls hold no database connection,
  and a later caller rollback cannot erase usage already incurred.

  ## Content safety is enforced here, not by convention

  Metadata uses a fixed allowlist. Unknown keys are dropped so prompts, answers, observations,
  credentials, and knowledge cannot enter this operator-visible table. New keys must be
  provably content-free.

  ## Mistakes to avoid

  - Do not write model `UsageEvent` rows from anywhere else; the ledger stops
    being exact the moment there is a second writer.
  - Do not add a metadata key that could carry text supplied by a user or
    returned by a model.
  - Do not rely on this raising to signal a metering problem. A call without an
    Account or actor context is silently skipped, because losing a metering row
    must never fail the model call that the caller actually needed.
  """

  alias MemHouse.Clock
  alias MemHouse.Model.Config
  alias MemHouse.Model.Config.Role
  alias MemHouse.Operations.Metering
  alias MemHouse.Operations.UsageEvent

  # Content-safety allowlist for usage metadata. Every key here holds a count, a
  # boolean, or a short classification string — never text from a prompt, a
  # completion, an observation, or a credential. Anything not on this list is
  # dropped before the row is written.
  @safe_metadata_keys ~w(error_class fallback metering_status repair_attempt result_count vector_count)

  @doc """
  Appends one usage row for a completed provider call and updates budget counters.

  `context` must carry `:account_id` and `:actor`; `:scope_id` and `:peer_id`
  are optional attribution. `attrs` carries `:operation`, `:status` (`:ok` or
  `:error`), `:duration_ms`, a `:usage` token map, and a `:metadata` map that
  will be reduced to the safe allowlist.

  Returns `:ok`. The second clause makes a context without an Account or actor a
  no-op, which is what lets offline tooling and tests exercise the model layer
  without a tenant.

  Writes through the internal pipeline actor, because recording usage is a
  system obligation rather than something the calling human or agent is
  separately authorized to do. Raises if the durable write itself fails: a call
  that really was billed must not be quietly forgotten.
  """
  def emit(%{account_id: account_id, actor: actor} = context, %Role{} = config, attrs)
      when is_binary(account_id) and not is_nil(actor) do
    usage = attrs |> Map.get(:usage, %{}) |> normalize_usage()
    metadata = attrs |> Map.get(:metadata, %{}) |> safe_metadata()
    provenance = Config.provenance(config)

    # A separate Account transaction records incurred usage even if the caller later rolls back.
    MemHouse.DataLayer.in_account_transaction(account_id, fn ->
      UsageEvent
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.Changeset.for_create(:record, %{
        call_id: Ecto.UUID.generate(),
        scope_id: Map.get(context, :scope_id),
        peer_id: Map.get(context, :peer_id),
        operation: to_string(Map.fetch!(attrs, :operation)),
        model_role: Atom.to_string(config.role),
        provider: provenance.provider,
        model_name: provenance.model,
        model_version: provenance.model_version,
        prompt_version: provenance.prompt_version,
        pipeline_version: provenance.pipeline_version,
        input_tokens: Map.get(usage, :input_tokens, 0),
        output_tokens: Map.get(usage, :output_tokens, 0),
        embedding_tokens: Map.get(usage, :embedding_tokens, 0),
        duration_ms: Map.fetch!(attrs, :duration_ms),
        status: to_string(Map.fetch!(attrs, :status)),
        metadata: metadata,
        occurred_at: Clock.utc_now()
      })
      |> Ash.create!(actor: pipeline_actor(actor))
    end)

    # In-memory budget counters are a rebuildable cache derived from these rows;
    # they are updated after the durable write so the cache can never claim
    # spend that was not recorded.
    Metering.record_model(account_id, Map.get(context, :scope_id), usage)
    :ok
  end

  def emit(_context, _config, _attrs), do: :ok

  # Providers report token counts under atom or string keys, sometimes omit them
  # entirely, and occasionally report nil. Everything is coerced to a
  # non-negative integer so arithmetic downstream cannot blow up on a partial
  # provider response.
  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens: non_negative(usage[:input_tokens] || usage["input_tokens"]),
      output_tokens: non_negative(usage[:output_tokens] || usage["output_tokens"]),
      embedding_tokens: non_negative(usage[:embedding_tokens] || usage["embedding_tokens"])
    }
  end

  defp normalize_usage(_usage), do: %{input_tokens: 0, output_tokens: 0, embedding_tokens: 0}

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: 0

  # Allowlist, not denylist. Unknown keys are dropped rather than inspected,
  # so a provider adapter that starts returning richer metadata cannot leak
  # content into the ledger by accident.
  defp safe_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(@safe_metadata_keys)
  end

  defp safe_metadata(_metadata), do: %{}

  # Metering is an internal obligation of the engine, so the row is written as
  # the system pipeline rather than as the caller. The caller's Account is
  # preserved — only the authorization role is elevated — so this cannot be used
  # to write into another Account. Two clauses because the actor may be a struct
  # or a plain map depending on the entry point.
  defp pipeline_actor(%_{} = actor) do
    actor
    |> Map.put(:role, :system)
    |> Map.put(:pipeline?, true)
  end

  defp pipeline_actor(actor) when is_map(actor) do
    actor
    |> Map.put(:role, :system)
    |> Map.put(:pipeline?, true)
  end
end
