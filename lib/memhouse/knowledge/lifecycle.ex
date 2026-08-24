# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Knowledge.Lifecycle do
  @moduledoc """
  Executable contract for the knowledge lifecycle.

  The contract owns state names, operator meanings, visibility classes,
  retrieval eligibility, and allowed state edges. Durable writers, API and
  console presentation, and tests consume this module so a new state or edge
  cannot appear on only one surface.

  State names remain public compatibility values. Lifecycle events preserve
  the exact edge and reason. A state is therefore a mutually exclusive summary
  of the action that operators must take now, while timestamps, verification,
  provenance, and relations retain the orthogonal detail.
  """

  @type stability :: :transient | :stable | :terminal
  @type retrieval :: :all_authorized | :subject_only | :none
  @type visibility :: :all_authorized | :subject_or_governor | :subject_only

  @contracts [
    %{
      name: "proposed",
      meaning: "Extracted and waiting for its first gate decision.",
      stability: :transient,
      retrieval: :none,
      visibility: :subject_or_governor,
      example: "A new pipeline statement before Gate A and Gate B run.",
      fixture: "pipeline proposal creation",
      entry: "`nil → proposed` when the pipeline creates an extracted statement.",
      actor_queue: "Pipeline; extraction queue.",
      lifecycle:
        "Transient; `active`, `provisional`, `held`, `rejected`, `contested`, `redacted`, or `retracted`.",
      downstream: "No projection; missing for readiness.",
      evidence:
        "`verification=pending`; reason `f4_pipeline_proposed`; a new extracted preference; pipeline proposal fixture.",
      exits: ~w(active provisional held rejected contested redacted retracted)
    },
    %{
      name: "active",
      meaning: "Accepted. The system currently believes it.",
      stability: :stable,
      retrieval: :all_authorized,
      visibility: :all_authorized,
      example: "A direct self-observation accepted by an automatic gate rule.",
      fixture: "automatic Gate A and Gate B acceptance",
      entry: "Gate acceptance, curator approval, subject confirmation, or resolved contest.",
      actor_queue:
        "Pipeline, human governance, or verified peer answer; extraction or validation queue.",
      lifecycle:
        "Stable; self-edge for governed timer evidence, then `held`, `needs_revalidation`, `contested`, `superseded`, `expired`, `redacted`, or `retracted`.",
      downstream: "Shared and peer projections; satisfies readiness while fresh.",
      evidence:
        "Verification names the accepting decision; an accepted direct self-observation; automatic Gate A/B fixture.",
      exits: ~w(active held needs_revalidation contested superseded expired redacted retracted)
    },
    %{
      name: "provisional",
      meaning: "Visible only to its subject while it waits for review.",
      stability: :stable,
      retrieval: :subject_only,
      visibility: :subject_only,
      example: "A peer-level statement deferred to a human reviewer.",
      fixture: "default peer-level gate deferral",
      entry: "`proposed → provisional` when a peer-level gate defers.",
      actor_queue: "Pipeline; extraction creates a validation row and peer question.",
      lifecycle:
        "Stable; self-edge for unverified deferral, then `active`, `held`, `rejected`, `contested`, `superseded`, `expired`, `redacted`, `stale`, or `retracted`.",
      downstream:
        "Subject-keyed peer projection only; satisfies that subject's readiness while fresh.",
      evidence:
        "`subject_peer_id` and pending validation; reason `f4_gate_a_b_deferred`; a deferred peer preference; default-gate fixture.",
      exits:
        ~w(provisional active held rejected contested superseded expired redacted stale retracted)
    },
    %{
      name: "held",
      meaning: "Parked at its source scope while wider placement waits for review or consent.",
      stability: :stable,
      retrieval: :none,
      visibility: :subject_or_governor,
      example: "A scope-level proposal waiting for its first curator decision.",
      fixture: "scope-level gate deferral",
      entry: "`proposed → held` on wider gate deferral, or `active → held` on promotion request.",
      actor_queue: "Pipeline or human promotion; validation/consent workflow.",
      lifecycle:
        "Stable; self-edge for unverified deferral, then `active`, `rejected`, `contested`, `superseded`, `expired`, `redacted`, or `retracted`.",
      downstream: "Removed from projections; missing for readiness.",
      evidence:
        "`held_scope_id` and validation target; deferred or promotion reason; a scope proposal awaiting its first curator decision; scope-hold fixture.",
      exits: ~w(held active rejected contested superseded expired redacted retracted)
    },
    %{
      name: "needs_revalidation",
      meaning: "Past its revalidation date and unusable until it is confirmed again.",
      stability: :stable,
      retrieval: :none,
      visibility: :all_authorized,
      example: "An active statement selected by the hourly revalidation worker.",
      fixture: "revalidation lifecycle worker",
      entry:
        "`active → needs_revalidation` when `revalidate_after` passes or a deduction contributor changes.",
      actor_queue:
        "Lifecycle worker or pipeline dependency invalidation; `lifecycle` or reasoning queue.",
      lifecycle:
        "Stable; self-edge for unverified deferral, then `active`, `rejected`, `contested`, `superseded`, `expired`, `redacted`, `stale`, or `retracted`.",
      downstream: "Removed from projections; reported as a readiness gap.",
      evidence:
        "Due timestamp plus validation row; reason `f4_revalidation_due` or contributor-change reason; an old preference needing confirmation; revalidation-worker fixture.",
      exits:
        ~w(needs_revalidation active rejected contested superseded expired redacted stale retracted)
    },
    %{
      name: "superseded",
      meaning: "Replaced by a later statement and retained as history.",
      stability: :terminal,
      retrieval: :none,
      visibility: :all_authorized,
      example: "A curator edit replaces the original statement.",
      fixture: "curator edit or consolidation replacement",
      entry:
        "A curator edit/merge, document revision, consolidation, or accepted deduction replacement retires an older row.",
      actor_queue: "Human governance, document sync, or dream-time worker.",
      lifecycle:
        "Terminal for ordinary lifecycle work; privacy redaction or last-source retraction may still override it.",
      downstream: "Removed from projections; missing for readiness.",
      evidence:
        "`supersedes_id` where applicable; path-specific reason; an edited statement's original row; replacement fixture.",
      exits: ~w(redacted retracted)
    },
    %{
      name: "expired",
      meaning: "Past its declared expiry and no longer usable.",
      stability: :terminal,
      retrieval: :none,
      visibility: :all_authorized,
      example: "The expiry worker reaches a statement whose expires_at passed.",
      fixture: "expiry lifecycle worker",
      entry: "A lifecycle worker reaches `expires_at` on a nonterminal current row.",
      actor_queue: "Lifecycle worker; `lifecycle` queue started by hourly scheduler.",
      lifecycle:
        "Terminal for ordinary lifecycle work; privacy redaction or last-source retraction may still override it.",
      downstream: "Removed from projections; reported as a readiness gap.",
      evidence:
        "`expires_at`; reason `f4_expiry_due`; a time-limited event after its end; expiry-worker fixture.",
      exits: ~w(redacted retracted)
    },
    %{
      name: "rejected",
      meaning: "Refused by a gate or reviewer and retained as decision evidence.",
      stability: :terminal,
      retrieval: :none,
      visibility: :subject_or_governor,
      example: "Gate A rejects evidence that does not meet its configured rule.",
      fixture: "automatic or curator rejection",
      entry:
        "Gate auto-rejection, unattended restricted withholding, curator rejection, or overdue-review rejection.",
      actor_queue: "Pipeline, human governance, or dream-time aging.",
      lifecycle:
        "Terminal for ordinary lifecycle work; privacy redaction or last-source retraction may still override it.",
      downstream: "Removed from projections; missing for readiness.",
      evidence:
        "Verification and gate/validation decision; stable rejection reason; a claim declined by a curator; rejection fixture.",
      exits: ~w(redacted retracted)
    },
    %{
      name: "contested",
      meaning: "Disputed by its subject and waiting for a curator decision.",
      stability: :stable,
      retrieval: :none,
      visibility: :subject_or_governor,
      example: "A subject contests a statement in self-governance.",
      fixture: "subject contest action",
      entry: "A subject disputes a nonterminal statement.",
      actor_queue:
        "Authenticated human subject; synchronous request creates a curator validation row.",
      lifecycle:
        "Stable; `active`, `rejected`, `superseded`, `expired`, `redacted`, or `retracted`.",
      downstream: "Removed from projections; missing for readiness.",
      evidence:
        "Subject identity and dispute validation; reason `f4_subject_contested`; an incorrect preference disputed by its subject; self-governance contest fixture.",
      exits: ~w(active rejected superseded expired redacted retracted)
    },
    %{
      name: "redacted",
      meaning: "Withdrawn from use by its subject.",
      stability: :terminal,
      retrieval: :none,
      visibility: :subject_or_governor,
      example: "A subject redacts a statement in self-governance.",
      fixture: "subject redact action",
      entry: "A subject withdraws a retained statement through self-governance.",
      actor_queue: "Authenticated human subject; synchronous self-governance action.",
      lifecycle:
        "Terminal for ordinary lifecycle work; last-source retraction may still override it.",
      downstream: "Removed from projections; missing for readiness.",
      evidence:
        "Subject identity; reason `f4_subject_redacted`; a subject withdraws personal content; self-governance redact fixture.",
      exits: ~w(retracted)
    },
    %{
      name: "stale",
      meaning: "Repeatedly unconfirmed and no longer relied on.",
      stability: :stable,
      retrieval: :none,
      visibility: :subject_or_governor,
      example: "An unanswered revalidation question passes its deadline.",
      fixture: "dream-time peer-question decay",
      entry:
        "An unanswered confirmation or revalidation question passes its deadline; consent questions are excluded.",
      actor_queue: "Dream-time worker; dream-time queue.",
      lifecycle:
        "Stable; `active`, `rejected`, `contested`, `superseded`, `expired`, `redacted`, or `retracted`.",
      downstream: "Removed from projections; missing for readiness.",
      evidence:
        "Expired peer question and lower confidence; reason `f4_revalidation_confidence_decay`; an unconfirmed old preference; peer-question decay fixture.",
      exits: ~w(active rejected contested superseded expired redacted retracted)
    },
    %{
      name: "retracted",
      meaning: "Lost its supporting source or was denied by its subject.",
      stability: :terminal,
      retrieval: :none,
      visibility: :subject_or_governor,
      example: "Source erasure removes the last provenance for a statement.",
      fixture: "source erasure or verified peer rejection",
      entry: "A verified subject rejects the claim, or its last source is tombstoned or erased.",
      actor_queue: "Verified peer answer, document sync, or erasure worker.",
      lifecycle:
        "Terminal; self-edge only when repeated source erasure removes retained provenance.",
      downstream: "Removed from projections; missing for readiness.",
      evidence:
        "Source or peer decision evidence; path-specific retraction reason; a document-only claim after source deletion; source-retraction fixture.",
      exits: ~w(retracted)
    }
  ]

  @by_name Map.new(@contracts, &{&1.name, &1})
  @states Enum.map(@contracts, & &1.name)

  @doc "Returns public lifecycle state names in operator display order."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "Returns the complete contract for one state, or raises for an unknown state."
  @spec fetch!(String.t()) :: map()
  def fetch!(state), do: Map.fetch!(@by_name, state)

  @doc "Returns the operator meaning for one state."
  @spec meaning(String.t()) :: String.t() | nil
  def meaning(state) do
    case Map.fetch(@by_name, state) do
      {:ok, contract} -> contract.meaning
      :error -> nil
    end
  end

  @doc "Explains why a benchmark may legitimately omit one state."
  @spec absence_reason(String.t()) :: String.t()
  def absence_reason(state) do
    contract = fetch!(state)
    "not exercised: this state requires #{contract.fixture}"
  end

  @doc "Renders the canonical operator table published in the memory-model guide."
  @spec markdown_table() :: String.t()
  def markdown_table do
    header =
      "| State | Meaning | Entry and trigger | Actor or worker; queue | Stability; allowed exits | Visibility: subject / member / curator / admin | Search and `/ask` | Projection and skill readiness | Required evidence; example; fixture |\n" <>
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"

    rows =
      Enum.map_join(@contracts, "\n", fn contract ->
        "| `#{contract.name}` | #{contract.meaning} | #{contract.entry} | " <>
          "#{contract.actor_queue} | #{contract.lifecycle} | #{visibility_label(contract.visibility)} | " <>
          "#{retrieval_label(contract.retrieval)} | #{contract.downstream} | #{contract.evidence} |"
      end)

    header <> "\n" <> rows
  end

  @doc "Returns states ordinary authorized readers may enumerate in the console."
  @spec settled_states() :: [String.t()]
  def settled_states do
    for contract <- @contracts, contract.visibility == :all_authorized, do: contract.name
  end

  @doc "Returns whether the console may enumerate one state for the role/subject relation."
  @spec console_visible?(String.t(), boolean(), boolean()) :: boolean()
  def console_visible?(state, own_subject?, governor?) do
    case Map.fetch(@by_name, state) do
      {:ok, %{visibility: :all_authorized}} -> true
      {:ok, %{visibility: :subject_or_governor}} -> own_subject? or governor?
      {:ok, %{visibility: :subject_only}} -> own_subject?
      :error -> false
    end
  end

  @doc "Returns states that may enter ordinary memory retrieval before subject narrowing."
  @spec retrievable_states() :: [String.t()]
  def retrievable_states do
    for contract <- @contracts, contract.retrieval != :none, do: contract.name
  end

  @doc "Returns whether one state is retrievable for the reader and subject relationship."
  @spec retrievable?(String.t(), String.t() | nil, String.t() | nil, boolean()) :: boolean()
  def retrievable?(state, subject_peer_id, actor_peer_id, internal_reader?) do
    case Map.fetch(@by_name, state) do
      {:ok, %{retrieval: :all_authorized}} ->
        true

      {:ok, %{retrieval: :subject_only}} when internal_reader? ->
        true

      {:ok, %{retrieval: :subject_only}} ->
        is_binary(actor_peer_id) and subject_peer_id == actor_peer_id

      _other ->
        false
    end
  end

  @doc "Returns states eligible for Account- or scope-shared projections."
  @spec shared_projection_states() :: [String.t()]
  def shared_projection_states, do: ["active"]

  @doc "Returns states eligible for a subject-keyed peer projection."
  @spec peer_projection_states() :: [String.t()]
  def peer_projection_states, do: retrievable_states()

  @doc "Returns states readiness loads to distinguish usable evidence from lifecycle gaps."
  @spec readiness_observed_states() :: [String.t()]
  def readiness_observed_states, do: ~w(active provisional needs_revalidation expired)

  @doc "Returns whether the lifecycle graph documents one exact state edge."
  @spec allowed_transition?(String.t(), String.t()) :: boolean()
  def allowed_transition?(from_state, to_state) do
    case Map.fetch(@by_name, from_state) do
      {:ok, contract} -> to_state in contract.exits
      :error -> false
    end
  end

  defp visibility_label(:all_authorized), do: "Yes / yes / yes / yes when scope-authorized."
  defp visibility_label(:subject_or_governor), do: "Yes / no / yes / yes."
  defp visibility_label(:subject_only), do: "Yes / no / no / no for another subject."

  defp retrieval_label(:all_authorized),
    do: "Yes when scope, audience, sensitivity, and time filters pass."

  defp retrieval_label(:subject_only), do: "Subject only."
  defp retrieval_label(:none), do: "No."
end

defmodule MemHouse.Knowledge.Validations.AllowedLifecycleTransition do
  @moduledoc """
  Rejects lifecycle edges that the executable contract does not document.
  """

  use Ash.Resource.Validation

  alias MemHouse.Knowledge.Lifecycle

  @impl true
  def validate(changeset, _opts, _context) do
    from_state = changeset.data.state
    to_state = Ash.Changeset.get_attribute(changeset, :state)

    if Lifecycle.allowed_transition?(from_state, to_state) do
      :ok
    else
      {:error,
       field: :state, message: "undocumented lifecycle transition #{from_state} -> #{to_state}"}
    end
  end
end
