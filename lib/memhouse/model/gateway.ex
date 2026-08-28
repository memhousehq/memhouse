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

  alias MemHouse.Model.CampaignAdmission
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
    bounds = request_bounds(:structured, config, %{messages: messages, schema: schema}, opts)

    case invoke_with_admission(
           :structured,
           config,
           context,
           opts,
           fn provider -> provider.structured(config, messages, schema, opts) end,
           fn -> reserve_extraction_budget(config.role, context, messages, schema, opts) end,
           bounds
         ) do
      {:ok, %Result{value: value, usage: usage}} ->
        {:ok, value, config, usage || %{}, 1}

      {:error, %ProviderCircuit.OpenError{} = error} ->
        {:error, error, 0}

      {:error, %ExtractionBudget.Exceeded{reason: "wall-time cap"} = error} ->
        {:error, error, 1}

      {:error, %ExtractionBudget.Exceeded{} = error} ->
        {:error, error, 0}

      {:error, %CampaignAdmission.Refused{} = error} ->
        {:error, error, 0}

      {:error, :unauthorized} ->
        {:error, :unauthorized, 0}

      {:error, error} ->
        {:error, error, 1}
    end
  end

  @budgeted_extraction_tasks [
    :extraction,
    :extraction_batch,
    :compact_extraction,
    :compact_extraction_batch
  ]

  defp reserve_extraction_budget(:ingest_extractor, context, messages, schema, opts) do
    if Keyword.get(opts, :task) in @budgeted_extraction_tasks and
         Map.get(context, :budgeted_extraction?, true) do
      ExtractionBudget.reserve(context, messages, schema)
    else
      {:ok, nil}
    end
  end

  defp reserve_extraction_budget(_role, _context, _messages, _schema, _opts), do: {:ok, nil}

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

    case invoke(
           :chat,
           config,
           context,
           opts,
           fn provider ->
             provider.chat(config, messages, opts)
           end,
           messages
         ) do
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
    case invoke(
           :embed,
           config,
           context,
           opts,
           fn provider ->
             provider.embed(config, texts, opts)
           end,
           texts
         ) do
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

    case invoke(
           :rerank,
           config,
           context,
           opts,
           fn provider ->
             provider.rerank(config, query, documents, opts)
           end,
           %{query: query, documents: documents}
         ) do
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
  defp invoke(operation, config, context, opts, call, request_material, timeout_ms \\ nil) do
    invoke_with_admission(
      operation,
      config,
      context,
      opts,
      call,
      fn -> {:ok, timeout_ms} end,
      request_bounds(operation, config, request_material, opts)
    )
  end

  defp invoke_with_admission(operation, config, context, opts, call, admission, bounds)
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
                with {:ok, reservation} <-
                       CampaignAdmission.reserve(
                         config,
                         operation,
                         bounds.input_tokens,
                         bounds.output_tokens,
                         provider,
                         opts
                       ) do
                  invoke_permitted(
                    operation,
                    config,
                    context,
                    opts,
                    call,
                    provider,
                    permit,
                    {reservation, campaign_timeout(timeout_ms, reservation)}
                  )
                end

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

  defp invoke_permitted(
         operation,
         config,
         context,
         opts,
         call,
         provider,
         permit,
         {reservation, timeout_ms}
       ) do
    started_at = System.monotonic_time(:millisecond)
    result = accounted_safe_call(call, provider, timeout_ms, reservation)
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

  defp campaign_timeout(timeout_ms, %{remaining_wall_ms: remaining})
       when is_integer(remaining) and remaining > 0 do
    if is_integer(timeout_ms), do: min(timeout_ms, remaining), else: remaining
  end

  defp campaign_timeout(timeout_ms, _inactive_or_local), do: timeout_ms

  # This uses the same target-revision-pinned `utf8-bytes-v1` convention as
  # extraction admission: the canonical JSON byte size deliberately
  # over-counts ordinary BPE tokens without needing a routed provider's
  # tokenizer or exposing the content to the campaign process.
  defp request_bounds(operation, config, material, opts) do
    input_tokens =
      Jason.encode!(%{
        operation: operation,
        provider: config.provider,
        model: config.model,
        material: material
      })
      |> byte_size()

    output_tokens =
      if operation in [:structured, :chat] do
        Keyword.get(opts, :max_tokens, Map.get(config.options, "max_tokens", -1))
      else
        0
      end

    %{input_tokens: input_tokens, output_tokens: output_tokens}
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
  defp safe_call(call, provider, nil) do
    call.(provider)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:provider_exit, reason}}
    :throw, reason -> {:error, {:provider_throw, reason}}
  end

  defp safe_call(call, provider, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.Supervisor.async_nolink(
        MemHouse.Model.ProviderTaskSupervisor,
        fn -> safe_call(call, provider, nil) end
      )

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:provider_exit, reason}}
      nil -> {:error, %ExtractionBudget.Exceeded{reason: "wall-time cap"}}
    end
  end

  defp accounted_safe_call(call, provider, timeout_ms, reservation)
       when reservation in [:inactive, :local] do
    :ok = CampaignAdmission.dispatch(reservation)
    result = safe_call(call, provider, timeout_ms)
    :ok = CampaignAdmission.complete(reservation, result)
    result
  end

  defp accounted_safe_call(call, provider, nil, reservation) do
    :ok = CampaignAdmission.dispatch(reservation)
    result = safe_call(call, provider, nil)
    :ok = CampaignAdmission.complete(reservation, result)
    result
  end

  defp accounted_safe_call(call, provider, timeout_ms, reservation)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    owner = self()
    admission = Process.whereis(CampaignAdmission)
    result_ref = make_ref()

    {lifecycle, lifecycle_ref} =
      spawn_monitor(fn ->
        provider_lifecycle_guard(owner, admission, result_ref, call, provider)
      end)

    provider_task = await_provider_task(lifecycle, lifecycle_ref, result_ref)
    provider_ref = Process.monitor(provider_task)
    :ok = CampaignAdmission.dispatch(reservation, lifecycle)
    send(provider_task, :campaign_provider_dispatch)

    result =
      receive do
        {:campaign_provider_result, ^result_ref, result} ->
          result

        {:DOWN, ^provider_ref, :process, ^provider_task, reason} ->
          {:error, {:provider_exit, reason}}
      after
        timeout_ms ->
          stop_provider_task(provider_task, provider_ref, false)
          flush_provider_result(result_ref)
          {:error, %ExtractionBudget.Exceeded{reason: "wall-time cap"}}
      end

    :ok = CampaignAdmission.complete(reservation, result)
    send(lifecycle, :complete)
    Process.demonitor(lifecycle_ref, [:flush])
    Process.demonitor(provider_ref, [:flush])
    result
  end

  defp await_provider_task(lifecycle, lifecycle_ref, result_ref) do
    receive do
      {:campaign_provider_ready, ^result_ref, ^lifecycle, provider_task} ->
        provider_task

      {:DOWN, ^lifecycle_ref, :process, ^lifecycle, reason} ->
        exit({:provider_lifecycle_start_failed, reason})
    end
  end

  defp provider_lifecycle_guard(owner, admission, result_ref, call, provider) do
    owner_ref = Process.monitor(owner)
    admission_ref = if is_pid(admission), do: Process.monitor(admission)

    {:ok, provider_task} =
      Task.Supervisor.start_child(MemHouse.Model.CampaignProviderTaskSupervisor, fn ->
        receive do
          :campaign_provider_dispatch ->
            send(owner, {:campaign_provider_result, result_ref, safe_call(call, provider, nil)})
        end
      end)

    task_ref = Process.monitor(provider_task)
    send(owner, {:campaign_provider_ready, result_ref, self(), provider_task})
    provider_lifecycle_loop(owner_ref, task_ref, admission_ref, provider_task, false)
  end

  defp provider_lifecycle_loop(owner_ref, task_ref, admission_ref, provider_task, task_down?) do
    receive do
      :complete ->
        :ok

      {:DOWN, ^task_ref, :process, ^provider_task, _reason} ->
        provider_lifecycle_loop(owner_ref, task_ref, admission_ref, provider_task, true)

      {:DOWN, ^owner_ref, :process, _owner, _reason} ->
        stop_provider_task(provider_task, task_ref, task_down?)

      {:DOWN, ^admission_ref, :process, _admission, _reason} ->
        stop_provider_task(provider_task, task_ref, task_down?)
    end
  end

  defp stop_provider_task(_provider_task, _task_ref, true), do: :ok

  defp stop_provider_task(provider_task, task_ref, false) do
    Process.exit(provider_task, :kill)

    receive do
      {:DOWN, ^task_ref, :process, ^provider_task, _reason} -> :ok
    end
  end

  defp flush_provider_result(result_ref) do
    receive do
      {:campaign_provider_result, ^result_ref, _result} -> :ok
    after
      0 -> :ok
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

  def error_class(%CampaignAdmission.Refused{reason: reason}),
    do: "campaign_admission_#{reason}"

  def error_class(%module{}), do: inspect(module)
  def error_class(error) when is_atom(error), do: Atom.to_string(error)
  def error_class(_error), do: "model_error"
end
