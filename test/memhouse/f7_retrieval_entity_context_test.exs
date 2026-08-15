# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.F7RetrievalEntityContextTest.Provider do
  @moduledoc """
  Deterministic, call-recording provider for retrieval tests.

  Structured generation, chat, and rerank delegate offline; embeddings use two
  keyword flags plus normalized text length so semantic order is predictable.
  A named Agent records calls, allowing context tests to prove the cached path
  is model-free. The singleton recorder requires synchronous tests.
  """

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Provider.Result
  alias MemHouse.Model.Providers.Deterministic

  @impl true
  def structured(config, messages, schema, opts) do
    record(:structured)
    Deterministic.structured(config, messages, schema, opts)
  end

  @impl true
  def chat(config, messages, opts) do
    record(:chat)

    if Keyword.get(opts, :task) == :entity_card do
      {:ok,
       %Result{
         value: "The billing service has three governed operational facts.",
         usage: %{input_tokens: 12, output_tokens: 8},
         metadata: %{fixture: true}
       }}
    else
      Deterministic.chat(config, messages, opts)
    end
  end

  # Interpretable dimensions make nearest-neighbor expectations explicit.
  @impl true
  def embed(_config, texts, _opts) do
    record(:embed)

    vectors =
      Enum.map(texts, fn text ->
        normalized = String.downcase(text)

        [
          if(String.contains?(normalized, "avery"), do: 1.0, else: 0.0),
          if(String.contains?(normalized, "release"), do: 1.0, else: 0.0),
          min(String.length(normalized) / 100.0, 1.0)
        ]
      end)

    {:ok,
     %Result{
       value: vectors,
       usage: %{embedding_tokens: length(texts)},
       metadata: %{fixture: true}
     }}
  end

  @impl true
  def rerank(config, query, documents, opts) do
    record(:rerank)
    Deterministic.rerank(config, query, documents, opts)
  end

  @doc "Starts the call recorder. One per node; the suite must be `async: false`."
  def start! do
    {:ok, _pid} = Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @doc "Clears the recorded calls. Call this right before the window you intend to assert on."
  def reset!, do: Agent.update(__MODULE__, fn _calls -> [] end)

  @doc "Returns the recorded capability atoms in call order (the agent stores them reversed)."
  def calls, do: Agent.get(__MODULE__, &Enum.reverse/1)

  @doc "Stops the recorder. Must run in `on_exit` so the next test starts from empty."
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> stop_if_alive(pid)
    end
  end

  # The recorder can die between the lookup above and the stop below, and an exit raised out of
  # `on_exit` would abandon the rest of teardown. Already stopped is the outcome asked for.
  defp stop_if_alive(pid) do
    Agent.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp record(call), do: Agent.update(__MODULE__, &[call | &1])
end

defmodule MemHouse.F7RetrievalEntityContextTest.VanishingProvider do
  @moduledoc """
  Failure-injection provider for rebuild transaction boundaries.

  Embed deletes the knowledge row due for indexing; structured generation
  deletes the entity due for folding. The subsequent write must fail while the
  separately committed usage event survives. Raw SQL performs the mid-provider
  deletion under the sandbox's Account RLS setting. Unused chat and rerank calls
  fail explicitly.
  """

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Provider.Result
  alias MemHouse.Repo

  @impl true
  def structured(_config, [%{content: content}], _schema, _opts) do
    canonical_name = content |> String.split("right=") |> List.last()

    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM entities WHERE canonical_name = $1", [
      canonical_name
    ])

    {:ok,
     %Result{
       value: %{"same_entity" => true},
       usage: %{input_tokens: 11, output_tokens: 1},
       metadata: %{}
     }}
  end

  @impl true
  def chat(_config, _messages, _opts), do: {:error, :not_supported}

  @impl true
  def embed(_config, texts, _opts) do
    Enum.each(texts, fn text ->
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM knowledge_items WHERE statement = $1", [
        text
      ])
    end)

    # Cosine 0.8 puts Oryon in the resolver's ambiguous adjudication band.
    vectors =
      Enum.map(texts, fn
        "Oryon" -> [0.8, 0.6, 0.0]
        _other -> [1.0, 0.0, 0.0]
      end)

    {:ok, %Result{value: vectors, usage: %{embedding_tokens: length(texts)}, metadata: %{}}}
  end

  @impl true
  def rerank(_config, _query, _documents, _opts), do: {:error, :not_supported}
end

defmodule MemHouse.F7RetrievalEntityContextTest.UnavailableEmbedderProvider do
  @moduledoc """
  Provider whose embedder is down and whose other capabilities are not.

  Used to prove that a failed embedding call degrades one strategy and is
  reported, rather than passing as a query that legitimately matched nothing.
  """

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Providers.Deterministic

  @impl true
  def structured(config, messages, schema, opts),
    do: Deterministic.structured(config, messages, schema, opts)

  @impl true
  def chat(config, messages, opts), do: Deterministic.chat(config, messages, opts)

  @impl true
  def embed(_config, _texts, _opts), do: {:error, :embedder_unavailable}

  @impl true
  def rerank(config, query, documents, opts),
    do: Deterministic.rerank(config, query, documents, opts)
end

defmodule MemHouse.F7RetrievalEntityContextTest.RerankFailureProvider do
  @moduledoc "Failure-injection provider for reranker outcome classification."

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Provider.Result
  alias MemHouse.Model.Providers.Deterministic

  @impl true
  def structured(config, messages, schema, opts),
    do: Deterministic.structured(config, messages, schema, opts)

  @impl true
  def chat(config, messages, opts), do: Deterministic.chat(config, messages, opts)

  @impl true
  def embed(config, texts, opts), do: Deterministic.embed(config, texts, opts)

  @impl true
  def rerank(config, query, documents, opts) do
    case Application.fetch_env!(:memhouse, :rerank_test_mode) do
      :complete ->
        Deterministic.rerank(config, query, documents, opts)

      :timeout ->
        Process.sleep(80)
        Deterministic.rerank(config, query, documents, opts)

      :provider_error ->
        {:error, :provider_down}

      :invalid ->
        {:ok, %Result{value: [%{index: 999, relevance_score: 1.0}], usage: %{}}}

      # Judges only the last document. A generation-backed reranker returning
      # fewer rankings than it was given is the common shape of a short answer.
      :partial ->
        {:ok,
         %Result{
           value: [%{index: length(documents) - 1, relevance_score: 0.9}],
           usage: %{}
         }}
    end
  end
end

defmodule MemHouse.F7RetrievalEntityContextTest.CardSummaryFailureProvider do
  @moduledoc """
  Provider whose entity-card summary call fails and whose other calls do not.

  Used to prove that one failed summary degrades its own card instead of
  discarding the embeddings and entity rows the same rebuild committed.
  """

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Providers.Deterministic

  @impl true
  def structured(config, messages, schema, opts),
    do: Deterministic.structured(config, messages, schema, opts)

  @impl true
  def chat(config, messages, opts) do
    if Keyword.get(opts, :task) == :entity_card do
      {:error, %Mint.TransportError{reason: :timeout}}
    else
      Deterministic.chat(config, messages, opts)
    end
  end

  # The deterministic provider refuses to embed, so indexing borrows the suite's fixture vectors.
  # The rebuild must reach its third stage for this failure injection to mean anything.
  @impl true
  def embed(config, texts, opts),
    do: MemHouse.F7RetrievalEntityContextTest.Provider.embed(config, texts, opts)

  @impl true
  def rerank(config, query, documents, opts),
    do: Deterministic.rerank(config, query, documents, opts)
end

defmodule MemHouse.F7RetrievalEntityContextTest.CardSummaryConcurrencyProvider do
  @moduledoc """
  Provider that records how many entity-card summary calls overlap.

  The provider seam is the only place this is observable: a refresh reports how
  many cards it wrote, never how it obtained them. Each summary call is held for
  a fixed interval so that calls which are allowed to overlap certainly do,
  rather than merely being able to.
  """

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Provider.Result
  alias MemHouse.Model.Providers.Deterministic

  # Unit: milliseconds. Long enough that two calls released together still overlap on a loaded CI
  # machine, short enough to keep a synchronous suite fast.
  @hold_ms 150

  @doc """
  Arms the provider with a zero call count. Returns `:ok`, discarding earlier counts.
  """
  def start! do
    case Agent.start(fn -> %{in_flight: 0, peak: 0} end, name: __MODULE__) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        Agent.update(__MODULE__, fn _ -> %{in_flight: 0, peak: 0} end)
    end
  end

  @doc """
  Disarms the provider. Safe to call when nothing is armed; always returns `:ok`.
  """
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> stop_if_alive(pid)
    end
  end

  # Same race as the recorder above: already stopped is the outcome asked for.
  defp stop_if_alive(pid) do
    Agent.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Returns the largest number of summary calls seen in flight together.

  Exits with `:noproc` when the provider is not armed.
  """
  def peak, do: Agent.get(__MODULE__, & &1.peak)

  @impl true
  def structured(config, messages, schema, opts),
    do: Deterministic.structured(config, messages, schema, opts)

  @impl true
  def chat(config, messages, opts) do
    if Keyword.get(opts, :task) == :entity_card do
      enter()
      Process.sleep(@hold_ms)
      leave()

      {:ok,
       %Result{
         value: "One governed summary.",
         usage: %{input_tokens: 4, output_tokens: 4},
         metadata: %{fixture: true}
       }}
    else
      Deterministic.chat(config, messages, opts)
    end
  end

  # The deterministic provider refuses to embed, so indexing borrows the suite's fixture vectors.
  @impl true
  def embed(config, texts, opts),
    do: MemHouse.F7RetrievalEntityContextTest.Provider.embed(config, texts, opts)

  @impl true
  def rerank(config, query, documents, opts),
    do: Deterministic.rerank(config, query, documents, opts)

  defp enter do
    Agent.update(__MODULE__, fn state ->
      in_flight = state.in_flight + 1
      %{in_flight: in_flight, peak: max(state.peak, in_flight)}
    end)
  end

  defp leave, do: Agent.update(__MODULE__, &%{&1 | in_flight: &1.in_flight - 1})
end

defmodule MemHouse.F7RetrievalEntityContextTest do
  @moduledoc """
  Pins retrieval, private entity caches, and reasoning-free context assembly.

  The suite protects strategy contracts, rank fusion, in-query authorization,
  entity invisibility, nearest-wins versioned profiles, internal-only raw
  strategy selection, enforced/reported deadlines, model-free cached context,
  and authorization at both cross-scope endpoints. Account/scope leakage or
  public entity data is a security failure.

  `f7-1` identifies retrieval and context behavior in search, ask, and context
  responses; changing it requires a changelog and updated evidence. The suite
  runs synchronously because it changes node-global retrieval/model settings
  and uses a singleton recorder.
  """

  use MemHouse.DataCase, async: false

  alias MemHouse.Actor
  alias MemHouse.Clock
  alias MemHouse.Context.Builder
  alias MemHouse.DataLayer
  alias MemHouse.Documents
  alias MemHouse.Governance.Engine, as: GovernanceEngine

  alias MemHouse.Knowledge.{
    Entity,
    EntityMention,
    KnowledgeItem,
    KnowledgeRelation,
    Projection
  }

  alias MemHouse.Identity
  alias MemHouse.Memory
  alias MemHouse.Observations.Session

  alias MemHouse.Retrieval.{
    Budget,
    Candidate,
    EntityResolver,
    Fusion,
    Indexer,
    Profile,
    Query
  }

  alias MemHouse.Retrieval.DiagnosticGrant
  alias MemHouse.Retrieval.Strategies
  alias MemHouse.Topology.{Scope, ScopeRelation}

  require Ash.Query

  # Every strategy MemHouse ships. Listing them here rather than reading a registry means a
  # newly added strategy makes this suite fail until someone states what it is and how it
  # behaves, which is the intended review prompt.
  @strategies [
    Strategies.Semantic,
    Strategies.Lexical,
    Strategies.Temporal,
    Strategies.SalienceRecency,
    Strategies.EntityMatch,
    Strategies.RelationExpand
  ]

  # Names both the scope-wide entity and the selective one, so the same text can be sent
  # through the search response and through the strategy directly and be compared.
  @entity_idf_query "What did Melanie say to Rivet"

  setup do
    original_provider = Application.get_env(:memhouse, :model_provider)
    original_roles = Application.fetch_env!(:memhouse, :model_roles)
    original_retrieval = Application.fetch_env!(:memhouse, :retrieval_profiles)

    # Three dimensions, matching the recording provider's hand-built vectors. Production uses
    # 384; the small space keeps semantic ranking predictable in assertions.
    roles =
      Keyword.update!(original_roles, :embedder, fn config ->
        config
        |> Map.put(:provider, "fixture")
        |> Map.put(:model, "f7-fixture")
        |> Map.put(:model_version, "1")
        |> Map.put(:embedding_dimensions, 3)
      end)

    Application.put_env(
      :memhouse,
      :model_provider,
      MemHouse.F7RetrievalEntityContextTest.Provider
    )

    Application.put_env(:memhouse, :model_roles, roles)
    MemHouse.F7RetrievalEntityContextTest.Provider.start!()

    # Retrieval profiles are restored too: one test deliberately sets a zero-millisecond
    # deadline, and leaving that in place would make every later test return nothing.
    # The application environment is restored before the recorder is stopped, and never after.
    # `:model_provider` is global: if teardown fails part-way with it still naming this module,
    # every later test that calls a model reaches a process that is gone, and one failure here
    # becomes dozens elsewhere.
    on_exit(fn ->
      Application.put_env(:memhouse, :model_roles, original_roles)
      Application.put_env(:memhouse, :retrieval_profiles, original_retrieval)

      if original_provider do
        Application.put_env(:memhouse, :model_provider, original_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end

      MemHouse.F7RetrievalEntityContextTest.Provider.stop()
    end)

    :ok
  end

  test "all shipped strategies satisfy the independent contract and profile stages" do
    assert Enum.map(@strategies, & &1.name()) == [
             :semantic,
             :lexical,
             :temporal,
             :salience_recency,
             :entity_match,
             :relation_expand
           ]

    # Cost class drives which strategies a deadline-bounded profile is willing to run.
    assert Enum.all?(@strategies, &(&1.cost_class() in [:cheap, :moderate, :expensive]))
    # Stage is an ordering constraint, not a label: seed strategies find candidates from the
    # query, expansion strategies walk outward from the seed head and therefore cannot run
    # until seeding finishes. Relation expansion is the one expansion strategy shipped.
    assert Enum.all?(@strategies, &(&1.stage() in [:seed, :expand]))
    assert Strategies.RelationExpand.stage() == :expand

    # Query dependence is what separates "found nothing about your question" from "ranked the
    # scope for you". Expansion is not query-dependent: it walks out from seeds that may
    # themselves have ignored the query, so counting it would launder that.
    assert Enum.all?(@strategies, &is_boolean(&1.query_dependent?()))
    assert Strategies.Semantic.query_dependent?()
    assert Strategies.Lexical.query_dependent?()
    assert Strategies.Temporal.query_dependent?()
    assert Strategies.EntityMatch.query_dependent?()
    refute Strategies.SalienceRecency.query_dependent?()
    refute Strategies.RelationExpand.query_dependent?()

    # Applicability must be a cheap, total predicate: it is consulted for every query, so it
    # cannot query the database or raise on an unusual query shape.
    query = %Query{text: "release", target: :knowledge, seed_ids: ["seed"]}
    assert Enum.all?(@strategies, &is_boolean(&1.applicable?(query)))
    refute Strategies.Temporal.applicable?(query)
    refute Strategies.SalienceRecency.applicable?(query)
    assert Strategies.Temporal.applicable?(%{query | as_of: DateTime.utc_now()})
    assert Strategies.SalienceRecency.applicable?(%{query | text: ""})

    # A nil query reaches the context fallback whenever a caller sends an explicit null. It is
    # the same blank request as "", and dropping it here would leave `:fast` with no strategy.
    assert Strategies.SalienceRecency.applicable?(%{query | text: nil})
  end

  test "micro-ablation keeps query-independent lists out of an ordinary search head" do
    target = candidate("answer", :lexical, 1)

    query_independent =
      for rank <- 1..40 do
        candidate("recent-#{rank}", :temporal, rank)
      end

    recency =
      for rank <- 1..40 do
        candidate("recent-#{rank}", :salience_recency, rank)
      end

    # This fixed fixture models the observed failure: one exact lexical answer
    # versus two full query-independent lists. Their agreeing distractors bury
    # the answer despite neither list reading the question.
    baseline =
      Fusion.reciprocal_rank(
        [lexical: [target], temporal: query_independent, salience_recency: recency],
        %{lexical: 1.0, temporal: 0.7, salience_recency: 0.8},
        50
      )

    proposed = Fusion.reciprocal_rank([lexical: [target]], %{lexical: 1.0}, 50)

    assert 32 == Enum.find_index(baseline, &(&1.id == target.id)) + 1
    assert 1 == Enum.find_index(proposed, &(&1.id == target.id)) + 1
  end

  test "fused separation is bounded by the fusion constant, not by how well anything matched" do
    profiles = Application.fetch_env!(:memhouse, :retrieval_profiles)
    k = Keyword.fetch!(profiles, :rrf_k)
    %{strategies: strategies, weights: weights} = Keyword.fetch!(profiles, :balanced)
    total_weight = strategies |> Enum.map(&Map.get(weights, &1, 1.0)) |> Enum.sum()

    # Unanimous rank 1 is the best any candidate can ever score, and unanimous rank 4 is still
    # a strong result. Every strategy returns both, so the pair differs only in rank.
    lists =
      for strategy <- strategies do
        {strategy, [candidate("best", strategy, 1), candidate("fourth", strategy, 4)]}
      end

    [top, next] = Fusion.reciprocal_rank(lists, weights, 10)

    assert top.id == "best"
    assert next.id == "fourth"

    # Both bounds are functions of `rrf_k` and the profile weights alone. No corpus, embedding,
    # or analyzer change can widen them, so the ceiling is a property of the merge rather than
    # of the match.
    assert_in_delta top.score, total_weight / (k + 1), 1.0e-12
    assert_in_delta next.score, total_weight / (k + 4), 1.0e-12

    # Three whole rank positions of unanimous disagreement move the score by a few percent, so
    # the ordering a caller sees is close to a tie however certain a strategy was.
    assert (top.score - next.score) / top.score < 0.05
  end

  test "an ordinary question keeps lexical evidence in the default top twelve" do
    answer =
      seed_active!(
        "f7-query-independent-head",
        "/f7/query-independent-head",
        "The Polaris envelope is approved for the northbound route."
      )

    for number <- 1..40 do
      seed_active!(
        "f7-query-independent-head",
        "/f7/query-independent-head",
        "Recent operations note #{number}: routine status remains green.",
        "irrelevant-#{number}"
      )
    end

    # This is an integration corpus, not a model benchmark: the lexical answer
    # has to remain visible even when a full recency-shaped corpus exists.
    result =
      Memory.search(%{
        "account_key" => "f7-query-independent-head",
        "scope_path" => answer.scope.path,
        "query" => "Which route has the Polaris envelope?",
        "deadline" => "disabled"
      })

    answer_rank = Enum.find_index(result["candidates"], &(&1["id"] == answer.knowledge.id))

    assert is_integer(answer_rank) and answer_rank < 12
    refute "temporal" in result["contributed_strategies"]
    refute "salience_recency" in result["contributed_strategies"]
  end

  test "a candidate does not derive valid time from observation time" do
    # The observation time only says when MemHouse learned the event. Search
    # exposes the validity fields without inventing a date that the source did
    # not establish.
    seeded =
      seed_active!(
        "f7-validity",
        "/f7/validity",
        "After orientation, Caroline joined a mentorship program.",
        "session-1",
        occurred_at: "2023-07-17T14:31:00Z"
      )

    result =
      Memory.search(%{
        "account_key" => "f7-validity",
        "scope_path" => seeded.scope.path,
        "query" => "When did Caroline join a mentorship program?",
        "deadline" => "disabled"
      })

    assert [candidate | _] = result["candidates"]
    assert candidate["id"] == seeded.knowledge.id
    assert candidate["kind"] == "event"

    assert candidate["relevant_from"] == nil
    assert Map.has_key?(candidate, "relevant_until")
  end

  test "semantic, lexical, temporal, and salience candidates fuse with pinned identity" do
    seeded = seed_active!("f7-fusion", "/f7/fusion", "Avery prefers concise release summaries.")

    # Vectors and full-text data are a rebuildable cache. Rebuilding the scope explicitly
    # keeps the test independent of background job timing.
    assert {:ok, %{indexed: 1}} = Indexer.rebuild_scope(seeded.account.id, seeded.scope.id)

    result =
      Memory.search(%{
        "account_key" => "f7-fusion",
        "scope_path" => seeded.scope.path,
        "query" => "Avery release summaries",
        # Deadlines off: this test is about fusion, and a timing-sensitive assertion would
        # be flaky on a loaded CI machine. Deadline behaviour has its own test below.
        "deadline" => "disabled"
      })

    assert result["profile"] == "balanced"
    assert result["profile_version"] == "f7-1"
    # Nothing was dropped, so the result set is complete — this is what makes the following
    # candidate assertions meaningful rather than accidental.
    assert result["dropped_strategies"] == []
    assert "semantic" in result["contributed_strategies"]
    assert "lexical" in result["contributed_strategies"]

    # Contributing means "returned candidates", so a strategy cannot be in both lists, and
    # the strategies that read the query text are the ones that answered it.
    refute "semantic" in result["empty_strategies"]
    refute "lexical" in result["empty_strategies"]
    refute result["disagreement"]["query_dependent_empty"]

    # The same statement found by two independent strategies is reported once, carrying the
    # list of strategies that found it. Callers use that as an agreement signal.
    assert [%{"id" => id, "strategies" => strategies} | _] = result["candidates"]
    assert id == seeded.knowledge.id
    assert "semantic" in strategies
    assert "lexical" in strategies

    # Source filters are applied inside retrieval, before fusion. Filtering on a model that
    # did not extract this item must remove it entirely, not merely rank it lower.
    assert [] ==
             Memory.search(%{
               "account_key" => "f7-fusion",
               "scope_path" => seeded.scope.path,
               "query" => "Avery release summaries",
               "strategies" => ["lexical"],
               "source_filters" => %{"model" => "not-the-extracting-model"},
               "deadline" => "disabled"
             })["candidates"]

    # The column is a real pgvector `vector`, not a float array stand-in. Only the true type
    # can use the approximate-nearest-neighbour index; an array would silently fall back to a
    # full scan and quietly become unusable as the corpus grows.
    assert %{rows: [["vector", 3]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT pg_typeof(embedding)::text, vector_dims(embedding)
               FROM knowledge_items
               WHERE id = $1
               """,
               [Ecto.UUID.dump!(seeded.knowledge.id)]
             )
  end

  test "lexical retrieval answers a question that no single statement repeats in full" do
    target =
      seed_active!(
        "f7-question",
        "/f7/question",
        "Avery publishes the release notes every Friday."
      )

    # Shares two query words with the question instead of four, so it belongs in the result
    # set but must not outrank the statement that answers it.
    distractor =
      seed_active!("f7-question", "/f7/question", "Avery reviewed the notes.", "session-2")

    unrelated =
      seed_active!(
        "f7-question",
        "/f7/question",
        "Saturday is the production deployment window.",
        "session-3"
      )

    result =
      Memory.search(%{
        "account_key" => "f7-question",
        "scope_path" => target.scope.path,
        # "day" appears in no statement. A conjunctive parse requires every content word to
        # occur in one sentence, which a one-sentence statement almost never satisfies, so
        # the lane returned nothing for any question phrased like this one.
        "query" => "Which day does Avery publish the release notes?",
        # Lexical alone: fusion with another strategy could otherwise supply the candidate
        # this assertion is about.
        "strategies" => ["lexical"],
        "deadline" => "disabled"
      })

    ids = Enum.map(result["candidates"], & &1["id"])

    assert target.knowledge.id in ids
    assert Enum.all?(result["candidates"], &("lexical" in &1["strategies"]))

    # Sharing more of the question's words has to rank higher; matching any word at all is
    # only useful if density still decides the order.
    assert Enum.find_index(ids, &(&1 == target.knowledge.id)) <
             Enum.find_index(ids, &(&1 == distractor.knowledge.id))

    refute unrelated.knowledge.id in ids
  end

  test "websearch phrase and negation operators still constrain lexical matching" do
    friday =
      seed_active!(
        "f7-operators",
        "/f7/operators",
        "Avery publishes the release notes every Friday."
      )

    mention =
      seed_active!(
        "f7-operators",
        "/f7/operators",
        "The release notes mention Avery.",
        "session-2"
      )

    lexical_ids = fn query ->
      %{"account_key" => "f7-operators", "scope_path" => friday.scope.path}
      |> Map.merge(%{"query" => query, "strategies" => ["lexical"], "deadline" => "disabled"})
      |> Memory.search()
      |> Map.fetch!("candidates")
      |> Enum.map(& &1["id"])
    end

    # Both statements share words with the phrase, so only phrase semantics can separate them.
    phrase = lexical_ids.(~s("release notes every Friday"))
    assert friday.knowledge.id in phrase
    refute mention.knowledge.id in phrase

    negated = lexical_ids.("Avery -Friday")
    assert mention.knowledge.id in negated
    refute friday.knowledge.id in negated
  end

  test "document chunks answer question-shaped lexical queries like statements do" do
    seeded = seed_active!("f7-chunks", "/f7/chunks", "Orchid keeps a release handbook.")

    assert {:ok, %{version: version}} =
             Documents.ingest_bytes(pipeline_actor(seeded.actor), %{
               scope_id: seeded.scope.id,
               external_id: "release-handbook",
               title: "Release handbook",
               media_type: "text/markdown",
               bytes: "Avery publishes the release notes every Friday."
             })

    # Chunks and their vectors are derived caches built by the processing job; running it
    # inline keeps the assertion independent of job scheduling.
    assert {:ok, _processed} =
             Documents.process_version_for_account(version.id, seeded.account.id)

    result =
      Memory.search(%{
        "account_key" => "f7-chunks",
        "scope_path" => seeded.scope.path,
        "query" => "Which day does Avery publish the release notes?",
        "strategies" => ["lexical"],
        "_retrieval_target" => "documents",
        "deadline" => "disabled"
      })

    assert [%{"statement" => statement, "strategies" => ["lexical"]} | _] = result["candidates"]
    assert statement =~ "release notes"
  end

  test "a run where no query-reading strategy matched is reported as query-independent" do
    # Deliberately skip Indexer.rebuild_scope and EntityResolver.rebuild_scope. Both caches are
    # rebuildable and are populated by background jobs, so this is the state a real deployment
    # sits in between ingest and the next rebuild — not an artificial one.
    seeded =
      seed_active!("f7-degraded", "/f7/degraded", "Avery prefers concise release summaries.")

    result =
      Memory.search(%{
        "account_key" => "f7-degraded",
        "scope_path" => seeded.scope.path,
        # None of these words occur in the corpus, so full-text search cannot match either.
        "query" => "kayak tariff schedule",
        "deadline" => "disabled"
      })

    # Three strategies read the query text. Every one of them came back with nothing: semantic
    # has no vectors to compare, entity matching has no resolved mentions, and full-text search
    # found no term in common.
    assert Enum.sort(result["empty_strategies"]) == ["entity_match", "lexical", "semantic"]
    assert result["contributed_strategies"] == []

    # Running and finding nothing is not degradation. Nothing was disabled, timed out, or
    # failed, so the dropped list stays empty and keeps its narrower meaning.
    assert result["dropped_strategies"] == []

    # The point of the flag: no query-reading strategy found evidence. Ordinary
    # text searches no longer fill that absence with a scope-ranked list.
    #
    # These two also pin the signal to pre-fusion. Fusion always emits a ranked
    # list, so anything derived from the fused output could not report "nothing was found"
    # while candidates are being returned. They can only hold together if it was measured
    # before the merge.
    assert result["disagreement"]["query_dependent_empty"]
    assert result["candidates"] == []

    # The pre-existing signals cannot express this state, which is why the new one exists.
    # All three read only the strategies that returned something, and here nothing did, so
    # they collapse to their documented empty-list values: `low_score` is vacuously true over
    # no lists, `disjoint` is false because there is no pair to overlap, and `strategy_count`
    # counts what survived rather than what vanished. Only `query_dependent_empty`
    # distinguishes this run from one that never had a query-reading strategy enabled.
    assert result["disagreement"]["low_score"]
    refute result["disagreement"]["disjoint"]
    assert result["disagreement"]["strategy_count"] == 0
  end

  test "an explicit as_of query retains temporal recall" do
    seeded = seed_active!("f7-as-of", "/f7/as-of", "Avery led the 2025 migration.")

    seeded.knowledge
    |> Ash.Changeset.for_update(:transition, %{
      state: "active",
      relevant_from: ~U[2025-01-01 00:00:00Z],
      reason: "f7_test_date",
      channel: "pipeline"
    })
    |> Ash.update!(actor: pipeline_actor(seeded.actor))

    result =
      Memory.search(%{
        "account_key" => "f7-as-of",
        "scope_path" => seeded.scope.path,
        "query" => "Who led the migration?",
        "as_of" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "strategies" => ["temporal"],
        "deadline" => "disabled"
      })

    assert result["contributed_strategies"] == ["temporal"]
    assert [%{"id" => id}] = result["candidates"]
    assert id == seeded.knowledge.id
  end

  test "lexical ranks a target above distractors that share only part of the query" do
    corpus = seed_ranking_corpus!()

    result =
      Memory.search(%{
        "account_key" => "f7-rank",
        "scope_path" => "/f7/rank",
        # Every content word of the query appears in the target statement; each distractor
        # holds a strict subset. Ranking, not membership, is what separates them.
        "query" => "Avery release checklist",
        # Lexical alone, so the ordering asserted below is the lexical predicate's own and
        # cannot be supplied by a strategy that ignores the query text.
        "strategies" => ["lexical"],
        "deadline" => "disabled"
      })

    ids = Enum.map(result["candidates"], & &1["id"])

    assert [%{"id" => head_id, "strategies" => strategies} | _] = result["candidates"]
    assert head_id == corpus.target.knowledge.id
    # The per-candidate attribution identifies which strategies found this statement;
    # `contributed_strategies` only identifies which strategies returned any candidate.
    assert "lexical" in strategies

    # Sharing no query term is the one thing that must keep a statement out of the lexical
    # list. Were that to fail, the ordering above would be measuring an unfiltered scan.
    refute corpus.unrelated.knowledge.id in ids

    # Whichever partial-overlap distractors the predicate admits, none may outrank the only
    # statement carrying every query term.
    for distractor <- [corpus.shared_person_and_artifact, corpus.shared_artifact],
        distractor.knowledge.id in ids do
      assert Enum.find_index(ids, &(&1 == corpus.target.knowledge.id)) <
               Enum.find_index(ids, &(&1 == distractor.knowledge.id))
    end
  end

  test "lexical question analysis ranks supplied terms above unrelated expansions" do
    melanie =
      seed_active!(
        "f7-question-ranking",
        "/f7/question-ranking",
        "Melanie runs regularly as a way to destress.",
        "ranking-melanie"
      )

    pottery =
      seed_active!(
        "f7-question-ranking",
        "/f7/question-ranking",
        "Therapeutic pottery helps Caroline relax after difficult days.",
        "ranking-pottery"
      )

    caroline =
      seed_active!(
        "f7-question-ranking",
        "/f7/question-ranking",
        "Caroline joined a mentorship program in March 2024.",
        "ranking-caroline"
      )

    Enum.each(1..20, fn index ->
      seed_active!(
        "f7-question-ranking",
        "/f7/question-ranking",
        "Melanie and Caroline discussed what the team does during conversation #{index}.",
        "ranking-noise-#{index}"
      )
    end)

    search = fn query ->
      Memory.search(%{
        "account_key" => "f7-question-ranking",
        "scope_path" => melanie.scope.path,
        "query" => query,
        "strategies" => ["lexical"],
        "deadline" => "disabled"
      })
    end

    melanie_ids =
      search.("What does Melanie do to destress?")
      |> Map.fetch!("candidates")
      |> Enum.map(& &1["id"])

    caroline_ids =
      search.("When did Caroline join a mentorship program?")
      |> Map.fetch!("candidates")
      |> Enum.map(& &1["id"])

    assert Enum.find_index(melanie_ids, &(&1 == melanie.knowledge.id)) < 12
    refute pottery.knowledge.id in melanie_ids
    assert Enum.find_index(caroline_ids, &(&1 == caroline.knowledge.id)) < 12

    assert %{
             lexical_analyzer: "lexical-question-v2",
             query_search_list_size: 100,
             query_rescore: 50
           } = MemHouse.Retrieval.Diagnostics.latest(melanie.account.id)
  end

  test "lexical question analysis preserves quoted phrases, negation, dates, and safe empty input" do
    quoted =
      seed_active!(
        "f7-question-safety",
        "/f7/question-safety",
        "Melanie recorded the release notes on 2024-03-05.",
        "safety-quoted"
      )

    excluded =
      seed_active!(
        "f7-question-safety",
        "/f7/question-safety",
        "Melanie recorded draft release notes on 2024-03-05.",
        "safety-excluded"
      )

    search = fn query ->
      Memory.search(%{
        "account_key" => "f7-question-safety",
        "scope_path" => quoted.scope.path,
        "query" => query,
        "strategies" => ["lexical"],
        "deadline" => "disabled"
      })["candidates"]
      |> Enum.map(& &1["id"])
    end

    assert quoted.knowledge.id in search.(~s("release notes" 2024-03-05 -draft))
    refute excluded.knowledge.id in search.(~s("release notes" 2024-03-05 -draft))
    assert search.("what does the to ??? & | ;") == []
  end

  test "lexical proximity bonus separates statements the cover-density rank scores identically" do
    # Both statements carry `melani` and `destress` once, so `ts_rank_cd` over the disjunction
    # scores them the same and only the proximity bonus can order them. The nearer statement is
    # seeded first, so the `inserted_at DESC` tiebreak would put the distant one first if the
    # bonus contributed nothing.
    near =
      seed_active!(
        "f7-question-proximity",
        "/f7/question-proximity",
        "Melanie chose destress walks during the quiet spring evenings.",
        "proximity-near"
      )

    far =
      seed_active!(
        "f7-question-proximity",
        "/f7/question-proximity",
        "Melanie kept a long steady weekly journal about many other unrelated topics and later learned to destress.",
        "proximity-far"
      )

    ids =
      Memory.search(%{
        "account_key" => "f7-question-proximity",
        "scope_path" => near.scope.path,
        "query" => "What does Melanie do to destress?",
        "strategies" => ["lexical"],
        "deadline" => "disabled"
      })["candidates"]
      |> Enum.map(& &1["id"])

    assert Enum.find_index(ids, &(&1 == near.knowledge.id)) <
             Enum.find_index(ids, &(&1 == far.knowledge.id))
  end

  test "fusion ranks the query-matching target above distractors a newer statement outranks" do
    corpus = seed_ranking_corpus!()

    result =
      Memory.search(%{
        "account_key" => "f7-rank",
        "scope_path" => "/f7/rank",
        "query" => "Avery release checklist",
        "deadline" => "disabled"
      })

    ids = Enum.map(result["candidates"], & &1["id"])

    # The whole corpus is reachable, so the positions below compare candidates that were all
    # available to be ranked first.
    assert length(ids) == 5

    assert [%{"id" => head_id, "strategies" => strategies} | _] = result["candidates"]
    assert head_id == corpus.target.knowledge.id
    assert "semantic" in strategies
    assert "lexical" in strategies

    # The target was seeded first, so recency-ordered strategies rank it last of the five.
    # Its head position therefore comes from the query-dependent strategies outweighing them,
    # which is the agreement signal fusion exists to produce.
    target_rank = Enum.find_index(ids, &(&1 == corpus.target.knowledge.id))

    for distractor <- [
          corpus.shared_person_and_artifact,
          corpus.shared_artifact,
          corpus.shared_person,
          corpus.unrelated
        ] do
      assert target_rank < Enum.find_index(ids, &(&1 == distractor.knowledge.id))
    end
  end

  test "a diagnostic run can explain local, fused, and reranked ranks" do
    corpus = seed_ranking_corpus!()
    admin = %{corpus.target.actor | identity_kind: :password, role: :account_admin}

    attrs = %{
      "scope_path" => corpus.target.scope.path,
      "query" => "Avery release checklist",
      "profile" => "thorough",
      "deadline" => "disabled"
    }

    traced = Memory.diagnostic_search(Map.put(attrs, "trace", true), admin)

    assert %{"candidates" => trace_candidates} = traced["diagnostic_trace"]
    assert Enum.map(trace_candidates, & &1["id"]) == Enum.map(traced["candidates"], & &1["id"])

    assert target = Enum.find(trace_candidates, &(&1["id"] == corpus.target.knowledge.id))
    assert is_integer(target["fused_rank"])
    assert is_integer(target["final_rank"])
    assert target["rerank_status"] in ["reranked", "outside_rerank_head"]

    assert Enum.any?(target["strategies"], fn strategy ->
             strategy["strategy"] == "lexical" and is_integer(strategy["local_rank"]) and
               is_number(strategy["local_score"]) and is_number(strategy["fusion_contribution"])
           end)

    # The explanation is opt-in, and asking for it is the only difference: the
    # same diagnostic run without it returns the same candidates in the same
    # order, so reading the ranking cannot change it.
    untraced = Memory.diagnostic_search(attrs, admin)

    refute Map.has_key?(untraced, "diagnostic_trace")

    assert Enum.map(untraced["candidates"], & &1["id"]) ==
             Enum.map(traced["candidates"], & &1["id"])
  end

  test "only a password-authenticated account administrator may run a diagnostic" do
    corpus = seed_ranking_corpus!()
    admin = %{corpus.target.actor | identity_kind: :password, role: :account_admin}

    attrs = %{
      "scope_path" => corpus.target.scope.path,
      "query" => "Avery release checklist",
      "trace" => true
    }

    assert_raise Ash.Error.Forbidden, fn ->
      Memory.diagnostic_search(attrs, %{admin | role: :member})
    end

    assert_raise Ash.Error.Forbidden, fn ->
      Memory.diagnostic_search(attrs, %{admin | identity_kind: :api_key})
    end

    # A caller that reaches the ordinary facade cannot name the grant itself:
    # the key exists, but only a struct satisfies it and a request body carries
    # plain data.
    forged =
      Memory.search(
        Map.merge(attrs, %{"_diagnostic" => %{"trace?" => true, "limit" => 100}}),
        admin
      )

    refute Map.has_key?(forged, "diagnostic_trace")
  end

  test "relation expansion traverses knowledge relations and shared-entity edges" do
    first = seed_active!("f7-expand", "/f7/expand", "Orchid uses an append-only ledger.")

    second =
      seed_active!(
        "f7-expand",
        "/f7/expand",
        "Saturday is the production deployment window.",
        "session-2"
      )

    DataLayer.with_account_key("f7-expand", fn account, actor ->
      create!(
        KnowledgeRelation,
        :create_from_pipeline,
        %{
          scope_id: first.scope.id,
          source_knowledge_id: first.knowledge.id,
          target_knowledge_id: second.knowledge.id,
          kind: "supports",
          confidence: 0.9
        },
        account.id,
        pipeline_actor(actor)
      )
    end)

    result =
      Memory.search(%{
        "account_key" => "f7-expand",
        "scope_path" => "/f7/expand",
        # The query mentions only the first statement. The second shares no keywords and no
        # embedding signal, so it can only arrive by traversing the relation just created.
        "query" => "Orchid append-only ledger",
        "profile" => "thorough",
        "strategies" => ["lexical", "relation_expand"],
        "deadline" => "disabled"
      })

    assert second.knowledge.id in Enum.map(result["candidates"], & &1["id"])
    assert "relation_expand" in result["contributed_strategies"]

    assert %{component: "reranker", status: "completed", reason_class: nil} =
             Enum.find(result["retrieval_outcomes"], &(&1.component == "reranker"))
  end

  test "shared-entity expansion yields one row per neighbour, at its strongest edge" do
    seed = seed_active!("f7-hub", "/f7/hub", "Avery signed off on the Orchid ledger.")

    neighbour =
      seed_active!(
        "f7-hub",
        "/f7/hub",
        "Melanie reviewed the Orchid ledger rollout.",
        "hub-session"
      )

    DataLayer.with_account_key("f7-hub", fn account, actor ->
      pipeline = pipeline_actor(actor)

      entity =
        create!(
          Entity,
          :create_from_pipeline,
          %{
            canonical_name: "orchid ledger",
            kind: "system",
            aliases: ["orchid ledger"],
            derived_from: [seed.knowledge.id, neighbour.knowledge.id]
          },
          account.id,
          pipeline
        )

      # Two surface forms on one seed is what multiplies the neighbour: each pairing produces a
      # different edge score, so deduplicating on the pair keeps both. A hub entity is the same
      # shape at scale, which is why the branch has to collapse to the neighbour itself.
      for {surface_form, confidence} <- [{"Orchid ledger", 0.4}, {"the ledger", 0.9}] do
        create!(
          EntityMention,
          :create_from_pipeline,
          %{
            knowledge_item_id: seed.knowledge.id,
            scope_id: seed.scope.id,
            entity_id: entity.id,
            surface_form: surface_form,
            confidence: confidence
          },
          account.id,
          pipeline
        )
      end

      create!(
        EntityMention,
        :create_from_pipeline,
        %{
          knowledge_item_id: neighbour.knowledge.id,
          scope_id: neighbour.scope.id,
          entity_id: entity.id,
          surface_form: "Orchid ledger",
          confidence: 1.0
        },
        account.id,
        pipeline
      )
    end)

    query = %Query{
      account_id: seed.account.id,
      actor: seed.actor,
      text: "",
      target: :knowledge,
      scope_ids: [seed.scope.id],
      seed_ids: [seed.knowledge.id]
    }

    rows = MemHouse.Retrieval.Store.relation_expand(query, 50)

    assert [%{"score" => score, "confidence" => confidence}] = rows
    assert hd(rows)["id"] == neighbour.knowledge.id

    # The weaker 0.4 mention shares the neighbour with the 0.9 one, so it can only lower the
    # score or add a row. It must do neither.
    assert_in_delta score, 0.9 * confidence, 0.000001
  end

  test "each retrieval component reports its own elapsed time as a measurement" do
    seeded = seed_active!("f7-timing", "/f7/timing", "Avery owns the release checklist.")

    assert {:ok, %{indexed: 1}} = Indexer.rebuild_scope(seeded.account.id, seeded.scope.id)

    events = attach_component_telemetry!()

    Memory.search(%{
      "account_key" => "f7-timing",
      "scope_path" => "/f7/timing",
      "query" => "release checklist",
      "profile" => "balanced"
    })

    # Elapsed time already travelled as `:outcomes` metadata, where a metrics reporter cannot
    # summarise it. As a measurement on its own event it is aggregatable per component, which is
    # what turns "the request took 855 ms" into "this strategy took 855 ms".
    assert_receive {^events, %{elapsed_ms: elapsed_ms},
                    %{
                      account_id: account_id,
                      profile: profile,
                      component: "lexical",
                      status: status,
                      reason_class: reason_class
                    }}

    assert is_integer(elapsed_ms) and elapsed_ms >= 0
    assert account_id == seeded.account.id
    assert profile == "balanced"
    assert status in ["completed", "dropped"]
    # reason_class is nil for completed, or a string for dropped/degraded
    assert is_nil(reason_class) or is_binary(reason_class)
  end

  test "entity resolution is internal, alias retrieval is scoped, and public surfaces stay opaque" do
    seeded = seed_active!("f7-entity", "/f7/entity", "Avery owns the release checklist.")

    # Entity resolution runs as a background rebuild over governed statements. It is invoked
    # directly here so the assertions do not depend on job scheduling.
    assert {:ok, %{mentions: mentions}} =
             EntityResolver.rebuild_scope(seeded.account.id, seeded.scope.id)

    assert mentions >= 1

    # Give the resolved entity a short alias. Aliases are internal recall aids: they must be
    # usable as a query and must never be returned to a caller. Writing one requires the
    # pipeline actor because the cache has no externally reachable write action.
    DataLayer.with_account_key("f7-entity", fn account, actor ->
      pipeline = pipeline_actor(actor)

      entity =
        Entity
        |> Ash.Query.filter(canonical_name == "Avery")
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: pipeline)

      entity
      |> Ash.Changeset.for_update(:recompute_from_pipeline, %{aliases: ["Avery", "Av"]})
      |> Ash.Changeset.set_tenant(account.id)
      |> Ash.update!(actor: pipeline, authorize?: false)
    end)

    # Searching the alias finds the statement: the cache widens recall as intended.
    result =
      Memory.search(%{
        "account_key" => "f7-entity",
        "scope_path" => "/f7/entity",
        "query" => "Av",
        "strategies" => ["entity_match"],
        "deadline" => "disabled"
      })

    assert [%{"id" => id} = candidate | _] = result["candidates"]
    assert id == seeded.knowledge.id
    # ...but the candidate exposes nothing about the entity that matched. Entity rows are a
    # derived, pipeline-internal cache; disclosing names, aliases, or ids would create a
    # second, ungoverned view of who and what an account knows about.
    refute Map.has_key?(candidate, "canonical_name")
    refute Map.has_key?(candidate, "aliases")
    refute Map.has_key?(candidate, "entity_id")

    # Enforced structurally, not just by response shaping: these attributes are not public on
    # the resources, so no generic API surface can serialize them by accident.
    refute :canonical_name in Enum.map(Ash.Resource.Info.public_attributes(Entity), & &1.name)
    refute :aliases in Enum.map(Ash.Resource.Info.public_attributes(Entity), & &1.name)

    refute :surface_form in Enum.map(
             Ash.Resource.Info.public_attributes(EntityMention),
             & &1.name
           )

    # And no HTTP route addresses entities at all. Substring match on purpose: it also
    # catches "entities" and "entity_mentions".
    refute Enum.any?(MemHouseWeb.Router.__routes__(), fn route ->
             String.contains?(route.path, "entit")
           end)
  end

  test "entity_match drops a statement whose expiry passed before the sweeper moved its state" do
    seeded =
      seed_active!("f7-entity-expiry", "/f7/entity-expiry", "Avery owns the release checklist.")

    assert {:ok, %{mentions: mentions}} =
             EntityResolver.rebuild_scope(seeded.account.id, seeded.scope.id)

    assert mentions >= 1

    assert [%{"id" => id}] = entity_match_candidates!("f7-entity-expiry", "/f7/entity-expiry")
    assert id == seeded.knowledge.id

    # Expiry is a timestamp; the sweeper that rewrites `state` to "expired" runs as a job. In
    # the window between the two the row is still "active" with a past `expires_at`, and every
    # other visible-knowledge query already refuses it. This one must agree, or an expired
    # statement stays retrievable through whichever entity it happens to name.
    DataLayer.with_actor(seeded.actor, fn _account, actor ->
      GovernanceEngine.transition!(
        seeded.knowledge,
        pipeline_actor(actor),
        %{state: "active", expires_at: DateTime.add(DateTime.utc_now(), -1, :second)},
        reason: "f7_test_expire",
        channel: "pipeline"
      )
    end)

    # Verify the row is actually active with a past expires_at before asserting retrieval behavior.
    updated_knowledge =
      DataLayer.with_actor(seeded.actor, fn account, actor ->
        KnowledgeItem
        |> Ash.Query.filter(id == ^seeded.knowledge.id)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: pipeline_actor(actor))
      end)

    assert updated_knowledge.state == "active"
    assert DateTime.compare(updated_knowledge.expires_at, DateTime.utc_now()) == :lt

    assert [] == entity_match_candidates!("f7-entity-expiry", "/f7/entity-expiry")
  end

  test "entity_match ranks a selective entity's statements above a scope-wide one's" do
    seeds = seed_statements!("f7-entity-idf", "/f7/entity-idf", 6)

    # "Melanie" names most of the scope, so learning that a statement mentions her narrows
    # nothing. "Rivet" names two statements, so it narrows a great deal. Ranking must follow
    # that difference and not the extractor's confidence, which is uniform here.
    mention_entity!("f7-entity-idf", "Melanie", seeds)
    selective = Enum.take(seeds, 2)
    mention_entity!("f7-entity-idf", "Rivet", selective)

    candidates = entity_match_candidates!("f7-entity-idf", "/f7/entity-idf", @entity_idf_query)

    assert length(candidates) == 6

    assert candidates |> Enum.take(2) |> Enum.map(& &1["id"]) |> Enum.sort() ==
             selective |> Enum.map(& &1.knowledge.id) |> Enum.sort()

    # Bounded, because `min_score` filtering and the `low_score` disagreement hint both read
    # the strategy's own score. An unbounded sum would silently change what those two mean.
    # The count is asserted first: over an empty list `Enum.all?/2` holds vacuously and would
    # report a bound this never checked.
    raw = entity_match_strategy_candidates!("f7-entity-idf", "/f7/entity-idf", @entity_idf_query)

    assert length(raw) == 6
    assert Enum.all?(raw, &(&1.score >= 0.0 and &1.score <= 1.0))
  end

  test "entity_match reports nothing when every entity the query names saturates the scope" do
    put_retrieval_config!(entity_match_ceiling_min_statements: 4)

    seeds = seed_statements!("f7-entity-hub", "/f7/entity-hub", 5)
    mention_entity!("f7-entity-hub", "Melanie", seeds)

    # Every statement mentions her, so the strategy has no way to prefer one over another and
    # would otherwise return the scope in extractor-confidence order. Reporting empty is what
    # lets `query_dependent_empty` say the run never understood the question.
    result =
      Memory.search(%{
        "account_key" => "f7-entity-hub",
        "scope_path" => "/f7/entity-hub",
        "query" => "Melanie",
        "strategies" => ["entity_match"],
        "deadline" => "disabled"
      })

    assert result["candidates"] == []
    assert result["disagreement"]["query_dependent_empty"]
  end

  test "entity_match caps how many statements one entity may contribute" do
    put_retrieval_config!(
      entity_match_ceiling_min_statements: 100,
      entity_match_per_entity_cap: 2
    )

    seeds = seed_statements!("f7-entity-cap", "/f7/entity-cap", 5)
    mention_entity!("f7-entity-cap", "Melanie", seeds)

    # The ceiling is out of reach here, so without a cap one hub entity fills the whole list
    # and crowds out every other strategy's contribution to fusion.
    assert length(entity_match_candidates!("f7-entity-cap", "/f7/entity-cap", "Melanie")) == 2
  end

  test "Indexer.rebuild_scope keeps a billed embedding call metered when the write phase fails" do
    seeded = seed_active!("f7-index-vanish", "/f7/index-vanish", "Vanishing indexer statement.")

    original_provider = Application.get_env(:memhouse, :model_provider)

    on_exit(fn ->
      if original_provider do
        Application.put_env(:memhouse, :model_provider, original_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end
    end)

    Application.put_env(
      :memhouse,
      :model_provider,
      MemHouse.F7RetrievalEntityContextTest.VanishingProvider
    )

    # The provider deletes the very knowledge item being indexed as a side effect of
    # answering the embedding call, so the write phase's update has no row left to update.
    # Ash reports this as forbidden rather than not-found: its policy check re-filters by
    # tenant and existence together, and a row that no longer matches either is
    # indistinguishable from one the actor was never allowed to see.
    assert_raise Ash.Error.Forbidden, fn ->
      Indexer.rebuild_scope(seeded.account.id, seeded.scope.id)
    end

    # The call was made and billed. Rolling its ledger row back with the failed write would
    # understate real spend, so the usage write must not share a transaction with the vector
    # write.
    assert scalar!(
             "SELECT count(*) FROM usage_events WHERE account_id = $1 AND model_role = 'embedder'",
             [Ecto.UUID.dump!(seeded.account.id)]
           ) == 1

    # The item is really gone — the provider deleted it — which is exactly what confirms
    # nothing else was half-written: the write phase raised before it touched any row.
    assert scalar!(
             "SELECT count(*) FROM knowledge_items WHERE id = $1",
             [Ecto.UUID.dump!(seeded.knowledge.id)]
           ) == 0
  end

  test "EntityResolver.rebuild_scope keeps billed calls metered and the prior index intact when the write phase fails" do
    seeded =
      seed_active!("f7-entity-vanish", "/f7/entity-vanish", "Oryon owns the launch checklist.")

    # A pre-existing entity from an earlier rebuild, seeded directly rather than through
    # `rebuild_scope/2` so its alias embedding is the exact vector the fixture provider's
    # "Oryon" vector sits at cosine 0.8 from — inside the ambiguous band, so this run reaches
    # the reasoning model rather than matching or rejecting on similarity alone.
    entity =
      DataLayer.with_account_key("f7-entity-vanish", fn account, actor ->
        create!(
          Entity,
          :create_from_pipeline,
          %{
            canonical_name: "Orion",
            kind: "person",
            aliases: ["Orion"],
            alias_embedding: [1.0, 0.0, 0.0],
            embedding_provider: "fixture",
            embedding_model: "f7-fixture",
            embedding_version: "1",
            embedding_dimensions: 3,
            derived_from: []
          },
          account.id,
          pipeline_actor(actor)
        )
      end)

    original_provider = Application.get_env(:memhouse, :model_provider)

    on_exit(fn ->
      if original_provider do
        Application.put_env(:memhouse, :model_provider, original_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end
    end)

    Application.put_env(
      :memhouse,
      :model_provider,
      MemHouse.F7RetrievalEntityContextTest.VanishingProvider
    )

    # The provider deletes the adjudicated entity as a side effect of answering, so the write
    # phase's re-read of it comes back empty.
    assert_raise RuntimeError, ~r/vanished/, fn ->
      EntityResolver.rebuild_scope(seeded.account.id, seeded.scope.id)
    end

    # Both billed embedding calls — the one that scored the ambiguous match and the one that
    # re-embeds the widened alias set once the fold is decided — survive the later failure,
    # along with the reasoner call that adjudicated the match, because metering commits in its
    # own transaction rather than the rebuild's write transaction.
    assert scalar!(
             "SELECT count(*) FROM usage_events WHERE account_id = $1 AND model_role = 'embedder'",
             [Ecto.UUID.dump!(seeded.account.id)]
           ) == 2

    assert scalar!(
             "SELECT count(*) FROM usage_events WHERE account_id = $1 AND model_role = 'dream_reasoner'",
             [Ecto.UUID.dump!(seeded.account.id)]
           ) == 1

    # The write transaction rolled back entirely: clearing this scope's mentions and folding
    # the surface form into the entity happen in the same transaction as the re-read that
    # failed, so no mention was left behind by a half-applied rebuild.
    assert scalar!(
             "SELECT count(*) FROM entity_mentions WHERE scope_id = $1",
             [Ecto.UUID.dump!(seeded.scope.id)]
           ) == 0

    # The entity really is gone — the provider deleted it — which is what forced the write
    # phase to fail in the first place, not evidence the transaction misbehaved.
    assert scalar!(
             "SELECT count(*) FROM entities WHERE id = $1",
             [Ecto.UUID.dump!(entity.id)]
           ) == 0
  end

  test "Account and authorized scope filters run before candidates leave retrieval" do
    # Three statements, two traps. Both traps carry the query verbatim, so they outrank the
    # searched scope's own statement on every lexical measure and can only be missing because
    # the Account and scope filters removed them.
    visible = seed_active!("f7-wall-a", "/f7/team/visible", "Visible Orchid handbook.")
    hidden = seed_active!("f7-wall-a", "/f7/team/hidden", "Hidden Juniper handbook.")
    foreign = seed_active!("f7-wall-b", "/f7/team/visible", "Foreign Juniper handbook.")

    result =
      Memory.search(%{
        "account_key" => "f7-wall-a",
        "scope_path" => visible.scope.path,
        "query" => "Juniper handbook",
        "strategies" => ["lexical"],
        "deadline" => "disabled"
      })

    # Scope containment inherits downward, never sideways, and account isolation is absolute.
    # Either trap appearing here is a data-leak bug, not a ranking bug — do not "fix" it by
    # adjusting the query or the fixtures.
    ids = Enum.map(result["candidates"], & &1["id"])
    refute hidden.knowledge.id in ids
    refute foreign.knowledge.id in ids

    # Stated as a whitelist as well, so a candidate arriving from a scope nobody listed here
    # fails too rather than passing on the two `refute`s alone.
    assert Enum.all?(result["candidates"], &(&1["scope_path"] == visible.scope.path))
  end

  test "nearest-scope profile inheritance, raw overrides, and deadline reporting are explicit" do
    seeded = seed_active!("f7-profile", "/f7/profile/child", "Avery writes release notes.")

    parent =
      DataLayer.with_account_key("f7-profile", fn account, actor ->
        Scope
        |> Ash.Query.filter(path == "/f7/profile")
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)
      end)

    DataLayer.with_account_key("f7-profile", fn account, actor ->
      # Authoring a retrieval profile is an administrative act, not something a reader or a
      # machine credential may do; it changes what every caller in the subtree sees.
      actor = %{actor | role: :account_admin}

      # Parent scope: temporal only, 222 ms deadline. Deliberately different in both strategy
      # set and deadline from the child, so the resolution assertions cannot both pass by
      # accident.
      create!(
        MemHouse.Retrieval.RetrievalProfile,
        :create,
        %{
          scope_id: parent.id,
          name: "balanced",
          version: 1,
          strategy_config: %{"strategies" => ["temporal"], "weights" => %{"temporal" => 1}},
          deadline_ms: 222,
          active: true
        },
        account.id,
        actor
      )

      # Child scope, same profile name: lexical only, 111 ms deadline.
      create!(
        MemHouse.Retrieval.RetrievalProfile,
        :create,
        %{
          scope_id: seeded.scope.id,
          name: "balanced",
          version: 2,
          strategy_config: %{"strategies" => ["lexical"], "weights" => %{"lexical" => 1}},
          deadline_ms: 111,
          active: true
        },
        account.id,
        actor
      )

      query = %Query{
        account_id: account.id,
        actor: actor,
        scope_ids: [seeded.scope.id, parent.id],
        text: "release",
        target: :knowledge
      }

      # Nearest scope wins outright — the child's configuration is used, not merged with the
      # parent's. Both scopes are in the query, so this cannot be an accident of filtering.
      profile = Profile.resolve(:balanced, query)
      assert profile.strategies == [:lexical]
      assert profile.deadline_ms == 111

      # The reported version is the authored version plus a digest of the effective
      # strategies, weights, and rerank settings. Two runs reporting the same version really
      # did use the same configuration, even if someone edited a profile in place without
      # bumping its number. Only the shape is asserted; the digest changes with the config.
      assert profile.version =~ ~r/\Af7-2-[0-9a-f]{10}\z/

      # An external caller cannot hand-pick strategies. Named profiles are what make a
      # published measurement reproducible; a raw list from a request would not be.
      assert_raise ArgumentError, ~r/raw retrieval strategies/, fn ->
        Profile.resolve(:balanced, query, strategies: [:temporal], internal?: false)
      end
    end)

    _deadline_seed =
      seed_active!("f7-deadline", "/f7/deadline", "Avery publishes release notes.")

    retrieval = Application.fetch_env!(:memhouse, :retrieval_profiles)

    # A zero-millisecond budget: nothing can finish. Restored by the suite's on_exit.
    Application.put_env(
      :memhouse,
      :retrieval_profiles,
      Keyword.update!(retrieval, :balanced, &Map.put(&1, :deadline_ms, 0))
    )

    result =
      Memory.search(%{
        "account_key" => "f7-deadline",
        "scope_path" => "/f7/deadline",
        "query" => "release"
      })

    # Out-of-time strategies are dropped, never retried and never waited out. The caller gets
    # an empty but *honest* answer: the response names what was dropped, so a degraded result
    # is distinguishable from a genuinely empty corpus.
    assert result["candidates"] == []
    assert "lexical" in result["dropped_strategies"]

    assert %{
             component: "lexical",
             status: "dropped",
             reason_class: "deadline_exhausted_before_start",
             elapsed_ms: 0,
             budget_remaining_ms: 0
           } in result["retrieval_outcomes"]

    # A strategy that never ran is only dropped. Reporting it as having found nothing would
    # claim the corpus was searched and came back empty, which is the opposite of what happened.
    refute "lexical" in result["empty_strategies"]
    refute "lexical" in result["contributed_strategies"]
  end

  test "retrieval diagnostics reach the internal seam only through an authorized grant" do
    admin = bootstrap_diagnostic_admin!("diagnostic-admin@example.test")
    scope_path = "/f7/diagnostic"

    # Deep enough that the observed failure is reproducible: the statement this
    # test looks for sits at rank 34, well past the ordinary top-12 window.
    for index <- 1..40 do
      seed_active_as!(
        admin,
        scope_path,
        "Avery published release checklist number #{index}.",
        "diagnostic-#{index}"
      )
    end

    # Ingest created the scope; the actor's authorized-scope set is a snapshot
    # taken before it existed.
    admin = Identity.refresh_actor(admin)

    normal =
      Memory.search(
        %{"scope_path" => scope_path, "query" => "release checklist"},
        admin
      )

    # The ordinary window is what the observed failure was about: the answer can
    # sit below it and the response looks identical either way.
    assert length(normal["candidates"]) == 12

    diagnostic =
      Memory.diagnostic_search(
        %{"scope_path" => scope_path, "query" => "release checklist", "limit" => "50"},
        admin
      )

    assert length(diagnostic["candidates"]) > 12
    assert diagnostic["diagnostic"]["default_limit"] == 12
    assert diagnostic["diagnostic"]["beyond_default_limit"] > 0
    assert "lexical" in diagnostic["diagnostic"]["query_dependent_strategies"]
    refute "salience_recency" in diagnostic["diagnostic"]["query_dependent_strategies"]

    # Rank 34: reachable only through the diagnostic limit, which is the whole
    # point of the mode.
    deep = Enum.at(diagnostic["candidates"], 33)
    assert deep["statement"]
    refute Enum.any?(normal["candidates"], &(&1["id"] == deep["id"]))

    # Strategy isolation and a disabled deadline are the two internal controls,
    # and they reach retrieval intact.
    isolated =
      Memory.diagnostic_search(
        %{
          "scope_path" => scope_path,
          "query" => "release checklist",
          "strategies" => ["lexical"],
          "deadline" => "disabled",
          "rerank" => "false"
        },
        admin
      )

    assert isolated["contributed_strategies"] == ["lexical"]
    assert isolated["deadline"] == "disabled"
    assert isolated["diagnostic"]["rerank"] == false
    assert isolated["diagnostic"]["strategies"] == ["lexical"]

    # The limit is clamped rather than honoured, so one browser form cannot ask
    # the database for an unbounded pre-fusion pool.
    clamped =
      Memory.diagnostic_search(
        %{"scope_path" => scope_path, "query" => "release", "limit" => "100000"},
        admin
      )

    assert clamped["diagnostic"]["limit"] == DiagnosticGrant.max_limit()

    ordinary_clamped =
      Memory.search(
        %{
          "scope_path" => scope_path,
          "query" => "release",
          "limit" => "100000",
          "strategies" => ["lexical"],
          "deadline" => "disabled"
        },
        %{admin | identity_kind: :system}
      )

    assert length(ordinary_clamped["candidates"]) == 40

    assert %{
             query_search_list_size: 200,
             query_rescore: 100
           } = MemHouse.Retrieval.Diagnostics.latest(admin.account_id)

    # The DiskANN settings must apply when semantic retrieval runs with indexed
    # vectors, not only when lexical search computes them without using them.
    scope_id = Scope.id_from_path!(admin.account_id, scope_path)
    assert {:ok, %{indexed: indexed}} = Indexer.rebuild_scope(admin.account_id, scope_id)
    assert indexed == 40

    semantic_result =
      Memory.search(
        %{
          "scope_path" => scope_path,
          "query" => "release checklist",
          "limit" => "100",
          "strategies" => ["semantic"],
          "deadline" => "disabled"
        },
        %{admin | identity_kind: :system}
      )

    assert "semantic" in semantic_result["contributed_strategies"]
    assert length(semantic_result["candidates"]) > 0

    assert %{
             query_search_list_size: 200,
             query_rescore: 100
           } = MemHouse.Retrieval.Diagnostics.latest(admin.account_id)

    assert_raise ArgumentError, ~r/unknown retrieval strategy/, fn ->
      Memory.diagnostic_search(
        %{"scope_path" => scope_path, "query" => "release", "strategies" => ["not_a_strategy"]},
        admin
      )
    end

    # Both halves of the gate refuse at the facade rather than merely hiding the
    # controls in the browser: a lesser role, and a machine credential holding
    # the administrative role anyway.
    member = %{admin | role: :member}
    machine_admin = %{admin | identity_kind: :api_key}

    for refused <- [member, machine_admin] do
      assert_raise Ash.Error.Forbidden, fn ->
        Memory.diagnostic_search(%{"scope_path" => scope_path, "query" => "release"}, refused)
      end
    end

    # The grant is a struct precisely so a request body cannot forge one:
    # decoded JSON produces a plain map, and a plain map is not a grant.
    assert_raise ArgumentError, ~r/raw retrieval strategies/, fn ->
      Memory.search(
        %{
          "scope_path" => scope_path,
          "query" => "release",
          "strategies" => ["lexical"],
          "_diagnostic" => %{"limit" => 50, "strategies" => ["lexical"]}
        },
        member
      )
    end
  end

  test "reranker completion, timeout, provider failure, and malformed output are classified" do
    seeded = seed_active!("f7-rerank-outcomes", "/f7/rerank", "Avery writes release notes.")
    original_provider = Application.get_env(:memhouse, :model_provider)
    original_retrieval = Application.fetch_env!(:memhouse, :retrieval_profiles)

    on_exit(fn ->
      Application.put_env(:memhouse, :retrieval_profiles, original_retrieval)
      Application.delete_env(:memhouse, :rerank_test_mode)

      if original_provider,
        do: Application.put_env(:memhouse, :model_provider, original_provider),
        else: Application.delete_env(:memhouse, :model_provider)
    end)

    Application.put_env(
      :memhouse,
      :model_provider,
      MemHouse.F7RetrievalEntityContextTest.RerankFailureProvider
    )

    Application.put_env(
      :memhouse,
      :retrieval_profiles,
      Keyword.put(original_retrieval, :rerank_timeout_ms, 50)
    )

    baseline =
      Memory.search(%{
        "account_key" => "f7-rerank-outcomes",
        "scope_path" => seeded.scope.path,
        "query" => "release",
        "profile" => "balanced",
        "strategies" => ["lexical"],
        "deadline" => "disabled"
      })

    baseline_ids = Enum.map(baseline["candidates"], & &1["id"])

    # The timeout class needs a live deadline and is exercised separately: a deadline-free run
    # deliberately offers the reranker an unbounded allowance.
    for {mode, expected_status, reason} <- [
          {:complete, "completed", nil},
          {:provider_error, "dropped", "provider_error"},
          {:invalid, "dropped", "invalid_result"}
        ] do
      Application.put_env(:memhouse, :rerank_test_mode, mode)

      result =
        Memory.search(%{
          "account_key" => "f7-rerank-outcomes",
          "scope_path" => seeded.scope.path,
          "query" => "release",
          "profile" => "thorough",
          "strategies" => ["lexical"],
          "deadline" => "disabled"
        })

      assert %{status: ^expected_status, reason_class: ^reason} =
               Enum.find(result["retrieval_outcomes"], &(&1.component == "reranker"))

      if expected_status == "dropped" do
        assert Enum.map(result["candidates"], & &1["id"]) == baseline_ids
        assert "reranker" in result["dropped_strategies"]
        # A dropped ordering stage is degradation the caller can read without
        # interpreting the outcome list.
        assert result["degraded"] == true
        assert "reranker" in result["degraded_components"]
      else
        assert result["degraded"] == false
        assert result["degraded_components"] == []
      end
    end
  end

  test "a live deadline bounds the reranker and a deadline-free run does not" do
    seeded =
      seed_active!("f7-rerank-deadline", "/f7/rerank-deadline", "Avery writes release notes.")

    original_provider = Application.get_env(:memhouse, :model_provider)
    original_retrieval = Application.fetch_env!(:memhouse, :retrieval_profiles)

    on_exit(fn ->
      Application.put_env(:memhouse, :retrieval_profiles, original_retrieval)
      Application.delete_env(:memhouse, :rerank_test_mode)

      if original_provider,
        do: Application.put_env(:memhouse, :model_provider, original_provider),
        else: Application.delete_env(:memhouse, :model_provider)
    end)

    Application.put_env(
      :memhouse,
      :model_provider,
      MemHouse.F7RetrievalEntityContextTest.RerankFailureProvider
    )

    # The injected reranker takes 80 ms; the allowance is 50 ms.
    Application.put_env(
      :memhouse,
      :retrieval_profiles,
      Keyword.put(original_retrieval, :rerank_timeout_ms, 50)
    )

    Application.put_env(:memhouse, :rerank_test_mode, :timeout)

    search = fn deadline ->
      Memory.search(%{
        "account_key" => "f7-rerank-deadline",
        "scope_path" => seeded.scope.path,
        "query" => "release",
        "profile" => "thorough",
        "strategies" => ["lexical"],
        "deadline" => deadline
      })
    end

    live = search.("enabled")

    assert %{status: "dropped", reason_class: "timeout"} =
             Enum.find(live["retrieval_outcomes"], &(&1.component == "reranker"))

    assert live["degraded"] == true

    # An evaluation run that asked for no time limit is measuring the reranked ordering. Capping
    # the stage that produces it at the live allowance measures fusion order instead.
    unbounded = search.("disabled")

    assert %{status: "completed", reason_class: nil} =
             Enum.find(unbounded["retrieval_outcomes"], &(&1.component == "reranker"))

    assert unbounded["degraded"] == false
  end

  test "the rerank allowance is reserved before the strategies can spend it" do
    seeded =
      seed_active!("f7-rerank-reserve", "/f7/rerank-reserve", "Avery writes release notes.")

    original_retrieval = Application.fetch_env!(:memhouse, :retrieval_profiles)

    on_exit(fn -> Application.put_env(:memhouse, :retrieval_profiles, original_retrieval) end)

    # Half of the 1500 ms thorough deadline is the clamp, so 700 ms is reserved in full and the
    # strategies see 800 ms rather than the whole ceiling.
    Application.put_env(
      :memhouse,
      :retrieval_profiles,
      Keyword.put(original_retrieval, :rerank_reserved_ms, 700)
    )

    search = fn profile, deadline ->
      Memory.search(%{
        "account_key" => "f7-rerank-reserve",
        "scope_path" => seeded.scope.path,
        "query" => "release",
        "profile" => profile,
        "strategies" => ["lexical"],
        "deadline" => deadline
      })
    end

    reranking = search.("thorough", "enabled")

    assert reranking["reserved_rerank_ms"] == 700

    strategy_outcomes =
      Enum.reject(reranking["retrieval_outcomes"], &(&1.component == "reranker"))

    assert strategy_outcomes != []

    for outcome <- strategy_outcomes do
      assert outcome.budget_remaining_ms <= 800
    end

    assert %{status: "completed"} =
             Enum.find(reranking["retrieval_outcomes"], &(&1.component == "reranker"))

    # Nothing is withheld from a profile that never reranks, or from a run with no clock.
    assert search.("balanced", "enabled")["reserved_rerank_ms"] == 0
    assert search.("thorough", "disabled")["reserved_rerank_ms"] == 0

    # A negative reservation would otherwise be subtracted as extra strategy time and carry the
    # phases past the profile deadline. It reserves nothing instead.
    Application.put_env(
      :memhouse,
      :retrieval_profiles,
      Keyword.put(original_retrieval, :rerank_reserved_ms, -120)
    )

    negative = search.("thorough", "enabled")

    assert negative["reserved_rerank_ms"] == 0

    for outcome <- Enum.reject(negative["retrieval_outcomes"], &(&1.component == "reranker")) do
      assert outcome.budget_remaining_ms <= 1500
    end
  end

  test "a partial ranking reorders what the model judged and reports degradation" do
    seeded =
      seed_active!("f7-rerank-partial", "/f7/rerank-partial", "Avery writes release notes.")

    seed_active!(
      "f7-rerank-partial",
      "/f7/rerank-partial",
      "Blake reviews the release checklist.",
      "partial-session-2"
    )

    seed_active!(
      "f7-rerank-partial",
      "/f7/rerank-partial",
      "Casey schedules the release train.",
      "partial-session-3"
    )

    original_provider = Application.get_env(:memhouse, :model_provider)

    on_exit(fn ->
      Application.delete_env(:memhouse, :rerank_test_mode)

      if original_provider,
        do: Application.put_env(:memhouse, :model_provider, original_provider),
        else: Application.delete_env(:memhouse, :model_provider)
    end)

    Application.put_env(
      :memhouse,
      :model_provider,
      MemHouse.F7RetrievalEntityContextTest.RerankFailureProvider
    )

    search = fn profile ->
      Memory.search(%{
        "account_key" => "f7-rerank-partial",
        "scope_path" => seeded.scope.path,
        "query" => "release",
        "profile" => profile,
        "strategies" => ["lexical"],
        "deadline" => "disabled"
      })
    end

    Application.put_env(:memhouse, :rerank_test_mode, :complete)
    fusion_ids = Enum.map(search.("balanced")["candidates"], & &1["id"])

    assert length(fusion_ids) == 3

    Application.put_env(:memhouse, :rerank_test_mode, :partial)
    result = search.("thorough")

    # The model judged only the last document. Its verdict leads; everything it did not judge
    # keeps fusion order behind it, which is strictly more of the model's opinion than throwing
    # the call away and keeping fusion order for all three.
    assert Enum.map(result["candidates"], & &1["id"]) ==
             [Enum.at(fusion_ids, 2) | List.delete_at(fusion_ids, 2)]

    assert %{status: "completed", reason_class: "partial_rankings"} =
             Enum.find(result["retrieval_outcomes"], &(&1.component == "reranker"))

    # It ran and produced an ordering, so it is not a drop; it did less than asked, so it is
    # still degradation.
    refute "reranker" in result["dropped_strategies"]
    assert result["degraded"] == true
    assert "reranker" in result["degraded_components"]
  end

  test "projection refresh, bounded deltas, session resolution, and ETS invalidation stay model-free" do
    seeded =
      seed_active!(
        "f7-context",
        "/f7/context",
        "Avery prefers concise release summaries.",
        "context-session"
      )

    # Build the projections up front. Refresh is the expensive, background-time step; the
    # live context path is only allowed to read what refresh already produced.
    assert {:ok, %{scope_card: _id}} =
             Builder.refresh_scope(seeded.account.id, seeded.scope.id)

    # Start counting model calls from here. Everything after this point is the live path.
    MemHouse.F7RetrievalEntityContextTest.Provider.reset!()

    first =
      Memory.get_context(
        %{
          "scope_path" => seeded.scope.path,
          "session_id" => "context-session",
          "budget_chars" => 20_000
        },
        seeded.actor
      )

    second =
      Memory.get_context(
        %{
          "scope_path" => seeded.scope.path,
          "session_id" => "context-session",
          "budget_chars" => 20_000
        },
        seeded.actor
      )

    assert first["profile_version"] == "f7-1"
    # Projections were clean, so no live retrieval fallback was needed.
    assert first["fast_fallback"] == false
    # Projections are bounded summaries with inspectable pinned facts, not a second copy of every
    # governed row. They are assembled in a fixed budget order.
    assert first["session_summary"]["session_id"]
    assert [%{"path" => "/f7/context"} | _] = first["scope_cards"]
    assert [%{"pinned_facts" => [%{"statement" => statement} | _]} | _] = first["peer_profile"]
    assert statement =~ "concise release summaries"
    # The second identical request is served from the in-memory cache.
    assert second["projection_cache_hit"] == true
    # Zero model calls across both requests. This is the assertion that keeps context
    # assembly cheap and predictable: the moment it summarizes with a model, every agent
    # turn pays for inference and the response stops being reproducible.
    assert MemHouse.F7RetrievalEntityContextTest.Provider.calls() == []

    # Marking the scope dirty invalidates the cached projection, exactly as a lifecycle
    # change would. Invalidation is broadcast so every node in a multi-node deployment drops
    # the same key rather than serving stale context from its own memory.
    DataLayer.with_account_key("f7-context", fn account, actor ->
      Builder.mark_dirty(account.id, pipeline_actor(actor), seeded.scope.id)
    end)

    dirty =
      Memory.get_context(
        %{"scope_path" => seeded.scope.path, "query" => "release"},
        seeded.actor
      )

    # On a miss the caller still gets an answer, from the cheapest retrieval profile, and the
    # response says so. Silently serving a stale projection would be the worse failure.
    assert dirty["fast_fallback"] == true
  end

  test "projection payloads are bounded summaries with pinned facts, not knowledge-row dumps" do
    statement = "Avery's " <> String.duplicate("releasechecklist ", 200) <> "is complete"
    seeded = seed_active!("f7-bounded-projections", "/f7/bounded", statement, "bounded-session")

    assert {:ok, _counts} = Builder.refresh_scope(seeded.account.id, seeded.scope.id)

    DataLayer.with_account_key("f7-bounded-projections", fn account, actor ->
      projections =
        Projection
        |> Ash.Query.filter(scope_id == ^seeded.scope.id and dirty == false)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: pipeline_actor(actor))

      assert projections != []

      Enum.each(projections, fn projection ->
        refute Map.has_key?(projection.content, "knowledge")
        assert is_list(projection.content["pinned_facts"])
        assert byte_size(Jason.encode!(projection.content)) <= 2_500

        Enum.each(projection.content["pinned_facts"], fn fact ->
          assert Map.keys(fact) |> Enum.sort() == ["id", "statement"]
          assert fact["id"] in projection.source_ids
        end)
      end)
    end)
  end

  test "entity cards name their scope-local referent and drop the summary at two sources" do
    first =
      seed_active!(
        "f7-entity-card",
        "/f7/entity-card",
        "The billing service owns invoice generation.",
        "entity-card-1"
      )

    second =
      seed_active!(
        "f7-entity-card",
        "/f7/entity-card",
        "The billing service pages the finance on-call after failed settlement.",
        "entity-card-2"
      )

    third =
      seed_active!(
        "f7-entity-card",
        "/f7/entity-card",
        "The billing service restricts salary export access.",
        "entity-card-3"
      )

    ungoverned_a =
      seed_ungoverned!(
        "f7-entity-card",
        "/f7/entity-card",
        "Zap remains under discussion for the billing rollout.",
        "entity-card-4"
      )

    ungoverned_b =
      seed_ungoverned!(
        "f7-entity-card",
        "/f7/entity-card",
        "Zap has no owner assigned yet.",
        "entity-card-5"
      )

    ungoverned_c =
      seed_ungoverned!(
        "f7-entity-card",
        "/f7/entity-card",
        "Zap was raised again in the weekly review.",
        "entity-card-6"
      )

    DataLayer.with_account_key("f7-entity-card", fn account, actor ->
      pipeline = pipeline_actor(actor)
      source_ids = Enum.map([first, second, third], & &1.knowledge.id)

      # The third statement is personal and about a peer, so it reaches a shared card only once
      # it has been promoted above peer level — which is where its subject agreed to the wider
      # audience. Without this the card would be built from two sources and carry neither the
      # summary nor the strictest sensitivity the rest of this test checks.
      #
      # The promotion is written directly because this fixture is about card content, not about
      # the consent path; `test/memhouse/f4_real_gate_a_b_governance_test.exs` owns that evidence.
      GovernanceEngine.transition!(
        third.knowledge,
        pipeline,
        %{target_level: "scope"},
        reason: "f7_entity_card_promoted",
        channel: "pipeline"
      )

      entity =
        create!(
          Entity,
          :create_from_pipeline,
          %{
            canonical_name: "billing service",
            kind: "system",
            aliases: ["billing service"],
            derived_from: source_ids
          },
          account.id,
          pipeline
        )

      Enum.each([first, second, third], fn seeded ->
        create!(
          EntityMention,
          :create_from_pipeline,
          %{
            knowledge_item_id: seeded.knowledge.id,
            scope_id: seeded.scope.id,
            entity_id: entity.id,
            surface_form: "billing service",
            confidence: 1.0
          },
          account.id,
          pipeline
        )
      end)

      # Three statements that never went active, mentioning the same entity by a form that would
      # win if the label were drawn from the whole mention cache: it ties "billing service" on
      # frequency and beats it on the shortest tie-break. The card must ignore all three, because
      # none of them is one of its sources. Three is the count that makes this discriminating —
      # the retracted third source keeps its own mention in the cache, so two would still lose.
      Enum.each([ungoverned_a, ungoverned_b, ungoverned_c], fn seeded ->
        create!(
          EntityMention,
          :create_from_pipeline,
          %{
            knowledge_item_id: seeded.knowledge.id,
            scope_id: seeded.scope.id,
            entity_id: entity.id,
            surface_form: "Zap",
            confidence: 1.0
          },
          account.id,
          pipeline
        )
      end)

      assert {:ok, %{entity_cards: 1}} = Builder.refresh_scope(account.id, first.scope.id)

      projection =
        Projection
        |> Ash.Query.filter(kind == "entity_card" and scope_id == ^first.scope.id)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: pipeline)

      assert projection.entity_id == entity.id
      assert projection.sensitivity == "personal"
    end)

    context =
      Memory.get_context(
        %{"scope_path" => first.scope.path, "budget_chars" => 50_000},
        first.actor
      )

    assert [card] = context["entity_cards"]
    assert card["summary"] == "The billing service has three governed operational facts."
    assert card["summary_mode"] == "model"
    assert card["sensitivity"] == "personal"
    assert length(card["pinned_facts"]) == 3

    # The label is the scope-local surface form, and the kind is recomputed from it. The entity
    # row says "system"; recomputation says "concept". That divergence is the point: the stored
    # kind is frozen at the first spelling ever seen, in whatever scope that was.
    assert card["label"] == "billing service"
    assert card["kind"] == "concept"

    for private_field <- ~w(entity_id canonical_name aliases surface_form) do
      refute Map.has_key?(card, private_field)
      refute Enum.any?(card["pinned_facts"], &Map.has_key?(&1, private_field))
    end

    # Two sources still earn a card, but never a summary: a pair rarely yields a brief worth a
    # model call, so all three summary fields go empty while the label survives.
    DataLayer.with_account_key("f7-entity-card", fn account, actor ->
      GovernanceEngine.transition!(
        third.knowledge,
        pipeline_actor(actor),
        %{state: "retracted"},
        reason: "f7_entity_card_retracted",
        channel: "pipeline"
      )

      assert {:ok, %{entity_cards: 1}} = Builder.refresh_scope(account.id, first.scope.id)
    end)

    paired =
      Memory.get_context(
        %{"scope_path" => first.scope.path, "budget_chars" => 50_000},
        first.actor
      )

    assert [pair_card] = paired["entity_cards"]
    # "Invoice Runner" was the most frequent form until its statement was retracted. The label
    # follows the card's own sources, so it does not survive them.
    assert pair_card["label"] == "billing service"
    assert is_nil(pair_card["summary"])
    assert pair_card["summary_mode"] == "none"
    assert is_nil(pair_card["summary_provenance"])
    assert length(pair_card["pinned_facts"]) == 2

    # Dropping below the two-active-source threshold retires the card. The mention cache may
    # still contain the retracted statements until its own rebuild, so this also proves that card
    # eligibility comes from governed lifecycle state rather than mention presence alone.
    DataLayer.with_account_key("f7-entity-card", fn account, actor ->
      GovernanceEngine.transition!(
        second.knowledge,
        pipeline_actor(actor),
        %{state: "retracted"},
        reason: "f7_entity_card_retracted",
        channel: "pipeline"
      )

      assert {:ok, %{entity_cards: 0}} = Builder.refresh_scope(account.id, first.scope.id)
    end)

    refreshed =
      Memory.get_context(
        %{"scope_path" => first.scope.path, "budget_chars" => 50_000},
        first.actor
      )

    assert refreshed["entity_cards"] == []
  end

  test "a failed entity card summary degrades one card instead of the whole rebuild" do
    account_key = "f7-card-summary-failure"
    scope_path = "/f7/card-summary-failure"

    first =
      seed_active!(
        account_key,
        scope_path,
        "The ledger service owns invoice generation.",
        "card-summary-1"
      )

    second =
      seed_active!(
        account_key,
        scope_path,
        "The ledger service pages the finance on-call after failed settlement.",
        "card-summary-2"
      )

    third =
      seed_active!(
        account_key,
        scope_path,
        "The ledger service retries settlement twice before it escalates.",
        "card-summary-3"
      )

    DataLayer.with_account_key(account_key, fn account, actor ->
      pipeline = pipeline_actor(actor)
      sources = [first, second, third]

      entity =
        create!(
          Entity,
          :create_from_pipeline,
          %{
            canonical_name: "ledger service",
            kind: "system",
            aliases: ["ledger service"],
            derived_from: Enum.map(sources, & &1.knowledge.id)
          },
          account.id,
          pipeline
        )

      Enum.each(sources, fn seeded ->
        create!(
          EntityMention,
          :create_from_pipeline,
          %{
            knowledge_item_id: seeded.knowledge.id,
            scope_id: seeded.scope.id,
            entity_id: entity.id,
            surface_form: "ledger service",
            confidence: 1.0
          },
          account.id,
          pipeline
        )
      end)
    end)

    original_provider = Application.get_env(:memhouse, :model_provider)

    on_exit(fn ->
      if original_provider do
        Application.put_env(:memhouse, :model_provider, original_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end
    end)

    Application.put_env(
      :memhouse,
      :model_provider,
      MemHouse.F7RetrievalEntityContextTest.CardSummaryFailureProvider
    )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        DataLayer.with_account_key(account_key, fn account, _actor ->
          # Three sources earn a summary and the provider refuses it. The refresh still succeeds
          # and reports the degraded card, because the alternative — raising — throws away the
          # two committed stages the same rebuild already paid for.
          assert {:ok, %{entity_cards: 1, entity_card_summaries_unavailable: 1}} =
                   Builder.refresh_scope(account.id, first.scope.id)
        end)
      end)

    assert log =~ "entity card summary unavailable"
    assert log =~ "Mint.TransportError"
    # The failure is diagnosable from ids and an error class alone. A statement in a log line is
    # a content leak whatever the log level.
    refute log =~ "invoice generation"

    context =
      Memory.get_context(
        %{"scope_path" => first.scope.path, "budget_chars" => 50_000},
        first.actor
      )

    # Everything the card is built from survives the missing brief: the summary reads exactly as
    # it does below the source threshold, and only `summary_mode` distinguishes the two.
    assert [card] = context["entity_cards"]
    assert card["label"] == "ledger service"
    assert is_nil(card["summary"])
    assert card["summary_mode"] == "unavailable"
    assert is_nil(card["summary_provenance"])
    assert length(card["pinned_facts"]) == 3

    # The whole three-stage rebuild now completes with the same provider, and the embeddings its
    # first stage commits are what the raise used to make the caller redo.
    assert {:ok, %{index: %{indexed: 3}}} =
             MemHouse.Retrieval.rebuild_scope(first.account.id, first.scope.id)

    coverage =
      first.account.id
      |> MemHouse.Retrieval.index_coverage([first.scope.id], nil, true)
      |> Map.fetch!(first.scope.id)

    assert coverage.statement_count == 3
    assert coverage.embedded_count == 3
  end

  test "entity card summaries overlap up to the configured concurrency" do
    account_key = "f7-card-summary-concurrency"
    scope_path = "/f7/card-summary-concurrency"

    # Two clusters, each over the summary threshold, so the scope owes two provider calls. Serial
    # generation makes a scope wait for their sum; that is what the concurrency limit bounds.
    ledger =
      seed_entity_cluster!(account_key, scope_path, "ledger service", "system", [
        "The ledger service owns invoice generation.",
        "The ledger service pages the finance on-call after failed settlement.",
        "The ledger service retries settlement twice before it escalates."
      ])

    seed_entity_cluster!(account_key, scope_path, "rollout board", "system", [
      "The rollout board approves every release window.",
      "The rollout board meets before each freeze.",
      "The rollout board records its decisions in the release log."
    ])

    original_provider = Application.get_env(:memhouse, :model_provider)
    original_concurrency = Application.get_env(:memhouse, :entity_card_summary_concurrency)

    on_exit(fn ->
      MemHouse.F7RetrievalEntityContextTest.CardSummaryConcurrencyProvider.stop()
      Application.put_env(:memhouse, :entity_card_summary_concurrency, original_concurrency)

      if original_provider do
        Application.put_env(:memhouse, :model_provider, original_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end
    end)

    Application.put_env(
      :memhouse,
      :model_provider,
      MemHouse.F7RetrievalEntityContextTest.CardSummaryConcurrencyProvider
    )

    # A limit of one is the behaviour this test exists to distinguish from, and it is what the
    # suite runs under by default, so the fan-out below is proved against a measured baseline
    # rather than against an assumption about the serial path.
    Application.put_env(:memhouse, :entity_card_summary_concurrency, 1)
    MemHouse.F7RetrievalEntityContextTest.CardSummaryConcurrencyProvider.start!()

    # Called outside `with_account_key`, unlike the tests above: that helper holds an open
    # transaction for its callback, and the sandbox has one connection to lend, so the summary
    # tasks would wait on the caller that is waiting on them.
    assert {:ok, %{entity_cards: 2, entity_card_summaries_unavailable: 0}} =
             Builder.refresh_scope(ledger.account.id, ledger.scope.id)

    assert MemHouse.F7RetrievalEntityContextTest.CardSummaryConcurrencyProvider.peak() == 1

    Application.put_env(:memhouse, :entity_card_summary_concurrency, 2)
    MemHouse.F7RetrievalEntityContextTest.CardSummaryConcurrencyProvider.start!()

    assert {:ok, %{entity_cards: 2, entity_card_summaries_unavailable: 0}} =
             Builder.refresh_scope(ledger.account.id, ledger.scope.id)

    assert MemHouse.F7RetrievalEntityContextTest.CardSummaryConcurrencyProvider.peak() == 2

    # Overlapping the calls changes only when they run. Both cards are written with the summary a
    # serial pass produced, and neither degraded.
    context =
      Memory.get_context(
        %{"scope_path" => scope_path, "budget_chars" => 50_000},
        ledger.actor
      )

    assert length(context["entity_cards"]) == 2

    assert Enum.all?(context["entity_cards"], fn card ->
             card["summary"] == "One governed summary." and card["summary_mode"] == "model"
           end)

    assert Enum.sort(Enum.map(context["entity_cards"], & &1["label"])) == [
             "ledger service",
             "rollout board"
           ]
  end

  test "get_context caps entity cards per scope and orders equal cards by label" do
    account_key = "f7-entity-card-cap"
    scope_path = "/f7/entity-card-cap"

    seed = seed_active!(account_key, scope_path, "Ten teams share the rollout calendar.", "cap-1")

    # The cap and its sort key live in `MemHouse.Context`, not in the builder, so the cards are
    # written directly rather than driven through ingest and extraction. Ten identical-weight
    # cards is the shape that matters: every one has two sources and the same best confidence, so
    # the label alone decides which eight survive.
    DataLayer.with_account_key(account_key, fn account, actor ->
      pipeline = pipeline_actor(actor)

      Enum.each(1..10, fn index ->
        letter = <<?A + index - 1>>
        entity_id = Ash.UUID.generate()

        create!(
          Projection,
          :upsert_from_pipeline,
          %{
            cache_key: "entity:#{seed.scope.id}:#{entity_id}",
            scope_id: seed.scope.id,
            entity_id: entity_id,
            kind: "entity_card",
            sensitivity: "internal",
            content: %{
              "label" => "Team #{letter}",
              "kind" => "concept",
              "summary" => nil,
              "summary_mode" => "none",
              "summary_provenance" => nil,
              "sensitivity" => "internal",
              "pinned_facts" => [
                %{
                  "id" => Ash.UUID.generate(),
                  "statement" => "Team #{letter} owns it.",
                  "confidence" => 0.5
                },
                %{
                  "id" => Ash.UUID.generate(),
                  "statement" => "Team #{letter} reports on it.",
                  "confidence" => 0.5
                }
              ]
            },
            source_ids: [Ash.UUID.generate(), Ash.UUID.generate()]
          },
          account.id,
          pipeline
        )
      end)
    end)

    context =
      Memory.get_context(
        %{"scope_path" => scope_path, "budget_chars" => 200_000},
        seed.actor
      )

    cards = context["entity_cards"]
    assert length(cards) == 8

    # The previous final sort key was the cache key, which carries the entity UUID and changes
    # under re-resolution. With a cap in place that churn would decide which cards a caller sees.
    labels = Enum.map(cards, & &1["label"])
    assert labels == Enum.sort(labels, :desc)

    assert labels == [
             "Team J",
             "Team I",
             "Team H",
             "Team G",
             "Team F",
             "Team E",
             "Team D",
             "Team C"
           ]
  end

  test "scope and session projections keep provisional statements private to their subject" do
    account_key = "f7-private-provisional"
    scope_path = "/f7/private-provisional"
    secret = "Avery is under investigation for expensing a personal trip."
    blake_statement = "Blake prefers async standups."

    assert {:ok, avery_message} =
             Memory.ingest_message(%{
               "account_key" => account_key,
               "session_id" => "session-avery",
               "scope_path" => scope_path,
               "peer_key" => "avery",
               "peer_name" => "Avery",
               "content" => secret
             })

    assert {:ok, blake_message} =
             Memory.ingest_message(%{
               "account_key" => account_key,
               "session_id" => "session-blake",
               "scope_path" => scope_path,
               "peer_key" => "blake",
               "peer_name" => "Blake",
               "content" => blake_statement
             })

    assert {:ok, [avery_knowledge]} = Memory.extract_message(avery_message["id"], account_key)
    assert {:ok, [blake_knowledge]} = Memory.extract_message(blake_message["id"], account_key)

    DataLayer.with_account_key(account_key, fn account, actor ->
      pipeline = pipeline_actor(actor)

      scope =
        Scope
        |> Ash.Query.filter(path == ^scope_path)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: pipeline)

      avery = read_peer!(account.id, pipeline, "avery")
      blake = read_peer!(account.id, pipeline, "blake")

      avery_item =
        KnowledgeItem
        |> Ash.Query.filter(id == ^avery_knowledge["id"])
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: pipeline)

      blake_item =
        KnowledgeItem
        |> Ash.Query.filter(id == ^blake_knowledge["id"])
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: pipeline)

      for item <- [avery_item, blake_item] do
        provisional =
          GovernanceEngine.transition!(
            item,
            pipeline,
            %{state: "provisional", verification: "pending"},
            reason: "f7_test_defer",
            channel: "pipeline"
          )

        assert provisional.state == "provisional"
      end

      blake_session =
        Session
        |> Ash.Query.filter(scope_id == ^scope.id and external_id == "session-blake")
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: pipeline)

      leaked = %{
        "id" => avery_item.id,
        "scope_id" => scope.id,
        "statement" => secret,
        "kind" => "fact",
        "confidence" => 0.55,
        "sensitivity" => "internal",
        "state" => "provisional"
      }

      # These keys reproduce clean projections written before the visibility fix. New code must
      # never read this poisoned namespace, even before the background rebuild has run.
      for attrs <- [
            %{
              cache_key: "scope:#{scope.id}",
              kind: "scope_card",
              content: %{"knowledge" => [leaked]},
              source_ids: [avery_item.id]
            },
            %{
              cache_key: "session:#{scope.id}:#{blake_session.id}",
              kind: "session_summary",
              peer_id: blake.id,
              session_id: blake_session.id,
              content: %{"session_id" => blake_session.id, "knowledge" => [leaked]},
              source_ids: [avery_item.id]
            }
          ] do
        create!(
          Projection,
          :upsert_from_pipeline,
          Map.merge(attrs, %{
            scope_id: scope.id,
            version: 1,
            dirty: false,
            watermark: DateTime.utc_now(),
            delta_count: 0
          }),
          account.id,
          pipeline
        )
      end

      blake_actor = %{
        actor
        | role: :member,
          pipeline?: false,
          peer_id: blake.id,
          scope_ids: [scope.id]
      }

      before_rebuild =
        Memory.get_context(
          %{
            "scope_path" => scope_path,
            "session_id" => "session-blake",
            "budget_chars" => 20_000
          },
          blake_actor
        )

      refute Jason.encode!(before_rebuild) =~ secret
      assert before_rebuild["fast_fallback"] == true

      assert {:ok, _counts} = Builder.refresh_scope(account.id, scope.id)

      blake_context =
        Memory.get_context(
          %{
            "scope_path" => scope_path,
            "session_id" => "session-blake",
            "budget_chars" => 20_000
          },
          blake_actor
        )

      refute Jason.encode!(blake_context) =~ secret
      assert blake_context["fast_fallback"] == false
      assert blake_context["session_summary"]["pinned_facts"] == []
      assert Enum.all?(blake_context["scope_cards"], &(&1["pinned_facts"] == []))

      assert Enum.any?(blake_context["peer_profile"], fn profile ->
               Enum.any?(profile["pinned_facts"], &(&1["statement"] == blake_statement))
             end)

      avery_actor = %{
        actor
        | role: :member,
          pipeline?: false,
          peer_id: avery.id,
          scope_ids: [scope.id]
      }

      avery_context =
        Memory.get_context(
          %{"scope_path" => scope_path, "budget_chars" => 20_000},
          avery_actor
        )

      assert Enum.any?(avery_context["peer_profile"], fn profile ->
               Enum.any?(profile["pinned_facts"], &(&1["statement"] == secret))
             end)
    end)
  end

  test "index coverage separates an unindexed scope from an empty one and reports the identity" do
    seeded = seed_active!("f7-coverage", "/f7/coverage", "Avery tracks the release checklist.")

    # The scope holds a governed statement and no vectors — exactly the state a cancelled
    # projection refresh leaves behind, and the state that was previously unobservable.
    before = MemHouse.Retrieval.index_coverage(seeded.account.id, [seeded.scope.id], nil, true)

    assert %{
             statement_count: 1,
             embedded_count: 0,
             mention_count: 0,
             mentioned_statement_count: 0,
             mention_coverage: +0.0,
             coverage: +0.0,
             embedding_identities: []
           } = Map.fetch!(before, seeded.scope.id)

    # A scope that was never written to reads as zeros rather than as an absent key, and
    # counts as covered: there is nothing to index, so an alert on the ratio must not fire.
    empty_scope_id = Ecto.UUID.generate()
    empty = MemHouse.Retrieval.index_coverage(seeded.account.id, [empty_scope_id], nil, true)

    assert %{statement_count: 0, embedded_count: 0, coverage: 1.0} =
             Map.fetch!(empty, empty_scope_id)

    events = attach_projection_refresh_telemetry!()

    assert {:ok, %{index: %{indexed: 1}}} =
             MemHouse.Retrieval.rebuild_scope(seeded.account.id, seeded.scope.id)

    after_rebuild =
      MemHouse.Retrieval.index_coverage(seeded.account.id, [seeded.scope.id], nil, true)

    coverage = Map.fetch!(after_rebuild, seeded.scope.id)

    assert coverage.statement_count == 1
    assert coverage.embedded_count == 1
    assert coverage.coverage == 1.0
    # Mentions are reported as a count. Naming the entity, its aliases, or the matched surface
    # form here would create a second, ungoverned view of who an Account knows about.
    assert coverage.mention_count >= 1
    assert coverage.mentioned_statement_count == 1
    assert coverage.mention_coverage == 1.0

    assert Map.keys(coverage) |> Enum.sort() == [
             :coverage,
             :embedded_count,
             :embedding_identities,
             :mention_count,
             :mention_coverage,
             :mentioned_statement_count,
             :statement_count
           ]

    # The identity is what decides whether stored vectors are comparable at all; two of them
    # in one scope means part of it needs re-embedding.
    assert [%{provider: "fixture", model: "f7-fixture", version: "1", dimensions: 3}] =
             coverage.embedding_identities

    # Ordinary refreshes do not re-embed the unchanged corpus. A new governed
    # statement has no vector and joins the next batch; existing identities are
    # replaced only by the explicit re-embed workflow.
    assert {:ok, %{indexed: 0}} =
             MemHouse.Retrieval.Indexer.refresh_scope(seeded.account.id, seeded.scope.id)

    assert_receive {^events, measurements, metadata}
    assert measurements.indexed == 1
    assert measurements.statements == 1
    assert measurements.embedded == 1
    assert measurements.coverage == 1.0
    assert metadata.scope_id == seeded.scope.id
    assert metadata.account_id == seeded.account.id
  end

  test "reconciliation enqueues one replay-safe rebuild for a scope with no mentions" do
    seeded =
      seed_active!("f7-mention-reconcile", "/f7/reconcile", "Avery owns the release checklist.")

    before = projection_refresh_count(seeded.account.id)

    assert {:ok, %{scopes: 1}} = MemHouse.Pipeline.Reconciler.run(seeded.account.id)
    assert projection_refresh_count(seeded.account.id) == before + 1

    assert {:ok, %{scopes: 1}} = MemHouse.Pipeline.Reconciler.run(seeded.account.id)
    assert projection_refresh_count(seeded.account.id) == before + 1

    assert {:ok, %{mentions: mentions}} =
             EntityResolver.rebuild_scope(seeded.account.id, seeded.scope.id)

    assert mentions > 0
    assert {:ok, %{scopes: 0}} = MemHouse.Pipeline.Reconciler.run(seeded.account.id)
  end

  test "mention coverage reports a partially indexed scope" do
    first = seed_active!("f7-partial-mentions", "/f7/partial", "Avery owns the checklist.")

    second =
      seed_active!(
        "f7-partial-mentions",
        "/f7/partial",
        "Melanie owns the launch plan.",
        "partial-session"
      )

    assert {:ok, %{mentions: mentions}} =
             EntityResolver.rebuild_scope(first.account.id, first.scope.id)

    assert mentions >= 2

    Ecto.Adapters.SQL.query!(
      MemHouse.Repo,
      "DELETE FROM entity_mentions WHERE account_id = $1 AND knowledge_item_id = $2",
      [Ecto.UUID.dump!(first.account.id), Ecto.UUID.dump!(second.knowledge.id)]
    )

    coverage = MemHouse.Retrieval.index_coverage(first.account.id, [first.scope.id], nil, true)
    coverage = Map.fetch!(coverage, first.scope.id)

    assert coverage.statement_count == 2
    assert coverage.mentioned_statement_count == 1
    assert coverage.mention_coverage == 0.5
  end

  test "entity no-match reasons stay count-only and scope-bound" do
    visible = seed_active!("f7-entity-reason", "/f7/visible", "Avery owns the checklist.")

    hidden =
      seed_active!(
        "f7-entity-reason",
        "/f7/hidden",
        "Melanie owns the private launch plan.",
        "hidden-session"
      )

    assert {:ok, %{mentions: mentions}} =
             EntityResolver.rebuild_scope(hidden.account.id, hidden.scope.id)

    assert mentions > 0

    query = %Query{
      account_id: visible.account.id,
      actor: visible.actor,
      text: "Melanie",
      target: :knowledge,
      scope_ids: [visible.scope.id]
    }

    assert MemHouse.Retrieval.Store.entity_match_status(query) ==
             :entity_found_no_authorized_statements

    assert MemHouse.Retrieval.Store.entity_match_status(%{query | text: "NobodyKnown"}) ==
             :query_resolved_no_entity

    diagnostic = inspect([MemHouse.Retrieval.Store.entity_match_status(query)])
    refute diagnostic =~ "Melanie"
    refute diagnostic =~ hidden.knowledge.id
  end

  test "an unavailable embedder drops the semantic strategy instead of reporting no matches" do
    seeded = seed_active!("f7-drop", "/f7/drop", "Avery reviews the release checklist.")

    assert {:ok, %{indexed: 1}} = Indexer.rebuild_scope(seeded.account.id, seeded.scope.id)

    original_provider = Application.get_env(:memhouse, :model_provider)

    on_exit(fn ->
      if original_provider do
        Application.put_env(:memhouse, :model_provider, original_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end
    end)

    Application.put_env(
      :memhouse,
      :model_provider,
      MemHouse.F7RetrievalEntityContextTest.UnavailableEmbedderProvider
    )

    result =
      Memory.search(%{
        "account_key" => "f7-drop",
        "scope_path" => seeded.scope.path,
        "query" => "release checklist",
        "strategies" => ["semantic", "lexical"],
        "deadline" => "disabled"
      })

    # Semantic never ran, so it is degradation and must be reported as such. Counting it as a
    # contributing strategy that happened to find nothing is what makes an unindexed corpus
    # and a broken embedder indistinguishable from a genuinely unmatched query.
    assert "semantic" in result["dropped_strategies"]

    assert %{reason_class: "dependency_unavailable"} =
             Enum.find(result["retrieval_outcomes"], &(&1.component == "semantic"))

    refute "semantic" in result["contributed_strategies"]
    # The request still answers from the strategies that did run.
    assert "lexical" in result["contributed_strategies"]
    assert [%{"id" => id} | _] = result["candidates"]
    assert id == seeded.knowledge.id
  end

  # The query planner will not use an index that has been renamed or dropped. Retrieval still
  # returns correct results by sequential scan, so this test protects the indexes that have SQL
  # readers and rejects the entity index that has none.
  test "F7 migrations install only indexes with query consumers" do
    assert %{rows: rows} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT indexname
               FROM pg_indexes
               WHERE indexname = ANY($1)
               ORDER BY indexname
               """,
               [
                 [
                   "document_chunks_search_vector_idx",
                   "document_chunks_embedding_diskann_1024_idx",
                   "entities_alias_embedding_diskann_1024_idx",
                   "knowledge_items_embedding_diskann_1024_idx",
                   "knowledge_items_search_vector_idx",
                   "projections_clean_entity_cards_index"
                 ]
               ]
             )

    assert Enum.map(rows, &hd/1) == [
             "document_chunks_embedding_diskann_1024_idx",
             "document_chunks_search_vector_idx",
             "knowledge_items_embedding_diskann_1024_idx",
             "knowledge_items_search_vector_idx",
             "projections_clean_entity_cards_index"
           ]

    assert %{rows: [[knowledge_definition], [chunk_definition]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT indexdef
               FROM pg_indexes
               WHERE indexname = ANY($1)
               ORDER BY indexname DESC
               """,
               [
                 [
                   "knowledge_items_embedding_diskann_1024_idx",
                   "document_chunks_embedding_diskann_1024_idx"
                 ]
               ]
             )

    assert knowledge_definition =~ "diskann_labels"
    assert chunk_definition =~ "diskann_labels"
  end

  test "cross-linked scope reads still require access to both relation endpoints" do
    seeded = seed_active!("f7-scope-link", "/f7/link/source", "Source scope memory.")
    hidden = seed_active!("f7-scope-link", "/f7/link/hidden", "Hidden scope memory.")

    DataLayer.with_account_key("f7-scope-link", fn account, actor ->
      create!(
        ScopeRelation,
        :create,
        %{
          source_scope_id: seeded.scope.id,
          target_scope_id: hidden.scope.id,
          kind: "related",
          metadata: %{}
        },
        account.id,
        actor
      )
    end)

    # A caller authorized for both scopes may follow the link, so the relation demonstrably
    # works. Without this half, the second half would pass even if expansion were broken.
    system_result =
      Memory.search(%{
        "account_key" => "f7-scope-link",
        "scope_path" => seeded.scope.path,
        "query" => "Source scope memory",
        "include_cross_links" => true,
        "strategies" => ["lexical", "relation_expand"],
        "deadline" => "disabled"
      })

    assert hidden.knowledge.id in Enum.map(system_result["candidates"], & &1["id"])

    # The same query as a reader authorized for the source scope only.
    limited_actor = %{seeded.actor | role: :reader, scope_ids: [seeded.scope.id]}

    limited_result =
      Memory.search(
        %{
          "scope_path" => seeded.scope.path,
          "query" => "Source scope memory",
          "include_cross_links" => true,
          "profile" => "thorough",
          "deadline" => "disabled"
        },
        limited_actor
      )

    # A relation between scopes is a hint for expansion, never a grant. Both endpoints must
    # independently pass the caller's authorization, otherwise anyone able to create a
    # relation could read across a boundary they were never given.
    refute hidden.knowledge.id in Enum.map(limited_result["candidates"], & &1["id"])
  end

  # Produces one `active` knowledge item and returns the account, scope, actor, and item.
  #
  # Ingest alone leaves an item awaiting approval, which retrieval correctly hides. These
  # tests are about ranking and authorization, not about the approval lifecycle, so the item
  # is transitioned to `active` through the ordinary governance engine under the pipeline
  # Runs entity_match alone, so what comes back is that strategy's own ranking rather than a
  # fused list another strategy could have supplied the same ids to.
  defp entity_match_candidates!(account_key, scope_path, query \\ "Avery") do
    Memory.search(%{
      "account_key" => account_key,
      "scope_path" => scope_path,
      "query" => query,
      "strategies" => ["entity_match"],
      "deadline" => "disabled"
    })["candidates"]
  end

  # The strategy's own score, which the search response does not carry: candidates reach a
  # caller with the fused `rrf_score`, so the bound that `min_score` and the `low_score` hint
  # depend on cannot be observed through `Memory.search/1` at all.
  defp entity_match_strategy_candidates!(account_key, scope_path, query_text) do
    DataLayer.with_account_key(account_key, fn account, actor ->
      scope =
        Scope
        |> Ash.Query.filter(path == ^scope_path)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)

      peer = read_peer!(account.id, actor)

      query = %Query{
        account_id: account.id,
        actor: %{actor | peer_id: peer.id},
        scope_ids: [scope.id],
        text: query_text,
        target: :knowledge
      }

      budget = %Budget{
        started_at: Clock.monotonic_ms(),
        max_candidates: 50,
        deadline?: false
      }

      Strategies.EntityMatch.candidates(query, budget)
    end)
  end

  # Distinct governed statements that name nobody, so the only entity signal a test sees is the
  # one it states through `mention_entity!/3`.
  defp seed_statements!(account_key, scope_path, count) do
    Enum.map(1..count, fn index ->
      seed_active!(
        account_key,
        scope_path,
        "Release note number #{index} records a routine deployment step.",
        "idf-#{index}"
      )
    end)
  end

  # One entity mentioned by exactly the given statements. Resolution is bypassed so a test can
  # state the frequency it is measuring instead of hoping the fixture extractor produces it.
  defp mention_entity!(account_key, surface_form, seeds) do
    DataLayer.with_account_key(account_key, fn account, actor ->
      pipeline = pipeline_actor(actor)

      entity =
        create!(
          Entity,
          :create_from_pipeline,
          %{
            canonical_name: surface_form,
            kind: "person",
            aliases: [surface_form],
            derived_from: Enum.map(seeds, & &1.knowledge.id)
          },
          account.id,
          pipeline
        )

      Enum.each(seeds, fn seed ->
        create!(
          EntityMention,
          :create_from_pipeline,
          %{
            knowledge_item_id: seed.knowledge.id,
            scope_id: seed.scope.id,
            entity_id: entity.id,
            surface_form: surface_form,
            confidence: 1.0
          },
          account.id,
          pipeline
        )
      end)
    end)
  end

  # The suite's setup restores the whole keyword list on exit, so a test may narrow one knob to
  # a fixture it can afford to seed rather than to production's scale.
  defp put_retrieval_config!(overrides) do
    profiles = Application.fetch_env!(:memhouse, :retrieval_profiles)

    Application.put_env(
      :memhouse,
      :retrieval_profiles,
      Enum.reduce(overrides, profiles, fn {key, value}, acc -> Keyword.put(acc, key, value) end)
    )
  end

  # actor — deliberately going through the engine, not around it, so the transition writes
  # its lifecycle and audit records like any other.
  defp seed_active!(
         account_key,
         scope_path,
         statement,
         session_id \\ "session-1",
         overrides \\ []
       ) do
    assert {:ok, message} =
             Memory.ingest_message(
               Map.merge(
                 %{
                   "account_key" => account_key,
                   "session_id" => session_id,
                   "scope_path" => scope_path,
                   "peer_key" => "avery",
                   "peer_name" => "Avery",
                   "content" => statement
                 },
                 Map.new(overrides, fn {key, value} -> {to_string(key), value} end)
               )
             )

    assert {:ok, [knowledge]} = Memory.extract_message(message["id"], account_key)

    knowledge_id = Map.fetch!(knowledge, "id")

    DataLayer.with_account_key(account_key, fn account, actor ->
      scope =
        Scope
        |> Ash.Query.filter(path == ^scope_path)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)

      knowledge =
        KnowledgeItem
        |> Ash.Query.filter(id == ^knowledge_id)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)

      peer = read_peer!(account.id, actor)
      actor = %{actor | peer_id: peer.id}
      pipeline = pipeline_actor(actor)

      knowledge =
        GovernanceEngine.transition!(
          knowledge,
          pipeline,
          %{state: "active", verification: "auto_verified"},
          reason: "f7_test_activate",
          channel: "pipeline"
        )

      %{account: account, actor: actor, scope: scope, knowledge: knowledge}
    end)
  end

  # Active statements plus the entity and mentions that group them into one card. Entity
  # resolution is bypassed so the cluster shape a test needs is stated rather than inferred from
  # what the fixture extractor happens to link. Returns the first seeded statement.
  defp seed_entity_cluster!(account_key, scope_path, surface_form, kind, statements) do
    slug = String.replace(surface_form, " ", "-")

    seeds =
      statements
      |> Enum.with_index(1)
      |> Enum.map(fn {statement, index} ->
        seed_active!(account_key, scope_path, statement, "#{slug}-#{index}")
      end)

    DataLayer.with_account_key(account_key, fn account, actor ->
      pipeline = pipeline_actor(actor)

      entity =
        create!(
          Entity,
          :create_from_pipeline,
          %{
            canonical_name: surface_form,
            kind: kind,
            aliases: [surface_form],
            derived_from: Enum.map(seeds, & &1.knowledge.id)
          },
          account.id,
          pipeline
        )

      Enum.each(seeds, fn seed ->
        create!(
          EntityMention,
          :create_from_pipeline,
          %{
            knowledge_item_id: seed.knowledge.id,
            scope_id: seed.scope.id,
            entity_id: entity.id,
            surface_form: surface_form,
            confidence: 1.0
          },
          account.id,
          pipeline
        )
      end)
    end)

    hd(seeds)
  end

  # Same as `seed_active!` up to the point of governance: the statement is extracted and stays in
  # its post-extraction state, so it never becomes a card source.
  defp seed_ungoverned!(account_key, scope_path, statement, session_id) do
    assert {:ok, message} =
             Memory.ingest_message(%{
               "account_key" => account_key,
               "session_id" => session_id,
               "scope_path" => scope_path,
               "peer_key" => "avery",
               "peer_name" => "Avery",
               "content" => statement
             })

    assert {:ok, [knowledge]} = Memory.extract_message(message["id"], account_key)
    knowledge_id = Map.fetch!(knowledge, "id")

    DataLayer.with_account_key(account_key, fn account, actor ->
      scope =
        Scope
        |> Ash.Query.filter(path == ^scope_path)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)

      knowledge =
        KnowledgeItem
        |> Ash.Query.filter(id == ^knowledge_id)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)

      refute knowledge.state == "active"

      %{account: account, actor: actor, scope: scope, knowledge: knowledge}
    end)
  end

  # A password-authenticated account administrator, which is the only identity
  # the retrieval diagnostic accepts. `bootstrap_human` is the ordinary path, so
  # the actor carries a real credential kind rather than a hand-set field.
  defp bootstrap_diagnostic_admin!(email) do
    %{actor: actor} =
      Identity.bootstrap_human(%{
        email: email,
        name: "Diagnostic Admin",
        password: "correct horse battery staple"
      })

    actor
  end

  # Same shape as `seed_active!`, for an Account reached through a resolved
  # actor rather than through the internal account-key adapter.
  defp seed_active_as!(admin, scope_path, statement, session_id) do
    assert {:ok, message} =
             Memory.ingest_message(
               %{
                 "session_id" => session_id,
                 "scope_path" => scope_path,
                 "content" => statement
               },
               admin
             )

    assert {:ok, [knowledge]} =
             Memory.extract_message_for_account(message["id"], admin.account_id)

    knowledge_id = Map.fetch!(knowledge, "id")

    DataLayer.with_actor(admin, fn account, actor ->
      item =
        KnowledgeItem
        |> Ash.Query.filter(id == ^knowledge_id)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)

      GovernanceEngine.transition!(
        item,
        pipeline_actor(actor),
        %{state: "active", verification: "auto_verified"},
        reason: "f7_diagnostic_activate",
        channel: "pipeline"
      )
    end)
  end

  defp projection_refresh_count(account_id) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        MemHouse.Repo,
        "SELECT count(*) FROM pipeline_runs WHERE account_id = $1 AND kind = 'projection_refresh'",
        [Ecto.UUID.dump!(account_id)]
      )

    count
  end

  # A five-statement corpus for ranking assertions.
  #
  # One statement carries every content word of the query "Avery release checklist"; three
  # carry a strict subset; one carries none. A single-statement fixture cannot tell a ranked
  # list from an unranked one, nor a conjunctive lexical predicate from a disjunctive one,
  # because every strategy that returns anything returns the same row.
  #
  # The target is seeded first, so the recency-ordered strategies rank it last. Anything that
  # puts it at the head had to use the query.
  #
  # Each statement gets its own session: a peer restating something within one session is a
  # supersession candidate, which would retire rows this fixture needs kept side by side.
  defp seed_ranking_corpus! do
    account_key = "f7-rank"
    scope_path = "/f7/rank"

    # Shortest of the two statements naming both the person and the artifact, which keeps its
    # fixture embedding nearest the query's and makes the semantic order predictable.
    target =
      seed_active!(account_key, scope_path, "Avery maintains the release checklist.", "rank-1")

    shared_person_and_artifact =
      seed_active!(
        account_key,
        scope_path,
        "Avery approved the release notes and the changelog on Monday.",
        "rank-2"
      )

    shared_artifact =
      seed_active!(
        account_key,
        scope_path,
        "Priya updated the release checklist template.",
        "rank-3"
      )

    shared_person =
      seed_active!(
        account_key,
        scope_path,
        "Avery scheduled the quarterly retrospective.",
        "rank-4"
      )

    unrelated =
      seed_active!(account_key, scope_path, "The deployment window moved to Saturday.", "rank-5")

    # Embeddings are a rebuildable cache; rebuilding here keeps the fixture independent of
    # background job timing.
    assert {:ok, %{indexed: 5}} =
             Indexer.rebuild_scope(target.account.id, target.scope.id)

    %{
      target: target,
      shared_person_and_artifact: shared_person_and_artifact,
      shared_artifact: shared_artifact,
      shared_person: shared_person,
      unrelated: unrelated
    }
  end

  defp candidate(id, strategy, rank) do
    %Candidate{id: id, score: 1.0, rank: rank, strategy: strategy, record: %{"id" => id}}
  end

  defp read_peer!(account_id, actor, key \\ "avery") do
    MemHouse.Accounts.Peer
    |> Ash.Query.filter(key == ^key)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  # The internal actor: full scope visibility and permission to touch pipeline-only actions
  # such as relation creation, entity recomputation, and lifecycle transitions. Tests that
  # assert on authorization must use a narrowed actor instead of this one.
  defp pipeline_actor(%Actor{} = actor),
    do: %{actor | role: :system, pipeline?: true, scope_ids: :all}

  # Every durable write goes through an Ash action with the account set as the tenant. The
  # tenant is what applies row-level isolation, so omitting it here would let a test write a
  # row no production code path could produce.
  defp create!(resource, action, attrs, account_id, actor) do
    resource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(action, attrs)
    |> Ash.create!(actor: actor)
  end

  # Forwards the projection-refresh event to the test process and returns the handler id used
  # as the message tag, so an assertion can prove the event fired with the counts an operator
  # would alert on.
  defp attach_projection_refresh_telemetry! do
    attach_telemetry!(:projection_refresh, [:memhouse, :retrieval, :projection_refresh])
  end

  # Same forwarding for the per-component timing event, which is what attributes a slow request
  # to one strategy.
  defp attach_component_telemetry! do
    attach_telemetry!(:component, [:memhouse, :retrieval, :component])
  end

  defp attach_telemetry!(tag, event) do
    handler_id = {__MODULE__, tag, System.unique_integer()}
    test_process = self()

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, measurements, metadata, _config ->
          send(test_process, {handler_id, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    handler_id
  end

  # One-column, one-row raw query, for asserting on tables no Ash action reads back — the
  # usage ledger and counts by id after a row has been deleted out from under a resource.
  defp scalar!(sql, params) do
    %{rows: [[value]]} = Ecto.Adapters.SQL.query!(Repo, sql, params)
    value
  end
end
