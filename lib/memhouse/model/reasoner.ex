# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.Reasoner do
  @moduledoc """
  The background reasoning capability: re-reads recent knowledge and proposes
  deductions and relations.

  This slow lane revisits a delta and stored working set when budget allows.

  `MemHouse.Pipeline.DreamTime` is its production caller. It supplies only
  active knowledge from one Account and scope, then applies accepted output
  through the ordinary governance operations.

  ## What it may and may not produce

  Reasoning proposes schema-validated candidates; governance decides. Contradictions return as
  typed relation edges and never overwrite statements.

  ## Mistakes to avoid

  - Do not treat a returned candidate as active knowledge. It has passed schema
    validation, nothing more.
  - Do not call this on a request path. It is the slow lane by design. Dream-time
    supplies a pass deadline, which split operations share rather than restart.
  """

  alias MemHouse.{Clock, Model}
  alias MemHouse.Model.Schema.{Reasoning, ReasoningSynthesis, ReasoningUpdate}
  alias MemHouse.Observability

  # Names the prompt template below, and is passed to the gateway as a call
  # option. Note that the `prompt_version` actually stamped on provenance and
  # usage rows comes from the resolved `dream_reasoner` role, not from here; the
  # two are kept equal on purpose, so editing the prompt means bumping both.
  @prompt_version "reason-1"
  @update_prompt_version "reason-update-1"
  @synthesis_prompt_version "reason-synthesis-1"

  @doc """
  Runs the independently versioned operations enabled for dream-time.

  `:request_timeout` sets one monotonic millisecond budget for the complete
  operation set. Each provider call receives only the remaining allowance.
  Exhaustion before an operation starts returns `{:error, :request_timeout}`.
  A caller coordinating a larger pass may instead supply the absolute monotonic
  millisecond `:request_deadline_ms`; when both options are present, that
  deadline takes precedence and `:request_timeout` is replaced with its
  remaining allowance for each operation.

  Every enabled operation must finish before the caller enters the single
  governed writer transaction. Completed calls remain usage-accounted, but a
  failure returns no partial result, so the scoped watermark cannot advance on
  half an operation set.
  """
  def reason_operations(delta_and_working_set, context, opts \\ []) do
    operations = enabled_operations()
    deadline = pass_deadline(opts)

    operations
    |> Enum.reduce_while({:ok, %{items: [], relations: []}, []}, fn operation,
                                                                    {:ok, combined, provenance} ->
      with {:ok, operation_opts} <- remaining_operation_opts(opts, deadline),
           {:ok, result, operation_provenance} <-
             run_operation(operation, delta_and_working_set, context, operation_opts) do
        combined = %{
          items: combined.items ++ result.items,
          relations: combined.relations ++ result.relations
        }

        {:cont, {:ok, combined, [operation_provenance | provenance]}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, combined, provenance} ->
        {:ok, combined, %{operations: Enum.reverse(provenance)}}

      error ->
        error
    end
  end

  defp pass_deadline(opts) do
    case Keyword.get(opts, :request_deadline_ms) do
      deadline when is_integer(deadline) ->
        deadline

      _deadline ->
        case Keyword.get(opts, :request_timeout) do
          timeout when is_integer(timeout) and timeout > 0 -> Clock.monotonic_ms() + timeout
          _timeout -> nil
        end
    end
  end

  defp remaining_operation_opts(opts, nil), do: {:ok, opts}

  defp remaining_operation_opts(opts, deadline) do
    case deadline - Clock.monotonic_ms() do
      remaining when remaining > 0 ->
        {:ok,
         opts
         |> Keyword.put(:request_timeout, remaining)
         |> Keyword.put(:request_deadline_ms, deadline)}

      _exhausted ->
        {:error, :request_timeout}
    end
  end

  @doc "Returns enabled operations in their fixed writer order."
  def enabled_operations do
    config = Application.fetch_env!(:memhouse, :dream_reasoning_operations)

    [:update, :synthesis]
    |> Enum.filter(&Keyword.fetch!(config, &1))
  end

  @doc "Returns the independently versioned prompt identity for each split operation."
  def operation_prompt_versions do
    %{"update" => @update_prompt_version, "synthesis" => @synthesis_prompt_version}
  end

  @doc """
  Returns whether the experimental split dream-reasoning contract is enabled.

  When false, callers must use the legacy single-call reasoning path. The value
  is read dynamically so a matched evaluation can enable and restore it without
  changing the deployment default.
  """
  def split_enabled? do
    :memhouse
    |> Application.fetch_env!(:dream_reasoning_operations)
    |> Keyword.fetch!(:split_enabled)
  end

  @doc """
  Runs one reasoning pass over a delta and its working set.

  `delta_and_working_set` is any JSON-encodable term describing what changed and
  the surrounding knowledge to reason over; it is serialized as the user turn.
  `context` is the caller context, and must carry the Account and scope so
  candidate subjects can be validated and usage attributed.

  Returns `{:ok, %{items: candidates, relations: edges}, provenance_map}`, or an
  error from structured generation — a validation failure after the repair
  budget, or a provider error. Errors are returned rather than raised, and
  nothing partial is applied.
  """
  def reason(delta_and_working_set, context, opts \\ []) do
    messages = [
      %{
        role: "system",
        content: """
        Revisit the supplied delta and working set. Return only supported
        deductions, update candidates, and supports/contradicts/derived_from
        relations in the supplied schema. Every deduction must cite at least two
        contributor ids from the working set. Never overwrite contradictions.
        """
      },
      %{role: "user", content: Jason.encode!(delta_and_working_set)}
    ]

    case Model.generate_structured(
           :dream_reasoner,
           messages,
           Reasoning,
           context,
           Keyword.merge([task: :reasoning, prompt_version: @prompt_version], opts)
         ) do
      {:ok, result, provenance} ->
        {:ok, %{result | items: Enum.map(result.items, &Map.merge(&1, provenance))}, provenance}

      {:error, error} ->
        {:error, error}
    end
  end

  defp run_operation(:update, input, context, opts) do
    messages = [
      %{
        role: "system",
        content: """
        Compare only the supplied active records. Return supports or
        contradicts edges using their exact ids. Do not create statements,
        explain hidden reasoning, choose lifecycle state, or request deletion.
        """
      },
      %{role: "user", content: Jason.encode!(input)}
    ]

    generate_operation(
      messages,
      ReasoningUpdate,
      context,
      :reasoning_update,
      @update_prompt_version,
      opts
    )
  end

  defp run_operation(:synthesis, input, context, opts) do
    messages = [
      %{
        role: "system",
        content: """
        Propose only cross-source knowledge whose cited active ids collectively
        carry at least two distinct supplied source_observations. Cite every
        contributor id exactly. Multiple knowledge ids with the same source
        observation still count as one source and are invalid. Do not classify
        contradictions, choose lifecycle state, explain hidden reasoning, or
        request deletion.
        """
      },
      %{role: "user", content: Jason.encode!(input)}
    ]

    generate_operation(
      messages,
      ReasoningSynthesis,
      context,
      :reasoning_synthesis,
      @synthesis_prompt_version,
      opts
    )
  end

  defp generate_operation(messages, schema, context, task, prompt_version, opts) do
    started_at = System.monotonic_time(:millisecond)

    case Model.generate_structured(
           :dream_reasoner,
           messages,
           schema,
           context,
           Keyword.merge(
             [task: task, return_usage: true],
             opts
           )
         ) do
      {:ok, result, provenance} ->
        operation_provenance =
          provenance
          |> Map.put(:operation_prompt_version, prompt_version)
          |> Map.put(:operation, Atom.to_string(task))

        items = Enum.map(result.items, &Map.merge(&1, operation_provenance))
        usage = Map.get(operation_provenance, :usage, %{})

        emit_operation(
          task,
          prompt_version,
          context,
          %{
            calls: 1,
            input_tokens: Map.get(usage, :input_tokens, 0),
            output_tokens: Map.get(usage, :output_tokens, 0),
            items: length(items) + length(result.relations),
            accepted: length(items) + length(result.relations),
            elapsed_ms: System.monotonic_time(:millisecond) - started_at
          },
          "ok",
          nil
        )

        {:ok, %{result | items: items}, operation_provenance}

      {:error, error} ->
        emit_operation(
          task,
          prompt_version,
          context,
          %{
            calls: 1,
            rejected: 1,
            failures: 1,
            elapsed_ms: System.monotonic_time(:millisecond) - started_at
          },
          "failed",
          failure_class(error)
        )

        {:error, error}
    end
  end

  defp emit_operation(task, prompt_version, context, measurements, status, failure_class) do
    Observability.emit_operation(
      task,
      measurements,
      %{
        version: prompt_version,
        status: status,
        failure_class: failure_class,
        account_id: Map.get(context, :account_id),
        scope_id: Map.get(context, :scope_id)
      }
    )
  end

  defp failure_class({:structured_validation_failed, _errors}),
    do: "structured_validation_failed"

  defp failure_class(%module{}), do: inspect(module)
  defp failure_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_class(_reason), do: "reasoning_failed"
end
