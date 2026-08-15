# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.Candidate do
  @moduledoc """
  One ranked hit produced by a single retrieval strategy.

  A candidate is always *strategy-local*. `score` is whatever that strategy's
  own scoring produces — a cosine similarity, a full-text rank, a time
  relevance step, a salience product — and those numbers are on unrelated
  scales. Never compare or threshold `score` across two strategies. Fusion
  normalizes each returned list before it combines scores.

  `record` is the database row already stripped of the raw score, and it is
  what eventually reaches the caller, so it must never be filled with anything
  the caller is not authorized to see. `evidence` is internal bookkeeping:
  a strategy stores its raw score there, and fusion replaces it with the set of
  strategies that voted for the candidate.

  After fusion the struct is reused with `strategy: :fusion`, `score` holding
  the score-aware fusion value, and `rank` renumbered over the merged list.
  """

  @enforce_keys [:id, :score, :rank, :strategy, :record]
  defstruct [:id, :score, :rank, :strategy, :record, evidence: %{}]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          score: float(),
          rank: pos_integer(),
          strategy: atom(),
          record: map(),
          evidence: map()
        }
end

defmodule MemHouse.Retrieval.Query do
  @moduledoc """
  The internal retrieval request: an already-authorized description of what to
  search for and where.

  This struct is not user input. By the time it is built, the caller has
  authenticated, the Account has been derived from that identity, and the list
  of scopes the actor may read has been resolved. Retrieval treats
  `account_id`, `actor`, and `scope_ids` as the authority boundary and filters
  every database statement by them, so populating `scope_ids` from an unchecked
  request parameter would hand the caller other people's memory.

  Fields:

  * `account_id` — the tenant. Every statement filters on it.
  * `actor` — the resolved caller. Its `peer_id` is the reader identity: it
    decides which `provisional` statements are visible (only those about that
    peer) and which personal ones are (again, only that peer's own). A
    peer-facing query with no `peer_id` reads public statements only.
  * `internal_reader?` — lifts the reader restriction entirely, for server-side
    work that must see the whole corpus: projection rebuild, dream-time, and
    the evaluation harness. It is never derived from request input, and it is
    not the `:internal?` option of `MemHouse.Retrieval.retrieve/3`, which only
    unlocks hand-picked strategy lists and grants no extra data. It defaults to
    false, so a construction site that forgets it loses recall rather than
    leaking.
  * `text` — the query string. Empty text makes the text-driven strategies
    report themselves inapplicable rather than returning everything.
  * `target` — `:knowledge`, `:documents`, or `:all`. Answer generation uses
    `:knowledge` so an answer cannot cite a document chunk as if it were a
    governed statement.
  * `as_of` — the explicit point in time that enables the time-relevance
    strategy. The store uses now only after this applicability gate has passed.
  * `min_score` — drops candidates below this strategy-local score. Because
    scores are not comparable across strategies, one value means different
    things to each of them; it is a coarse noise filter, not a relevance gate.
  * `source_filters` — provenance restrictions (provider, model, pipeline
    version, minimum corroboration, originating message, source document)
    applied before fusion, so filtered-out rows cannot influence ranking.
  * `query_embedding` — reserved for a caller-precomputed query vector. No
    shipped strategy reads it; the semantic strategy embeds `text` itself.
  * `scope_ids` — the authorized scopes, nearest first. Profile inheritance
    relies on that ordering to pick the nearest stored override.
  * `seed_ids` — filled in by the engine between phases. Expansion strategies
    read it; it is empty during the seed phase.
  * `max_candidates` — cap per strategy list and on the fused result.
  """

  defstruct [
    :account_id,
    :actor,
    :text,
    :target,
    :as_of,
    :min_score,
    :source_filters,
    :query_embedding,
    scope_ids: [],
    seed_ids: [],
    max_candidates: 50,
    internal_reader?: false
  ]

  @type t :: %__MODULE__{}
end

defmodule MemHouse.Retrieval.Budget do
  @moduledoc """
  The wall-clock deadline and candidate cap handed to every strategy.

  The budget is measured once, at the start of the whole request, and shared by
  all phases. It is a *total* ceiling covering seed strategies, expansion, and
  any model-backed reranking — not a per-strategy timeout — so work late in the
  request naturally gets whatever the earlier work left over. A strategy that
  runs past it is abandoned and reported as dropped; it is never retried,
  because a retry would spend the same budget the caller is already out of.

  `deadline?: false` disables the clock entirely (`remaining_ms/1` answers
  `:infinity`). That mode exists for evaluation runs and for dream-time
  projection rebuilds, where completeness matters and no caller is waiting. Do
  not use it on a request path: it removes the only bound on tail latency.

  `started_at` is a monotonic millisecond reading, so the budget is immune to
  system clock adjustments.
  """

  @enforce_keys [:started_at, :max_candidates]
  defstruct [:deadline_ms, :started_at, :max_candidates, deadline?: true]

  @type t :: %__MODULE__{}

  @doc """
  Returns the milliseconds left in the budget, clamped at zero, or `:infinity`
  when the deadline is disabled.

  Zero means "already out of time": callers use it to skip work rather than to
  start it with a zero timeout. Every call re-reads the monotonic clock, so two
  calls in the same request can return different values.
  """
  def remaining_ms(%__MODULE__{deadline?: false}), do: :infinity

  def remaining_ms(%__MODULE__{deadline_ms: deadline, started_at: started_at}) do
    max(deadline - (MemHouse.Clock.monotonic_ms() - started_at), 0)
  end
end

defmodule MemHouse.Retrieval.Strategy do
  @moduledoc """
  Defines retrieval strategy contracts and validates returned candidates.

  Strategies must filter Account, authorized scopes, lifecycle, and provisional subjects before
  returning candidates; nothing downstream rechecks access. Scores are strategy-local, budgets
  and caps are shared, and entity cache details must never escape. Expected absence degrades to an
  empty list.

  ## Callbacks

  * `name/0` — the stable atom used in profiles, weights, and the contributed
    and dropped lists reported to callers.
  * `cost_class/0` — `:cheap`, `:moderate`, or `:expensive`. Declarative today;
    it documents the relative price of running the strategy.
  * `stage/0` — `:seed` runs first against the query text; `:expand` runs
    afterwards and may only widen from the seed ids the first phase produced.
  * `query_dependent?/0` — whether the strategy reads `query.text`. When every
    query-dependent strategy comes back empty, what survives ranked the scope
    rather than the question, and retrieval reports that as its own signal.
    Answer "true" only for reading the text directly: a strategy that merely
    expands from seeds inherits whatever dependence the seeds had.
  * `applicable?/1` — cheap precondition check. Returning false means the
    strategy is skipped for this query rather than run and discarded.
  * `candidates/2` — the actual work, returning `Candidate` structs, or
    `{:error, reason}` when the strategy could not run at all. The two are not
    interchangeable: an empty list means the strategy searched and found
    nothing, an error means it never searched, and only the second is reported
    to the caller as a dropped strategy.
  """

  alias MemHouse.Retrieval.{Budget, Candidate, Query}

  @callback name() :: atom()
  @callback cost_class() :: :cheap | :moderate | :expensive
  @callback stage() :: :seed | :expand
  @callback query_dependent?() :: boolean()
  @callback applicable?(Query.t()) :: boolean()
  @callback candidates(Query.t(), Budget.t()) :: [Candidate.t()] | {:error, term()}

  @doc """
  Truncates, renumbers, and sanity-checks the candidates a strategy returned.

  This runs on every strategy result, including in production, because fusion
  depends on ranks being dense, 1-based, and assigned by the engine rather than
  self-reported: a strategy that numbered its own ranks could otherwise give
  itself extra fusion weight. It also stamps the owning strategy name onto each
  candidate and coerces integer scores to floats.

  `max_candidates` is the smaller of the query's cap and the budget's cap;
  anything beyond it is dropped.

  An `{:error, reason}` result passes through unchanged for the engine to report
  as a dropped strategy; there is nothing to rank.

  Raises `ArgumentError` when the module reports an unknown cost class or
  stage, or when a returned element is not a `Candidate` with a binary id, a
  numeric score, and a map record. Raising is deliberate: malformed candidates
  indicate a broken strategy, and silently skipping them would degrade recall
  invisibly.
  """
  def validate!(module, candidates, max_candidates)

  def validate!(module, {:error, reason}, _max_candidates) do
    validate_declarations!(module)
    {:error, reason}
  end

  def validate!(module, candidates, max_candidates) do
    name = module.name()
    validate_declarations!(module)

    candidates
    |> Enum.take(max_candidates)
    |> Enum.with_index(1)
    |> Enum.map(fn
      {%Candidate{id: id, score: score, record: record} = candidate, rank}
      when is_binary(id) and is_number(score) and is_map(record) ->
        %{candidate | rank: rank, strategy: name, score: score * 1.0}

      {invalid, _rank} ->
        raise ArgumentError,
              "#{inspect(module)} returned an invalid candidate: #{inspect(invalid)}"
    end)
  end

  defp validate_declarations!(module) do
    unless module.cost_class() in [:cheap, :moderate, :expensive],
      do: raise(ArgumentError, "#{inspect(module)} returned an invalid cost_class")

    unless module.stage() in [:seed, :expand],
      do: raise(ArgumentError, "#{inspect(module)} returned an invalid stage")

    :ok
  end
end
