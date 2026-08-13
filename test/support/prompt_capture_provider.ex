# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.PromptCaptureProvider do
  @moduledoc """
  Offline model provider that records the prompt it was given and returns one
  fixed extraction candidate.

  It exists so a test can assert what the pipeline actually shows a model.
  Nothing else can: prompts are built inside the caller and are deliberately
  kept out of usage records, telemetry, and job arguments, so the provider seam
  is the only place they are observable.

  Arm it with `start!/1`, install it as `:model_provider`, then read `messages/0`.
  Only `structured/4` records; the other capabilities raise, so a test that
  reaches them by accident fails loudly instead of getting a silent stub.
  """

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Provider.Result

  @doc """
  Arms the provider so the next `structured/4` call returns exactly `candidates`.

  Each entry must already be the string-keyed candidate shape the extraction
  schema validates. Returns `:ok`, replacing any previously armed state.
  """
  def start!(candidates) do
    case Agent.start(fn -> %{candidates: candidates, messages: []} end, name: __MODULE__) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        Agent.update(__MODULE__, fn _ -> %{candidates: candidates, messages: []} end)
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

  # The agent can die between the lookup above and the stop below. An exit raised out of
  # `on_exit` abandons the rest of teardown, and these providers are installed as the global
  # `:model_provider`, so an abandoned restore leaves every later test calling a dead process.
  defp stop_if_alive(pid) do
    Agent.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Returns the message lists served so far, oldest call first.

  Exits with `:noproc` when the provider is not armed.
  """
  def messages, do: Agent.get(__MODULE__, &Enum.reverse(&1.messages))

  @doc """
  Records the prompt and returns the armed candidates.
  """
  @impl true
  def structured(_config, messages, _schema, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      result = {:ok, %Result{value: %{"items" => state.candidates}}}
      {result, %{state | messages: [messages | state.messages]}}
    end)
  end

  @impl true
  def chat(_config, _messages, _opts), do: raise("PromptCaptureProvider serves structured only")

  @impl true
  def embed(_config, _texts, _opts), do: raise("PromptCaptureProvider serves structured only")

  @impl true
  def rerank(_config, _query, _documents, _opts),
    do: raise("PromptCaptureProvider serves structured only")
end
