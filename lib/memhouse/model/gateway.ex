# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.Gateway do
  @moduledoc """
  The one place that invokes a model provider.

  Every structured generation, chat, embedding, and rerank passes through here. No other module
  may call a provider. Every attempt, including failures and repairs:

  1. The role is resolved to a pinned provider, model, and version set.
  2. A tracing span records safe timings, counts, and identities.
  3. Exactly one durable usage record is appended, whenever the context carries
     an Account and an actor to attribute it to.
  4. A provider crash becomes an ordinary error tuple rather than an exception
     that would abort the caller's transaction or job.

  ## Provider selection

  Selection order is context `:model_provider`, application override, then the resolved role.
  Provider failure never falls back to another provider or the deterministic adapter. Operators
  may place a failover proxy in front of a role.

  ## Content safety

  Spans and usage may contain ids, model identities, counts, durations, and error classes, never
  prompts, messages, generated or embedded text, or credentials.

  ## Failure behaviour

  Provider errors are returned, not raised, so the caller's durable job can
  retry. A provider failure leaves the raw observation and queued work intact
  and the extraction simply incomplete. Role resolution and the usage write
  still raise on their own failures — those are configuration and database
  problems, not model problems.
  """

  alias MemHouse.Model.Config
  alias MemHouse.Model.Provider.Result
  alias MemHouse.Model.ProviderCircuit
  alias MemHouse.Model.Usage
  alias MemHouse.Observability
  alias MemHouse.Operations.ExtractionBudget

  @doc """
  Performs exactly one structured-generation call — no validation, no repair.

  `schema` here is an already-built JSON schema map, not a schema module. The
  return is `{:ok, raw_object, role_config}` where `raw_object` is whatever the
  provider produced, still unvalidated; the caller is responsible for casting
  it. The resolved role is returned so a repair loop can reuse the same
  configuration and stamp provenance from it.

  Returns `{:error, reason}` on provider failure. Use
  `MemHouse.Model.StructuredGenerator` rather than this function unless you are
  implementing that loop: raw provider output must never be trusted as-is.
  When `opts[:prompt_version]` is present, a different configured version
  returns `{:error, {:prompt_version_mismatch, details}}` before the provider
  call so provenance cannot name a prompt that did not produce the request.
  """
  def structured_once(role, messages, schema, context, opts \\ []) do
    case structured_once_with_usage(role, messages, schema, context, opts) do
      {:ok, value, config, _usage} -> {:ok, value, config}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Performs one structured-generation call and returns its content-free token usage.

  This is for callers that must report their own model cost. It has the same
  validation boundary and failures as `structured_once/5`.
  """
  def structured_once_with_usage(role, messages, schema, context, opts \\ []) do
    case structured_once_with_usage_and_attempt(role, messages, schema, context, opts) do
      {:ok, value, config, usage, _provider_attempts} -> {:ok, value, config, usage}
      {:error, error, _provider_attempts} -> {:error, error}
    end
  end

  @doc """
  Performs one structured-generation admission and reports whether a provider was invoked.

  The first four success values match `structured_once_with_usage/5`, followed by
  `provider_attempts`, which is exactly `1` after the provider callback runs. Errors
  return `{:error, reason, provider_attempts}`. Prompt-version rejection and an open
  provider circuit report zero; an error returned by an admitted provider reports one.

  This is the accounting seam used by the bounded repair loop. Ordinary callers
  should use `MemHouse.Model.StructuredGenerator`, which validates provider output.
  """
  def structured_once_with_usage_and_attempt(role, messages, schema, context, opts \\ []) do
    config = Config.resolve(role, context)

    case matching_prompt_version(config, opts) do
      :ok ->
        invoke_structured_with_budget(config, messages, schema, context, opts)

      {:error, error} ->
        {:error, error, 0}
    end
  end

  defp invoke_structured_with_budget(config, messages, schema, context, opts) do
    case invoke_with_admission(
           :structured,
           config,
           context,
           opts,
           fn provider -> provider.structured(config, messages, schema, opts) end,
           fn -> reserve_extraction_budget(config.role, context, messages, schema) end
         ) do
      {:ok, %Result{value: value, usage: usage}} ->
        {:ok, value, config, usage || %{}, 1}

      {:error, %ProviderCircuit.OpenError{} = error} ->
        {:error, error, 0}

      {:error, %ExtractionBudget.Exceeded{} = error} ->
        {:error, error, 0}

      {:error, error} ->
        {:error, error, 1}
    end
  end

  defp reserve_extraction_budget(:ingest_extractor, context, messages, schema),
    do: ExtractionBudget.reserve(context, messages, schema)

  defp reserve_extraction_budget(_role, _context, _messages, _schema), do: {:ok, nil}

  defp matching_prompt_version(config, opts) do
    case Keyword.fetch(opts, :prompt_version) do
      {:ok, expected} when expected != config.prompt_version ->
        {:error,
         {:prompt_version_mismatch, %{expected: expected, configured: config.prompt_version}}}

      _match_or_unspecified ->
        :ok
    end
  end

  @doc """
  Runs one free-text completion for a role.

  Returns `{:ok, text, provenance_map}` or `{:error, reason}`. The provenance
  map is the content-safe provider/model/version stamp the caller should persist
  alongside anything derived from the text.
  """
  def chat(role, messages, context, opts \\ []) do
    config = Config.resolve(role, context)

    case invoke(:chat, config, context, opts, fn provider ->
           provider.chat(config, messages, opts)
         end) do
      {:ok, %Result{value: value}} ->
        {:ok, value, Config.provenance(config)}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Embeds texts with the Account's `:embedder` role.

  Returns `{:ok, vectors, role_config}` — the role is handed back so the caller
  can record the four-part embedding identity next to the vectors — or
  `{:error, reason}`.

  This is the low-level entry point and performs no compatibility check. Prefer
  `MemHouse.Model.Embedding.embed/3`, which refuses to mix vector spaces.
  """
  def embed(texts, context, opts \\ []) when is_list(texts) do
    config = Config.resolve(:embedder, context)
    embed_with_config(config, texts, context, opts)
  end

  @doc """
  Embeds texts against an already-resolved role, skipping role resolution.

  Exists so a caller that has already resolved the embedder — and has already
  compared its identity against stored vectors — embeds with exactly that same
  configuration, with no chance of a second resolution returning something
  different in between.
  """
  def embed_with_config(config, texts, context, opts) when is_list(texts) do
    case invoke(:embed, config, context, opts, fn provider ->
           provider.embed(config, texts, opts)
         end) do
      {:ok, %Result{value: value}} -> {:ok, value, config}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Reranks `documents` against `query` using the dedicated `:reranker` role.

  Returns `{:ok, results, provenance_map}`
  or `{:error, reason}`; the result shape is the provider's, so callers must
  tolerate a provider that cannot rerank at all and keep their existing order.
  """
  def rerank(query, documents, context, opts \\ [])
      when is_binary(query) and is_list(documents) do
    config = Config.resolve(:reranker, context)

    case invoke(:rerank, config, context, opts, fn provider ->
           provider.rerank(config, query, documents, opts)
         end) do
      {:ok, %Result{value: value}} -> {:ok, value, Config.provenance(config)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Returns the provider module that would serve a call for this role.

  Selection order is per-call context override, then application-wide override,
  then the provider named by the role. Exposed publicly so a caller can ask
  whether a real provider has been injected before deciding to trust model
  output — a deployment left on the offline deterministic provider should answer
  from retrieved statements instead of presenting invented reasoning.
  """
  def provider_module(config, context) do
    Map.get(context, :model_provider) ||
      Application.get_env(:memhouse, :model_provider) ||
      default_provider(config)
  end

  # The shared body of every capability: span, time, call, meter, return.
  #
  # Metering happens on both the success and error branches, and `opts` carries
  # the repair-attempt number, so a structured generation that needed two
  # repairs appends three usage records. Tokens spent on a failed or repaired
  # call were still spent; hiding them would make the ledger wrong.
  #
  # Only content-safe values are recorded here: role, provider, model, version,
  # operation name, duration, token counts, and an error class. No message,
  # prompt, completion, or credential may be added to either the span or the
  # usage record.
  defp invoke(operation, config, context, opts, call, timeout_ms \\ nil) do
    invoke_with_admission(
      operation,
      config,
      context,
      opts,
      call,
      fn -> {:ok, timeout_ms} end
    )
  end

  defp invoke_with_admission(operation, config, context, opts, call, admission)
       when is_function(admission, 0) do
    Observability.with_span(:model, "memhouse.model.#{operation}", fn ->
      provider = provider_module(config, context)

      Observability.set_attributes(:model, %{
        "memhouse.model.role" => Atom.to_string(config.role),
        "memhouse.model.provider" => config.provider,
        "memhouse.model.version" => config.model_version,
        "gen_ai.operation.name" => Atom.to_string(operation),
        "gen_ai.request.model" => config.model
      })

      case ProviderCircuit.checkout(config, context) do
        {:ok, permit} ->
          try do
            case admission.() do
              {:ok, timeout_ms} ->
                invoke_permitted(
                  operation,
                  config,
                  context,
                  opts,
                  call,
                  provider,
                  permit,
                  timeout_ms
                )

              {:error, error} ->
                {:error, error}
            end
          after
            :ok = ProviderCircuit.abandon(permit)
          end

        {:error, %ProviderCircuit.OpenError{} = error} ->
          Observability.set_attributes(:model, %{
            "memhouse.model.circuit_state" => "open",
            "error.type" => error_class(error)
          })

          # No provider call occurred, so this must not append a billed-call
          # UsageEvent or inflate calls-per-message economics.
          {:error, error}
      end
    end)
  end

  defp invoke_permitted(operation, config, context, opts, call, provider, permit, timeout_ms) do
    started_at = System.monotonic_time(:millisecond)
    result = safe_call(call, provider, timeout_ms)
    :ok = ProviderCircuit.complete(permit, result)
    duration_ms = System.monotonic_time(:millisecond) - started_at

    case result do
      {:ok, %Result{} = provider_result} ->
        Usage.emit(context, config, %{
          operation: operation,
          status: :ok,
          duration_ms: duration_ms,
          usage: provider_result.usage,
          metadata:
            provider_result.metadata
            |> Map.put(:repair_attempt, Keyword.get(opts, :repair_attempt, 0))
            |> Map.put(
              :metering_status,
              metering_status(provider_result.usage, operation, config.provider)
            )
        })

        set_result_attributes(provider_result, duration_ms)
        {:ok, provider_result}

      {:error, error} ->
        Usage.emit(context, config, %{
          operation: operation,
          status: :error,
          duration_ms: duration_ms,
          usage: %{},
          metadata: %{
            error_class: error_class(error),
            metering_status: :unmetered,
            repair_attempt: Keyword.get(opts, :repair_attempt, 0)
          }
        })

        Observability.set_attributes(:model, %{
          "memhouse.model.duration_ms" => duration_ms,
          "error.type" => error_class(error)
        })

        {:error, error}
    end
  end

  defp set_result_attributes(result, duration_ms) do
    usage = result.usage || %{}

    Observability.set_attributes(:model, %{
      "memhouse.model.duration_ms" => duration_ms,
      "gen_ai.usage.input_tokens" => Map.get(usage, :input_tokens, 0) || 0,
      "gen_ai.usage.output_tokens" => Map.get(usage, :output_tokens, 0) || 0,
      "memhouse.model.embedding_tokens" => Map.get(usage, :embedding_tokens, 0) || 0
    })
  end

  defp metering_status(_usage, _operation, "deterministic"), do: :complete

  defp metering_status(usage, operation, _provider) when is_map(usage) do
    required =
      if operation == :embed,
        do: [:embedding_tokens],
        else: [:input_tokens, :output_tokens]

    if Enum.all?(required, &(is_integer(Map.get(usage, &1)) and Map.get(usage, &1) >= 0)),
      do: :complete,
      else: :unmetered
  end

  defp metering_status(_usage, _operation, _provider), do: :unmetered

  # Two provider names are handled in-engine: the offline deterministic
  # stand-in, and the local ONNX embedder. Everything else — hosted APIs,
  # OpenAI-compatible endpoints, self-hosted servers — is reached through the
  # one HTTP-model adapter, which is why there is no per-vendor module here.
  defp default_provider(%{provider: "deterministic"}),
    do: MemHouse.Model.Providers.Deterministic

  defp default_provider(%{provider: "ortex"}), do: MemHouse.Model.Providers.Ortex

  defp default_provider(_config), do: MemHouse.Model.Providers.ReqLLM

  # A provider that raises must not take down the caller's transaction or job.
  # Converting the exception into an error tuple keeps the failure on the same
  # path as a returned error: metered, traced, and retryable.
  defp safe_call(call, provider, nil) do
    call.(provider)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:provider_exit, reason}}
    :throw, reason -> {:error, {:provider_throw, reason}}
  end

  defp safe_call(call, provider, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    task = Task.async(fn -> safe_call(call, provider, nil) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, %ExtractionBudget.Exceeded{reason: "wall-time cap"}}
    end
  end

  @doc """
  A short, content-free label for what went wrong.

  Transport deadline classes distinguish a configured total deadline from an
  endpoint failure without retaining an exception message, which can quote a
  prompt or response body. Everything else reduces to an exception module name
  or the error atom the adapter returned.

  Public so that a caller reporting a provider failure outside the metered call
  path — `MemHouse.Model.Probe` — names it exactly as the ledger and the span
  do, rather than inventing a second vocabulary for the same failures.
  """
  def error_class(%ReqLLM.Error.API.Request{cause: %Finch.TransportError{reason: :timeout}}),
    do: "request_timeout"

  def error_class(%ReqLLM.Error.API.Timeout{kind: :total}), do: "request_timeout"

  def error_class(%ReqLLM.Error.API.Request{}), do: "transport_error"
  def error_class(%ProviderCircuit.OpenError{}), do: "provider_circuit_open"
  def error_class(%module{}), do: inspect(module)
  def error_class(error) when is_atom(error), do: Atom.to_string(error)
  def error_class(_error), do: "model_error"
end
