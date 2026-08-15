# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.Engine do
  @moduledoc """
  Runs retrieval strategies under one deadline, fuses their ranks, and optionally reranks.

  Seed strategies run first. Their interleaved, bounded ids feed expansion strategies; this
  chooses the expansion frontier, not the final order. Weighted reciprocal-rank fusion orders all
  candidates, then a model may rerank the fused head.

  The budget includes profile resolution, strategies, and reranking. A reranking profile
  withholds `rerank_reserved_ms` from its strategy phases, so the stage that decides the final
  order is not paid out of whatever earlier work left behind; the strategies are the stage that
  degrades under pressure. Timeouts are killed without retry and reported as dropped, as is a
  strategy whose dependency was unavailable; reranker failure preserves fusion order. Strategies
  normally run concurrently; tests may run them serially against one sandbox connection.

  Every response preserves the contributed, empty, and dropped name lists and adds content-free
  component outcomes with elapsed time, remaining budget, and deterministic failure classes. A
  strategy that ran and found nothing is not degradation, but it is also not a contribution, and
  a caller cannot tell a ranked answer from a recency dump without seeing the difference. Any
  component that was dropped, or completed with a reason class, is also named in
  `degraded_components`, counted through telemetry, and logged at warning level, because a
  result list carries no visible sign that the stage which orders it never ran.

  Each strategy runs in its own Account transaction and must filter scope, lifecycle, and
  provisional subjects before returning candidates. This module does no post-filtering.
  """

  require Logger

  alias MemHouse.DataLayer
  alias MemHouse.Model.Gateway
  alias MemHouse.Retrieval.{Budget, Candidate, Fusion, Profile, Trace}

  @doc """
  Executes one retrieval request and returns the response map.

  `query` has an authorized Account, actor, and scopes. `profile_name` selects the posture.
  Options:

  * `:deadline?` (default true) — set false to remove the time budget, including
    the reranker's own allowance; only for evaluation runs and dream-time
    rebuilds, never a live request.
  * `:concurrent?` — overrides the application-level concurrency setting; the
    test sandbox turns it off because it owns a single database connection.
  * `:internal?`, `:strategies`, and `:rerank` — naming strategies explicitly or
    forcing the rerank stage on or off is restricted to server-side and
    evaluation callers; profile resolution raises otherwise.
  * `:inherit?` — set false to ignore any stored per-scope profile override.

  Returns profile metadata, latency in milliseconds, contributed, empty, and dropped
  strategies, the degradation summary, the milliseconds withheld for reranking, pre-fusion
  disagreement, and ranked records with `rrf_score` and contributing strategies.

  Raises `ArgumentError` for an unknown profile or strategy name, or for a
  strategy list from a non-internal caller. A strategy killed by the deadline
  never raises, nor does one that reported itself unable to run; both are
  reported as dropped. On the concurrent path an exception
  inside a strategy is likewise reported as a dropped strategy, because the
  task exit is indistinguishable from a timeout; on the serial path it
  propagates to the caller.
  """
  def retrieve(query, profile_name, opts \\ []) do
    # Include profile resolution in the request deadline.
    started_at = MemHouse.Clock.monotonic_ms()
    profile = Profile.resolve(profile_name, query, opts)
    deadline? = Keyword.get(opts, :deadline?, true)

    concurrent? =
      Keyword.get(
        opts,
        :concurrent?,
        Application.get_env(:memhouse, :retrieval_concurrency, true)
      )

    budget = %Budget{
      deadline_ms: profile.deadline_ms,
      started_at: started_at,
      max_candidates: query.max_candidates,
      deadline?: deadline?
    }

    # Reranking changes which candidates the caller sees; expansion mostly changes which ones it
    # does not. Withhold the rerank allowance from the strategies rather than letting them spend
    # it, so slow strategies cost recall instead of costing the ordering.
    reserved_rerank_ms = reserved_rerank_ms(profile, deadline?)
    strategy_budget = %Budget{budget | deadline_ms: profile.deadline_ms - reserved_rerank_ms}

    {seed_lists, seed_outcomes} =
      profile.strategy_modules
      |> Enum.filter(&(&1.stage() == :seed))
      |> run_phase(query, strategy_budget, concurrent?)

    # Interleave before fusion for a diverse expansion frontier. Expansion is query-independent,
    # so only the trustworthy seed head may cause more database work. Taking before `uniq` keeps
    # the frontier bounded even when strategies agree. Filter for knowledge candidates before
    # sorting and capping so document chunks do not waste seed slots; relation_expand is
    # knowledge-only.
    seed_ids =
      seed_lists
      |> Enum.flat_map(fn {_strategy, candidates} -> candidates end)
      |> Enum.filter(fn candidate ->
        candidate.record["candidate_type"] == "knowledge"
      end)
      |> Enum.sort_by(& &1.rank)
      |> Enum.take(min(query.max_candidates, retrieval_config(:expand_seed_limit)))
      |> Enum.map(& &1.id)
      |> Enum.uniq()

    expanded_query = %{query | seed_ids: seed_ids}

    {expand_lists, expand_outcomes} =
      profile.strategy_modules
      |> Enum.filter(&(&1.stage() == :expand))
      |> run_phase(expanded_query, strategy_budget, concurrent?)

    lists = seed_lists ++ expand_lists
    fused = Fusion.reciprocal_rank(lists, profile.weights, query.max_candidates)
    pre_rerank_remaining_ms = Budget.remaining_ms(budget)

    {ranked, rerank_outcome} =
      maybe_rerank(fused, query, profile, budget, concurrent?, pre_rerank_remaining_ms)

    # Running to completion is not contributing. A strategy that returned nothing is reported
    # separately, because collapsing it into either other set hides the run that ranked the
    # scope instead of the query.
    {contributing_lists, empty_lists} =
      Enum.split_with(lists, fn {_strategy, candidates} -> candidates != [] end)

    # Include disabled, timed-out, and failed work so callers can distinguish degradation.
    disabled_outcomes =
      Enum.map(profile.disabled_strategies, fn strategy ->
        outcome(strategy, "disabled", 0, Budget.remaining_ms(budget))
      end)

    outcomes = disabled_outcomes ++ seed_outcomes ++ expand_outcomes ++ List.wrap(rerank_outcome)

    dropped =
      for %{component: component, status: "dropped"} <- outcomes,
          do: component

    # Completing with a reason class is still degradation: a partially reranked head is not the
    # ordering the profile promises, and collapsing it into "completed" hides that.
    degraded_components =
      for %{component: component, status: status, reason_class: reason_class} <- outcomes,
          status == "dropped" or not is_nil(reason_class),
          uniq: true,
          do: component

    query_dependent =
      for module <- profile.strategy_modules, module.query_dependent?(), do: module.name()

    result = %{
      query: query.text,
      profile: Atom.to_string(profile.name),
      profile_version: profile.version,
      deadline: if(deadline?, do: "enabled", else: "disabled"),
      latency_ms: MemHouse.Clock.monotonic_ms() - started_at,
      contributed_strategies: strategy_names(contributing_lists),
      empty_strategies: strategy_names(empty_lists),
      dropped_strategies: Enum.uniq(dropped),
      degraded: degraded_components != [],
      degraded_components: degraded_components,
      retrieval_outcomes: outcomes,
      pre_rerank_remaining_ms: finite_remaining(pre_rerank_remaining_ms),
      reserved_rerank_ms: reserved_rerank_ms,
      # Fusion destroys evidence of strategy disagreement.
      disagreement: Fusion.disagreement(seed_lists, query_dependent),
      candidates: Enum.map(ranked, &candidate_map/1)
    }

    result =
      if Keyword.get(opts, :diagnostic_trace?, false) do
        Map.put(
          result,
          :diagnostic_trace,
          Trace.build(
            lists,
            fused,
            ranked,
            profile.weights,
            retrieval_config(:rerank_head),
            rerank_outcome
          )
        )
      else
        result
      end

    emit_outcomes(query.account_id, result, profile.deadline_ms, query.max_candidates)
    result
  end

  defp strategy_names(lists) do
    lists
    |> Enum.map(fn {strategy, _candidates} -> Atom.to_string(strategy) end)
    |> Enum.uniq()
  end

  # Inapplicable strategies are skipped, not reported as degraded.
  defp run_phase([], _query, _budget, _concurrent?), do: {[], []}

  defp run_phase(modules, query, budget, concurrent?) do
    applicable = Enum.filter(modules, & &1.applicable?(query))
    remaining = Budget.remaining_ms(budget)
    timeout = strategy_timeout(remaining)

    if remaining == 0 do
      # Report applicable work that the exhausted budget prevented.
      {[],
       Enum.map(applicable, fn module ->
         outcome(module.name(), "deadline_exhausted_before_start", 0, 0)
       end)}
    else
      results = execute_modules(applicable, query, budget, timeout, concurrent?)

      completed =
        for {:ok, {strategy, candidates, _elapsed_ms, _remaining_ms}} <- results,
            is_list(candidates),
            do: {strategy, candidates}

      # A strategy that could not run at all — an unavailable embedder, say — is
      # degradation, not absence, so it joins the dropped list rather than
      # contributing an empty result the caller would read as "nothing matched".
      outcomes =
        results
        |> Enum.with_index()
        |> Enum.map(fn
          {{:ok, {strategy, candidates, elapsed_ms, remaining_ms}}, _index}
          when is_list(candidates) ->
            completed_outcome(strategy, elapsed_ms, remaining_ms)

          {{:ok, {strategy, {:error, _reason}, elapsed_ms, remaining_ms}}, _index} ->
            outcome(strategy, "dependency_unavailable", elapsed_ms, remaining_ms)

          {{:exit, :timeout}, index} ->
            outcome(
              Enum.at(applicable, index).name(),
              "timeout",
              timeout,
              finite_remaining(Budget.remaining_ms(budget))
            )

          {{:exit, _reason}, index} ->
            outcome(
              Enum.at(applicable, index).name(),
              "provider_error",
              timeout,
              finite_remaining(Budget.remaining_ms(budget))
            )
        end)

      {completed, outcomes}
    end
  end

  defp strategy_timeout(:infinity), do: :infinity

  defp strategy_timeout(remaining) do
    min(remaining, retrieval_config(:strategy_timeout_ms))
  end

  defp execute_modules(modules, query, budget, timeout, concurrent?) do
    run = fn module ->
      started_at = MemHouse.Clock.monotonic_ms()
      # Pin the database session to the Account and validate lazily read records inside it.
      candidates =
        DataLayer.with_actor(query.actor, fn _account, actor ->
          scoped_query = %{query | actor: actor}
          candidates = module.candidates(scoped_query, budget)

          MemHouse.Retrieval.Strategy.validate!(
            module,
            candidates,
            min(query.max_candidates, budget.max_candidates)
          )
        end)

      {module.name(), candidates, MemHouse.Clock.monotonic_ms() - started_at,
       finite_remaining(Budget.remaining_ms(budget))}
    end

    if concurrent? do
      # Ordering maps task exits to strategies; timed-out work is killed without retry.
      Task.async_stream(modules, run,
        ordered: true,
        max_concurrency: max(length(modules), 1),
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.to_list()
    else
      # The single-connection test path cannot kill work, so it classifies an overrun after the
      # strategy returns and enforces the remaining budget before starting the next strategy.
      Enum.map(modules, &run_serial(&1, run, budget, timeout))
    end
  end

  defp run_serial(module, run, budget, timeout) do
    if Budget.remaining_ms(budget) == 0 do
      {:exit, :timeout}
    else
      started_at = MemHouse.Clock.monotonic_ms()
      result = run.(module)
      elapsed = MemHouse.Clock.monotonic_ms() - started_at

      if timeout != :infinity and elapsed > timeout, do: {:exit, :timeout}, else: {:ok, result}
    end
  end

  # Reranker failure preserves fusion order and reports degradation.
  defp maybe_rerank(candidates, _query, %{rerank: false}, _budget, _concurrent?, _remaining),
    do: {candidates, nil}

  defp maybe_rerank([], _query, _profile, _budget, _concurrent?, _remaining), do: {[], nil}

  defp maybe_rerank(candidates, query, _profile, budget, concurrent?, remaining) do
    if remaining == 0 do
      {candidates, outcome(:reranker, "deadline_exhausted_before_start", 0, 0)}
    else
      # Rerank only the visible head to bound model cost and latency.
      head_size = retrieval_config(:rerank_head)
      {head, tail} = Enum.split(candidates, head_size)
      documents = Enum.map(head, & &1.record["statement"])

      # The model layer scopes its own reads and usage writes; do not hold a database connection
      # during the external call.
      call = fn ->
        Gateway.rerank(
          query.text,
          documents,
          %{
            account_id: query.account_id,
            actor: query.actor
          },
          deadline?: budget.deadline?
        )
      end

      allowance = rerank_allowance(remaining)
      started_at = MemHouse.Clock.monotonic_ms()

      case deadline_call(call, allowance, concurrent?) do
        {:ok, rankings, _provenance} ->
          elapsed_ms = MemHouse.Clock.monotonic_ms() - started_at
          finish_rerank(rankings, head, tail, candidates, elapsed_ms, budget)

        {:error, :timeout} ->
          {candidates,
           outcome(:reranker, "timeout", allowance, finite_remaining(Budget.remaining_ms(budget)))}

        {:error, _error} ->
          {candidates,
           outcome(
             :reranker,
             "provider_error",
             MemHouse.Clock.monotonic_ms() - started_at,
             finite_remaining(Budget.remaining_ms(budget))
           )}
      end
    end
  end

  defp finish_rerank(rankings, head, tail, candidates, elapsed_ms, budget) do
    remaining_ms = finite_remaining(Budget.remaining_ms(budget))

    case ranking_order(rankings, length(head)) do
      {:ok, order, completeness} ->
        reordered =
          order
          |> Enum.map(&Enum.at(head, &1))
          |> Kernel.++(tail)
          |> Enum.with_index(1)
          |> Enum.map(fn {candidate, rank} -> %{candidate | rank: rank} end)

        {reordered, rerank_outcome(completeness, elapsed_ms, remaining_ms)}

      :error ->
        {candidates, outcome(:reranker, "invalid_result", elapsed_ms, remaining_ms)}
    end
  end

  defp rerank_outcome(:complete, elapsed_ms, remaining_ms),
    do: completed_outcome(:reranker, elapsed_ms, remaining_ms)

  # Ran, produced a usable ordering, and still did less than it was asked to. Reporting it as a
  # drop would claim fusion order survived when it did not; reporting it as a clean completion
  # would hide that part of the head was never judged.
  defp rerank_outcome(:partial, elapsed_ms, remaining_ms) do
    %{
      completed_outcome(:reranker, elapsed_ms, remaining_ms)
      | reason_class: "partial_rankings"
    }
  end

  defp deadline_call(call, :infinity, _concurrent?), do: call.()

  defp deadline_call(call, timeout, concurrent?) do
    if concurrent? do
      task = Task.async(call)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
      end
    else
      # The SQL sandbox owns one connection, including the model-role lookup.
      # Run inline there and classify an overrun after return; production uses
      # the task path above and kills work at the allowance.
      started_at = MemHouse.Clock.monotonic_ms()
      result = call.()

      if MemHouse.Clock.monotonic_ms() - started_at >= timeout,
        do: {:error, :timeout},
        else: result
    end
  end

  # Turns provider rankings into the head order to apply, or `:error` when the intended order
  # cannot be known.
  #
  # A model that scored only part of the head still scored that part, and discarding the call
  # throws away real work to keep an ordering nobody asked for. So a short answer is honoured:
  # the indexes it returned lead, in its order, and the rest follow in fusion order. A duplicate
  # or out-of-range index is different in kind — it makes the intended order unknowable — and
  # still fails the whole result. An empty list ranks nothing and is likewise a failure.
  defp ranking_order(rankings, expected) when is_list(rankings) and rankings != [] do
    scored = Enum.map(rankings, &ranking_pair(&1, expected))
    indexes = for {index, _score} <- scored, do: index

    if :error in scored or length(Enum.uniq(indexes)) != length(indexes) do
      :error
    else
      ranked =
        scored
        |> Enum.sort_by(fn {_index, score} -> score end, :desc)
        |> Enum.map(fn {index, _score} -> index end)

      remainder = Enum.reject(0..(expected - 1), &(&1 in ranked))
      completeness = if remainder == [], do: :complete, else: :partial

      {:ok, ranked ++ remainder, completeness}
    end
  end

  defp ranking_order(_rankings, _expected), do: :error

  # Accepts provider key variants. A missing, non-integer, or out-of-range index is a failure
  # rather than a default, because a default silently reorders a candidate the model never
  # judged.
  defp ranking_pair(ranking, expected) do
    index = ranking_value(ranking, :index)
    score = ranking_value(ranking, :relevance_score, :score)

    if is_integer(index) and index in 0..(expected - 1) and is_number(score),
      do: {index, score},
      else: :error
  end

  defp ranking_value(ranking, key, fallback_key \\ nil)

  defp ranking_value(ranking, key, fallback_key) when is_map(ranking) do
    Map.get(ranking, key) || Map.get(ranking, Atom.to_string(key)) ||
      (fallback_key &&
         (Map.get(ranking, fallback_key) || Map.get(ranking, Atom.to_string(fallback_key))))
  end

  defp ranking_value(_ranking, _key, _fallback_key), do: nil

  # A run with no deadline is usually measuring the reranked ordering itself, so capping the
  # stage that produces it would measure the wrong thing. It is also the only mode in which a
  # provider without a native rerank endpoint may fall back to structured generation, which
  # cannot finish inside a live allowance.
  defp rerank_allowance(:infinity), do: :infinity
  defp rerank_allowance(remaining), do: min(remaining, retrieval_config(:rerank_timeout_ms))

  # Nothing is withheld from a profile that does not rerank, or from a run with no clock to
  # divide. The half-deadline clamp keeps a large reservation from starving retrieval of the
  # candidates the reranker exists to order. The lower bound matters just as much: a negative
  # value would be subtracted as extra strategy time and push the phases past the profile
  # deadline, which is the one ceiling the request is not allowed to cross.
  defp reserved_rerank_ms(%{rerank: true} = profile, true) do
    retrieval_config(:rerank_reserved_ms)
    |> max(0)
    |> min(div(profile.deadline_ms, 2))
  end

  defp reserved_rerank_ms(_profile, _deadline?), do: 0

  defp completed_outcome(component, elapsed_ms, remaining_ms) do
    %{
      component: Atom.to_string(component),
      status: "completed",
      reason_class: nil,
      elapsed_ms: elapsed_ms,
      budget_remaining_ms: remaining_ms
    }
  end

  defp outcome(component, reason_class, elapsed_ms, remaining_ms) do
    %{
      component: Atom.to_string(component),
      status: "dropped",
      reason_class: reason_class,
      elapsed_ms: elapsed_ms,
      budget_remaining_ms: remaining_ms
    }
  end

  defp finite_remaining(:infinity), do: nil
  defp finite_remaining(value), do: value

  defp emit_outcomes(account_id, result, deadline_ms, max_candidates) do
    MemHouse.Retrieval.Diagnostics.record(account_id, result, deadline_ms, max_candidates)

    :telemetry.execute(
      [:memhouse, :retrieval, :outcomes],
      %{
        latency_ms: result.latency_ms,
        pre_rerank_remaining_ms: result.pre_rerank_remaining_ms || 0
      },
      %{
        account_id: account_id,
        profile: result.profile,
        deadline_ms: deadline_ms,
        outcomes: result.retrieval_outcomes
      }
    )

    report_component_timings(account_id, result)
    report_degradation(account_id, result)
  end

  # The per-component elapsed time already rides along as `:outcomes` metadata, where a metrics
  # reporter cannot aggregate it: attributing a slow request to one strategy then needs the raw
  # events. Repeat it as a measurement, one event per component, so which strategy owns the
  # latency is a summary over `elapsed_ms` by `component` rather than an investigation.
  defp report_component_timings(account_id, result) do
    for outcome <- result.retrieval_outcomes do
      :telemetry.execute(
        [:memhouse, :retrieval, :component],
        %{elapsed_ms: outcome.elapsed_ms},
        %{
          account_id: account_id,
          profile: result.profile,
          component: outcome.component,
          status: outcome.status,
          reason_class: outcome.reason_class
        }
      )
    end

    :ok
  end

  # One counter increment and one warning per degraded component. A caller that ignores the
  # `degraded` flag still leaves a trace an operator can alert on, and a reranker that never runs
  # in production is otherwise indistinguishable from one that runs and agrees with fusion.
  defp report_degradation(account_id, result) do
    for %{component: component, reason_class: reason_class} <- result.retrieval_outcomes,
        component in result.degraded_components do
      :telemetry.execute(
        [:memhouse, :retrieval, :degraded],
        %{count: 1},
        %{
          account_id: account_id,
          profile: result.profile,
          component: component,
          reason_class: reason_class
        }
      )

      Logger.warning("retrieval component degraded",
        account_id: account_id,
        component: component,
        reason_class: reason_class
      )
    end

    :ok
  end

  # Do not expose incomparable strategy-local scores.
  defp candidate_map(%Candidate{} = candidate) do
    candidate.record
    |> Map.put("rrf_score", candidate.score)
    |> Map.put(
      "strategies",
      candidate.evidence
      |> Map.get("strategies", [])
      |> Enum.map(&Atom.to_string/1)
    )
  end

  defp retrieval_config(key) do
    :memhouse
    |> Application.fetch_env!(:retrieval_profiles)
    |> Keyword.fetch!(key)
  end
end
