# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.StructuredGenerator do
  @moduledoc """
  Structured generation with a bounded validate-and-repair loop.

  Generation is non-streaming; only complete, validated objects leave this module.

  ## Why a second validation exists

  Provider schema enforcement is not trusted. Every response passes the schema module's `cast/2`,
  which also enforces domain rules JSON Schema cannot express.

  ## The repair loop

  Validation failure resends the original messages with errors and the prior object. At most two
  repairs are allowed, even if configuration asks for more. Every attempt is separately metered.

  Exhaustion returns an error unless a schema defines a safe recovery for valid
  members of a collection. Recovery never coerces an invalid member.

  ## Content safety

  The repair prompt necessarily contains the model's own previous object, which
  may hold Account content. It goes only to the provider. Nothing from it enters
  telemetry, audit records, or the usage ledger, and validation error strings
  are written to describe shape problems rather than to quote content.
  """

  alias MemHouse.Clock
  alias MemHouse.Model.Config
  alias MemHouse.Model.Gateway

  # Hard ceiling on repair attempts, in extra provider calls after the first.
  # Two is enough to fix realistic formatting slips; beyond that the model is
  # not going to converge and the cost is better spent on a job retry. Also the
  # default when nothing is configured.
  @max_repairs 2

  @doc """
  Generates and validates one structured object.

  `role` is a model role or alias, `messages` the prompt in provider message
  form, and `schema` a module implementing `MemHouse.Model.Schema` — passed as
  a module, not as a built schema map, because both its JSON schema and its
  `cast/2` are needed. `context` is the caller context, and is also handed to
  `cast/2`, so validation can enforce caller-specific rules such as which peers
  may be named as a subject.

  `opts[:max_repairs]` may lower the repair budget but never raise it above the
  built-in ceiling. Callers that coordinate multiple generations may pass an
  absolute monotonic `:request_deadline_ms`; every attempt then receives only
  the remaining `:request_timeout`. Remaining options are passed to the provider.

  Returns `{:ok, value, provenance_map}` where `value` comes from the schema's
  `cast/2` on success, or from the schema's `recover_after_repairs/2` when
  repair budget is exhausted but safe recovery succeeds (see "The repair loop"
  in the moduledoc). The provenance map identifies the provider, model, and
  versions that produced the response.

  Failure modes: `{:error, {:structured_validation_failed, errors}}` when the
  repair budget is exhausted and no recovery path exists or recovery fails, or
  the provider's own `{:error, reason}`. A bounded set of transient
  incomplete-response errors retries the original request within the same
  budget. Other provider errors short-circuit immediately.
  """
  def generate(role, messages, schema, context, opts \\ [])
      when is_atom(schema) and is_list(messages) and is_map(context) do
    case generate_with_attempts(role, messages, schema, context, opts) do
      {:ok, value, provenance, _provider_attempts} -> {:ok, value, provenance}
      {:error, reason, _provider_attempts} -> {:error, reason}
    end
  end

  @doc """
  Generates one structured object and returns the exact provider-attempt count.

  Success is `{:ok, value, provenance, provider_attempts}` and failure is
  `{:error, reason, provider_attempts}`. The count is zero when admission stops
  before the provider callback, one for an unrepaired call, and at most three
  after the bounded repair loop. The ordinary `generate/5` API drops only this
  accounting value and otherwise preserves the same result.
  """
  def generate_with_attempts(role, messages, schema, context, opts \\ [])
      when is_atom(schema) and is_list(messages) and is_map(context) do
    # Clamped on both sides: a negative request becomes no repairs, and neither
    # the caller nor deployment configuration can exceed the built-in ceiling.
    max_repairs =
      opts
      |> Keyword.get(:max_repairs, configured_max_repairs())
      |> max(0)
      |> min(@max_repairs)

    state = %{attempt: 0, max_repairs: max_repairs, usage: %{}, provider_attempts: 0}
    generate_attempt(role, messages, schema, context, opts, state)
  end

  # One attempt, then either success, a recursive repair, or a final error.
  #
  defp generate_attempt(role, messages, schema, context, opts, state) do
    # Rides along to the usage ledger so a repaired generation is visibly more
    # than one call rather than looking like a single cheap one.
    case attempt_opts(opts, state.attempt) do
      {:ok, call_opts} ->
        run_attempt(role, messages, schema, context, opts, call_opts, state)

      {:error, :request_timeout} ->
        {:error, :request_timeout, state.provider_attempts}
    end
  end

  defp run_attempt(role, messages, schema, context, opts, call_opts, state) do
    case Gateway.structured_once_with_usage_and_attempt(
           role,
           messages,
           schema.json_schema(),
           context,
           call_opts
         ) do
      {:ok, object, config, attempt_usage, current_attempts} ->
        state = %{
          state
          | usage: merge_usage(state.usage, attempt_usage),
            provider_attempts: state.provider_attempts + current_attempts
        }

        case schema.cast(object, context) do
          {:ok, value} ->
            provenance =
              config
              |> Config.provenance()
              |> maybe_put_usage(opts, state.usage)

            {:ok, value, provenance, state.provider_attempts}

          {:error, errors} when state.attempt < state.max_repairs ->
            generate_attempt(
              role,
              repair_messages(messages, object, errors),
              schema,
              context,
              opts,
              %{state | attempt: state.attempt + 1}
            )

          {:error, errors} ->
            recover_or_error(
              schema,
              object,
              context,
              config,
              opts,
              state.usage,
              errors,
              state.provider_attempts
            )
        end

      {:error, reason, current_attempts} when state.attempt < state.max_repairs ->
        state = %{state | provider_attempts: state.provider_attempts + current_attempts}

        if retryable_incomplete_response?(reason) do
          generate_attempt(
            role,
            messages,
            schema,
            context,
            opts,
            %{state | attempt: state.attempt + 1}
          )
        else
          {:error, reason, state.provider_attempts}
        end

      {:error, reason, current_attempts} ->
        {:error, reason, state.provider_attempts + current_attempts}
    end
  end

  defp attempt_opts(opts, attempt) do
    call_opts = Keyword.put(opts, :repair_attempt, attempt)

    case Keyword.get(call_opts, :request_deadline_ms) do
      nil ->
        {:ok, call_opts}

      deadline ->
        case deadline - Clock.monotonic_ms() do
          remaining when remaining > 0 ->
            {:ok,
             call_opts
             |> Keyword.put(:request_timeout, remaining)
             |> Keyword.delete(:request_deadline_ms)}

          _exhausted ->
            {:error, :request_timeout}
        end
    end
  end

  defp retryable_incomplete_response?(:missing_structured_object), do: true
  defp retryable_incomplete_response?(:provider_upstream_error), do: true
  defp retryable_incomplete_response?(_reason), do: false

  defp recover_or_error(
         schema,
         object,
         context,
         config,
         opts,
         usage,
         errors,
         provider_attempts
       ) do
    if function_exported?(schema, :recover_after_repairs, 2) do
      case schema.recover_after_repairs(object, context) do
        {:ok, value} ->
          provenance =
            config
            |> Config.provenance()
            |> maybe_put_usage(opts, usage)

          {:ok, value, provenance, provider_attempts}

        :error ->
          {:error, {:structured_validation_failed, errors}, provider_attempts}
      end
    else
      {:error, {:structured_validation_failed, errors}, provider_attempts}
    end
  end

  defp merge_usage(total, current) do
    Enum.reduce([:input_tokens, :output_tokens, :embedding_tokens], total, fn key, acc ->
      value = Map.get(current, key, Map.get(current, Atom.to_string(key), 0)) || 0
      Map.update(acc, key, value, &(&1 + value))
    end)
  end

  defp maybe_put_usage(provenance, opts, usage) do
    if Keyword.get(opts, :return_usage, false),
      do: Map.put(provenance, :usage, usage),
      else: provenance
  end

  # Appends the repair turn to the original conversation rather than replacing
  # it, so the model still sees the task it was given. The instruction not to
  # invent facts matters: a model asked to make output "valid" will otherwise
  # happily fill a required field with something plausible.
  defp repair_messages(messages, object, errors) do
    messages ++
      [
        %{
          role: "user",
          content: """
          Repair the previous structured result so it matches the supplied schema.
          Preserve supported facts, do not invent facts, and return only the repaired object.
          For grounding errors, copy exact supporting text from the cited source in the original messages.
          Validation errors: #{Enum.join(errors, "; ")}
          Previous object: #{Jason.encode!(object)}
          """
        }
      ]
  end

  defp configured_max_repairs do
    :memhouse
    |> Application.get_env(:model_layer, [])
    |> Keyword.get(:max_repairs, @max_repairs)
  end
end
