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

  Exhaustion returns an error. Malformed output is never partially accepted or coerced.

  ## Content safety

  The repair prompt necessarily contains the model's own previous object, which
  may hold Account content. It goes only to the provider. Nothing from it enters
  telemetry, audit records, or the usage ledger, and validation error strings
  are written to describe shape problems rather than to quote content.
  """

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
  built-in ceiling. Remaining options are passed to the provider.

  Returns `{:ok, value, provenance_map}` where `value` is whatever the schema's
  `cast/2` produced and the provenance map identifies the provider, model, and
  versions that produced it.

  Failure modes: `{:error, {:structured_validation_failed, errors}}` when the
  budget is exhausted, or the provider's own `{:error, reason}` — the latter
  short-circuits immediately, since retrying a transport or credential failure
  with a repair prompt would only burn budget.
  """
  def generate(role, messages, schema, context, opts \\ [])
      when is_atom(schema) and is_list(messages) and is_map(context) do
    # Clamped on both sides: a negative request becomes no repairs, and neither
    # the caller nor deployment configuration can exceed the built-in ceiling.
    max_repairs =
      opts
      |> Keyword.get(:max_repairs, configured_max_repairs())
      |> max(0)
      |> min(@max_repairs)

    generate_attempt(role, messages, schema, context, opts, 0, max_repairs, %{})
  end

  # One attempt, then either success, a recursive repair, or a final error.
  #
  # The `with` deliberately has no else clause: a provider error falls straight
  # through to the caller unchanged, because re-prompting past a transport,
  # authentication, or rate-limit failure cannot help.
  defp generate_attempt(role, messages, schema, context, opts, attempt, max_repairs, usage) do
    # Rides along to the usage ledger so a repaired generation is visibly more
    # than one call rather than looking like a single cheap one.
    call_opts = Keyword.put(opts, :repair_attempt, attempt)

    with {:ok, object, config, attempt_usage} <-
           Gateway.structured_once_with_usage(
             role,
             messages,
             schema.json_schema(),
             context,
             call_opts
           ) do
      usage = merge_usage(usage, attempt_usage)

      case schema.cast(object, context) do
        {:ok, value} ->
          provenance =
            config
            |> Config.provenance()
            |> maybe_put_usage(opts, usage)

          {:ok, value, provenance}

        {:error, errors} when attempt < max_repairs ->
          generate_attempt(
            role,
            repair_messages(messages, object, errors),
            schema,
            context,
            opts,
            attempt + 1,
            max_repairs,
            usage
          )

        {:error, errors} ->
          {:error, {:structured_validation_failed, errors}}
      end
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
