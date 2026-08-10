# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.GroundedAnswerProvider do
  @moduledoc """
  Offline provider for exercising grounded answer assembly at public boundaries.

  The provider delegates extraction, embedding, chat, and reranking to the
  deterministic adapter. For dialectic generation it returns one of a small set
  of deliberately controlled citation/abstention combinations and records the
  prompt. Tests use those combinations to prove that answer assembly preserves
  supported uncertainty while still rejecting invented citations.

  This module is test-only and uses one unlinked, globally named Agent. Suites
  that arm it must run synchronously, restore the application provider, and call
  `stop/0` during cleanup. It must never be configured outside tests.
  """

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Provider.Result
  alias MemHouse.Model.Providers.Deterministic

  @supported_answer "The recorded statements do not establish this, but they support a preference for concise weekly release summaries."
  @inferred_answer "Avery most likely prefers concise weekly release summaries."

  @doc """
  Arms the dialectic response mode and clears all previously recorded prompts.

  Supported modes are `:grounded_abstention`,
  `:grounded_abstention_with_invented_citation`, `:unsupported_assertion`,
  `:confident_inference`, `:low_confidence_inference`, and `:provider_error`.
  Returns `:ok`; raises for an unsupported mode.
  """
  def start!(mode)
      when mode in [
             :grounded_abstention,
             :grounded_abstention_with_invented_citation,
             :unsupported_assertion,
             :confident_inference,
             :low_confidence_inference,
             :provider_error
           ] do
    state = %{mode: mode, prompts: []}

    case Agent.start(fn -> state end, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> Agent.update(__MODULE__, fn _ -> state end)
    end
  end

  @doc """
  Stops the provider recorder and discards its response mode and prompt log.

  Returns `:ok` even when it was not armed, so cleanup may call it
  unconditionally.
  """
  def stop do
    if Process.whereis(__MODULE__), do: Agent.stop(__MODULE__)
    :ok
  end

  @doc """
  Returns dialectic prompts in call order.

  Raises with `:noproc` when the provider was not armed.
  """
  def prompts, do: Agent.get(__MODULE__, &Enum.reverse(&1.prompts))

  @doc """
  Returns the controlled dialectic response or delegates other structured work.

  A dialectic call raises when the prompt contains no bracketed retrieved
  knowledge id, because every armed mode is intended to exercise a cited
  candidate path. Delegated deterministic failures are returned unchanged.
  """
  @impl true
  def structured(config, messages, schema, opts) do
    if Keyword.get(opts, :task) == :dialectic do
      dialectic_reply(messages)
    else
      Deterministic.structured(config, messages, schema, opts)
    end
  end

  @doc "Returns the deterministic adapter's free-form chat result."
  @impl true
  def chat(config, messages, opts), do: Deterministic.chat(config, messages, opts)

  @doc "Returns deterministic embeddings using the resolved role configuration."
  @impl true
  def embed(config, texts, opts), do: Deterministic.embed(config, texts, opts)

  @doc "Returns the deterministic adapter's reranking result."
  @impl true
  def rerank(config, query, documents, opts),
    do: Deterministic.rerank(config, query, documents, opts)

  defp dialectic_reply(messages) do
    prompt = messages |> List.last() |> Map.fetch!(:content)

    cited_id =
      case Regex.run(~r/^\s*\[([^\]]+)\]\s/m, prompt, capture: :all_but_first) do
        [id] -> id
        nil -> raise "grounded-answer fixture received no retrieved knowledge id"
      end

    mode =
      Agent.get_and_update(__MODULE__, fn state ->
        {state.mode, %{state | prompts: [prompt | state.prompts]}}
      end)

    if mode == :provider_error do
      # Exercises the answering call failing outright, the same shape a
      # transport or upstream error returns from the real ReqLLM adapter — no
      # decoded object ever reaches `MemHouse.Memory.model_answer/3`.
      {:error, :provider_upstream_error}
    else
      structured_reply(mode, cited_id)
    end
  end

  defp structured_reply(mode, cited_id) do
    value =
      case mode do
        :grounded_abstention ->
          %{
            "answer" => @supported_answer,
            "citations" => [cited_id],
            "abstained" => true,
            "answer_confidence" => 30
          }

        :grounded_abstention_with_invented_citation ->
          %{
            "answer" => @supported_answer,
            "citations" => [cited_id, "invented-knowledge-id"],
            "abstained" => true,
            "answer_confidence" => 30
          }

        :unsupported_assertion ->
          %{
            "answer" => "This assertion has no retrieved support.",
            "citations" => ["invented-knowledge-id"],
            "abstained" => false,
            "answer_confidence" => 90
          }

        # A tier-2 inference the model is sure enough of to present as a
        # conclusion, which must survive as `abstained => false`.
        :confident_inference ->
          %{
            "answer" => @inferred_answer,
            "citations" => [cited_id],
            "abstained" => false,
            "answer_confidence" => 80
          }

        # The same inference below the threshold. The model claims a conclusion
        # and must not get one.
        :low_confidence_inference ->
          %{
            "answer" => @inferred_answer,
            "citations" => [cited_id],
            "abstained" => false,
            "answer_confidence" => 20
          }
      end

    {:ok,
     %Result{
       value: value,
       usage: %{input_tokens: 20, output_tokens: 12},
       metadata: %{fixture: true}
     }}
  end
end
