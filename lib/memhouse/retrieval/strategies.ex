# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.StrategySupport do
  @moduledoc """
  Converts strategy rows to candidates after provenance and score filtering.

  Filtering occurs before fusion so excluded rows cannot affect rank. Survivors receive dense
  1-based ranks; local scores move to internal evidence and never reach caller records. Every
  strategy must use this path.
  """

  alias MemHouse.Retrieval.Candidate

  @doc """
  Converts raw result rows into `Candidate` structs for one strategy.

  `rows` are column-keyed maps as returned by the retrieval store. `strategy`
  is the owning strategy's name atom. `min_score` drops rows scoring below it
  on that strategy's own scale — the same number means something different to
  each strategy, so it is a coarse noise cut, not a relevance threshold.
  `source_filters` restricts candidates by provenance; keys may be atoms or
  strings, and a nil value for any key means "do not filter on this".

  Supports extractor `provider`/`model`, `pipeline_version`, inclusive
  `minimum_corroboration`, `source_message_id`, and `source_document_id`.

  Returns candidates ranked from 1 in the order the rows arrived, so the
  caller's `ORDER BY` decides the ranking.
  """
  def candidates(rows, strategy, min_score \\ 0.0, source_filters \\ %{}) do
    rows
    |> Enum.filter(
      &(source_allowed?(&1, source_filters || %{}) and
          (&1["score"] || 0.0) >= min_score)
    )
    |> Enum.with_index(1)
    |> Enum.map(fn {row, rank} ->
      %Candidate{
        id: row["id"],
        score: (row["score"] || 0.0) * 1.0,
        rank: rank,
        strategy: strategy,
        record: Map.drop(row, ["score"]),
        evidence: %{"raw_score" => row["score"] || 0.0}
      }
    end)
  end

  # All filters must pass; normalize request and internal keys to strings.
  defp source_allowed?(row, filters) do
    filters = Map.new(filters, fn {key, value} -> {to_string(key), value} end)

    matches?(row["extracting_provider"], filters["provider"]) and
      matches?(row["extracting_model"], filters["model"]) and
      matches?(row["pipeline_version"], filters["pipeline_version"]) and
      minimum?(row["corroboration_count"], filters["minimum_corroboration"]) and
      contains?(row["source_message_ids"], filters["source_message_id"]) and
      matches?(row["document_id"], filters["source_document_id"])
  end

  # Nil disables a filter; absent row values are empty or zero.
  defp matches?(_actual, nil), do: true
  defp matches?(actual, expected), do: actual == expected
  defp minimum?(_actual, nil), do: true
  defp minimum?(actual, expected), do: (actual || 0) >= expected
  defp contains?(_actual, nil), do: true
  defp contains?(actual, expected), do: expected in (actual || [])
end

defmodule MemHouse.Retrieval.Strategies.Semantic do
  @moduledoc """
  Embeds query text and finds nearest stored vectors.

  This moderate-cost seed strategy filters stored vectors by the Account's current provider,
  model, version, and dimensions. Older identities require re-embedding and are never mixed.
  """
  @behaviour MemHouse.Retrieval.Strategy

  alias MemHouse.Model.{Config, Embedding}
  alias MemHouse.Retrieval.{Store, StrategySupport}

  @impl true
  def name, do: :semantic
  @impl true
  def cost_class, do: :moderate
  @impl true
  def stage, do: :seed
  @impl true
  def query_dependent?, do: true

  @doc """
  True only for a non-blank query string.

  Blank text skips the provider call and arbitrary corpus neighborhood.
  """
  @impl true
  def applicable?(query), do: is_binary(query.text) and String.trim(query.text) != ""

  @doc """
  Embeds the query and returns the nearest authorized records.

  Embedding failure returns `{:error, reason}`, which the engine reports as a dropped strategy.
  Returning `[]` there would be indistinguishable from a corpus with no near neighbours, and the
  two call for opposite responses: fix the embedder, or accept the answer. Identity is resolved
  from the same Account role that embedded the query.
  """
  @impl true
  def candidates(query, budget) do
    context = %{account_id: query.account_id, actor: query.actor}

    case Embedding.embed([query.text], context, input_type: :query) do
      {:ok, %{vectors: [embedding]}} ->
        identity = :embedder |> Config.resolve(context) |> Config.embedding_identity()

        query
        |> Store.semantic(embedding, identity, budget.max_candidates)
        |> StrategySupport.candidates(
          name(),
          query.min_score || 0.0,
          query.source_filters
        )

      {:error, error} ->
        {:error, error}
    end
  end
end

defmodule MemHouse.Retrieval.Strategies.Lexical do
  @moduledoc """
  Word-based retrieval through PostgreSQL full-text search.

  A cheap indexed seed strategy for exact terms that semantic search may blur. Fusion balances
  its poor paraphrase recall.
  """
  @behaviour MemHouse.Retrieval.Strategy

  alias MemHouse.Retrieval.{Store, StrategySupport}

  @impl true
  def name, do: :lexical
  @impl true
  def cost_class, do: :cheap
  @impl true
  def stage, do: :seed
  @impl true
  def query_dependent?, do: true

  @doc "True only for a non-blank query string; there are no terms to match otherwise."
  @impl true
  def applicable?(query), do: is_binary(query.text) and String.trim(query.text) != ""

  @doc """
  Returns authorized statements and document chunks whose text matches the
  query terms, ranked by full-text relevance.

  The query target selects governed statements, document chunks, or both.
  """
  @impl true
  def candidates(query, budget) do
    query
    |> Store.lexical(budget.max_candidates)
    |> StrategySupport.candidates(name(), query.min_score || 0.0, query.source_filters)
  end
end

defmodule MemHouse.Retrieval.Strategies.Temporal do
  @moduledoc """
  Prefers statements in force at the query's reference time.

  Uses validity time, distinct from record time and salience. This cheap seed strategy needs no
  text or model and can still find superseded facts for historical queries.
  """
  @behaviour MemHouse.Retrieval.Strategy

  alias MemHouse.Retrieval.{Store, StrategySupport}

  @impl true
  def name, do: :temporal
  @impl true
  def cost_class, do: :cheap
  @impl true
  def stage, do: :seed
  @impl true
  def query_dependent?, do: false

  @doc """
  True only for an explicit point-in-time query that wants governed statements.

  `as_of` is the public temporal intent marker. Running this strategy for every
  ordinary question would add a query-independent list that can bury lexical
  evidence. Document chunks have no validity period, so document-only queries
  skip it too.
  """
  @impl true
  def applicable?(query), do: not is_nil(query.as_of) and query.target in [:knowledge, :all]

  @doc """
  Returns authorized statements scored by whether they were in force at the
  query's reference time, excluding those not yet recorded or already expired
  at that instant.
  """
  @impl true
  def candidates(query, budget) do
    query
    |> Store.temporal(budget.max_candidates)
    |> StrategySupport.candidates(name(), query.min_score || 0.0, query.source_filters)
  end
end

defmodule MemHouse.Retrieval.Strategies.SalienceRecency do
  @moduledoc """
  Query-independent ranking by how important and how fresh a statement is.

  Combines confidence, corroboration, and recency without text or a model. This cheap seed strategy
  supports context and degraded retrieval; fusion offsets its lack of query relevance.
  """
  @behaviour MemHouse.Retrieval.Strategy

  alias MemHouse.Retrieval.{Store, StrategySupport}

  @impl true
  def name, do: :salience_recency
  @impl true
  def cost_class, do: :cheap
  @impl true
  def stage, do: :seed
  @impl true
  def query_dependent?, do: false

  @doc """
  True only for a blank-text governed-memory request; chunks lack its scoring
  metadata. Text-bearing searches need query-dependent evidence at the head,
  while the blank-query path remains available for context fallback.

  A nil `text` is blank, not "not a query": the context fallback reaches this
  strategy with whatever the caller supplied, and treating nil as inapplicable
  would leave that path with no strategy at all.
  """
  @impl true
  def applicable?(query) do
    query.target in [:knowledge, :all] and String.trim(query.text || "") == ""
  end

  @doc """
  Returns authorized, unexpired statements ranked by confidence, corroboration,
  and recency of last update. The query text is not read at all.
  """
  @impl true
  def candidates(query, budget) do
    query
    |> Store.salience_recency(budget.max_candidates)
    |> StrategySupport.candidates(name(), query.min_score || 0.0, query.source_filters)
  end
end

defmodule MemHouse.Retrieval.Strategies.EntityMatch do
  @moduledoc """
  Finds statements through the private entity alias index.

  This cheap seed strategy uses derived names only to locate authorized statements. Entity ids,
  canonical names, aliases, and surface forms never leave retrieval. Stale cache costs recall,
  never access correctness.
  """
  @behaviour MemHouse.Retrieval.Strategy

  alias MemHouse.Retrieval.{Store, StrategySupport}

  @impl true
  def name, do: :entity_match
  @impl true
  def cost_class, do: :cheap
  @impl true
  def stage, do: :seed
  @impl true
  def query_dependent?, do: true

  @doc """
  True for governed statements with non-empty text; whitespace tokenizes to no candidates.
  """
  @impl true
  def applicable?(query), do: query.target in [:knowledge, :all] and query.text != ""

  @doc """
  Returns authorized statements that mention an entity whose canonical name or
  alias appears in the query text, scored by mention and statement confidence.
  """
  @impl true
  def candidates(query, budget) do
    query
    |> Store.entity_match(budget.max_candidates)
    |> StrategySupport.candidates(name(), query.min_score || 0.0, query.source_filters)
  end
end

defmodule MemHouse.Retrieval.Strategies.RelationExpand do
  @moduledoc """
  Expands one hop from seed statements.

  Follows statement relations, shared entity mentions, and scope relations without recursion.
  Both scope endpoints must already be authorized; links never grant access. Moderate-cost and
  enabled by the thorough profile.
  """
  @behaviour MemHouse.Retrieval.Strategy

  alias MemHouse.Retrieval.{Store, StrategySupport}

  @impl true
  def name, do: :relation_expand
  @impl true
  def cost_class, do: :moderate
  @impl true
  def stage, do: :expand

  @doc """
  False: expansion never reads the query text.

  It walks outward from whatever the seed phase produced, so it is only as
  query-relevant as those seeds were. Claiming otherwise would let a hop from a
  recency dump pass for evidence that the question was understood.
  """
  @impl true
  def query_dependent?, do: false

  @doc """
  True only when the query wants governed statements and the seed phase
  actually produced ids to expand from.

  The engine supplies seed ids between phases; no seeds means no expansion.
  """
  @impl true
  def applicable?(query), do: query.target in [:knowledge, :all] and query.seed_ids != []

  @doc """
  Returns authorized statements one hop from the seed set, scored by edge
  strength times the statement's own confidence.
  """
  @impl true
  def candidates(query, budget) do
    query
    |> Store.relation_expand(budget.max_candidates)
    |> StrategySupport.candidates(name(), query.min_score || 0.0, query.source_filters)
  end
end
