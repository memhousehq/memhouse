# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.CassetteProvider do
  @moduledoc """
  Offline model provider that replays a recorded JSON script instead of calling a
    model.

    Every remote or local model capability in the system — structured extraction, chat,
    embedding, reranking — goes through one behaviour, and the gateway picks the
    implementation from the call context, then from the `:model_provider` application
    environment key, then from the role's configured default. This module contains no
    HTTP client and no fallback path to a real provider, so a test that installs it
    cannot reach a model endpoint.
  """

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Provider.Result

  @doc """
  Loads one scenario from a cassette file and arms it as the next responses.

    Returns `:ok`. Raises if the file is missing or is not valid JSON.
  """
  def start!(path, scenario) do
    entries =
      path
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["scenarios", scenario])
      |> Kernel.||([])

    case Agent.start(fn -> %{entries: entries, calls: []} end, name: __MODULE__) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        Agent.update(__MODULE__, fn _ -> %{entries: entries, calls: []} end)
    end
  end

  @doc """
  Disarms the cassette, discarding any unconsumed entries and the call log.

  Always returns `:ok`, including when nothing is armed, so it is safe to call
  unconditionally from `on_exit`. Note that it does not assert the script was
  fully consumed: a test that cares about leftover entries must check `calls/0`.
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
  Returns the calls served so far, oldest first, as `{operation, role, task}` tuples.

  Operation and role are strings and task is a string or `nil`, matching the
  cassette entries. Use it to assert which model roles a code path actually
  invoked — for example that answering a question consulted exactly one reasoning
  role and nothing else. Exits with `:noproc` if no cassette is armed.
  """
  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  @doc """
  Serves the next recorded response for a structured-output call.

  The task label from `opts` participates in matching, so extraction, reasoning,
  and judging calls made by the same role stay distinguishable in the script.
  Messages and the requested schema are ignored.
  """
  @impl true
  def structured(config, _messages, _schema, opts),
    do: reply("structured", config.role, Keyword.get(opts, :task))

  @doc """
  Serves the next recorded response for a free-form chat call. Matched with a nil task.
  """
  @impl true
  def chat(config, _messages, _opts), do: reply("chat", config.role, nil)

  @doc """
  Serves the next recorded response for an embedding call. Matched with a nil task.

  The recorded value is returned verbatim, so a cassette used with embedding must
  supply vectors whose length matches the dimensions the caller expects.
  """
  @impl true
  def embed(config, _texts, _opts), do: reply("embed", config.role, nil)

  @doc """
  Serves the next recorded response for a rerank call. Matched with a nil task.

  The query and the candidate documents are ignored, so the recorded ordering is
  whatever the cassette says regardless of what was passed in.
  """
  @impl true
  def rerank(config, _query, _documents, _opts), do: reply("rerank", config.role, nil)

  # Consumes exactly one entry per call under the agent's serialised update, so
  # concurrent callers cannot both read the same head entry. The triple check
  # runs before the entry is turned into a result: an out-of-order or unexpected
  # call must fail the test loudly instead of receiving another step's answer.
  defp reply(operation, role, task) do
    Agent.get_and_update(__MODULE__, fn
      %{entries: [entry | rest], calls: calls} = state ->
        expected = {entry["operation"], entry["role"], entry["task"]}
        actual = {operation, Atom.to_string(role), task && Atom.to_string(task)}

        if expected != actual do
          raise "cassette mismatch: expected #{inspect(expected)}, got #{inspect(actual)}"
        end

        result =
          case entry do
            # An "error" entry drives the real failure path in the caller, which
            # must leave durable input intact and the job retryable.
            %{"error" => error} ->
              {:error, String.to_atom(error)}

            _other ->
              {:ok,
               %Result{
                 value: entry["value"],
                 usage: atomize_keys(entry["usage"] || %{}),
                 metadata: atomize_keys(entry["metadata"] || %{})
               }}
          end

        {result, %{state | entries: rest, calls: [actual | calls]}}

      # Running past the end is a test failure, never a default response: an
      # unrecorded call means the code under test changed its model usage.
      %{entries: []} ->
        raise "model cassette exhausted for #{operation}/#{role}"
    end)
  end

  # JSON gives string keys; a provider Result carries atom-keyed usage and
  # metadata. Only ever applied to committed fixture files, so unbounded atom
  # creation is not a concern here.
  defp atomize_keys(map), do: Map.new(map, fn {key, value} -> {String.to_atom(key), value} end)
end
