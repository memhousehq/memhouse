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
  alias MemHouse.Model.Usage
  alias MemHouse.Observability

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
  """
  def structured_once(role, messages, schema, context, opts \\ []) do
    config = Config.resolve(role, context)

    case invoke(:structured, config, context, opts, fn provider ->
           provider.structured(config, messages, schema, opts)
         end) do
      {:ok, %Result{value: value}} -> {:ok, value, config}
      {:error, error} -> {:error, error}
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
  defp invoke(operation, config, context, opts, call) do
    Observability.with_span(:model, "memhouse.model.#{operation}", fn ->
      provider = provider_module(config, context)
      started_at = System.monotonic_time(:millisecond)

      Observability.set_attributes(:model, %{
        "memhouse.model.role" => Atom.to_string(config.role),
        "memhouse.model.provider" => config.provider,
        "memhouse.model.version" => config.model_version,
        "gen_ai.operation.name" => Atom.to_string(operation),
        "gen_ai.request.model" => config.model
      })

      result = safe_call(call, provider)
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
    end)
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
  defp safe_call(call, provider) do
    call.(provider)
  rescue
    error -> {:error, error}
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

  def error_class(%ReqLLM.Error.API.Request{}), do: "transport_error"
  def error_class(%module{}), do: inspect(module)
  def error_class(error) when is_atom(error), do: Atom.to_string(error)
  def error_class(_error), do: "model_error"
end
