# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.Providers.ReqLLM do
  @moduledoc """
  The HTTP model adapter: one module serving every hosted, self-hosted, and
  OpenAI-compatible endpoint.

  Hosted, vendor, and self-hosted OpenAI-compatible endpoints use role provider, model, and
  optional base URL; no per-vendor modules are needed.

  ## Credentials

  Role options store `"env:NAME"` references resolved at call time. Credentials are never stored,
  metered, or traced. Legacy `config :memhouse, :models, api_key:` takes precedence when set.

  ## Request options

  Only allowlisted request options are forwarded; per-call values override configuration.

  ## Failure behaviour

  Errors are returned rather than raised, and a response that is missing the
  object or text it should contain is an error too, not an empty success. The
  gateway meters the failure and the caller's job retries; nothing here
  substitutes fabricated output for a failed call.

  A call can also come back as HTTP 200 and still carry nothing usable, which
  is what an aggregator does when its own upstream failed part-way, when the
  answer was cut off at the output cap, or when the answer was withheld. Those
  are three different operator actions — wait for the retry, raise the output
  cap, change the input or the model — so each returns its own error atom
  rather than one shared "missing" name. That atom becomes the error class on
  the usage record and the span, and it is the only diagnostic an operator has
  when reading a failed run afterwards.
  """

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Config.Role
  alias MemHouse.Model.Provider.Result

  # The only role options that may become outbound request options. Anything
  # else in the options map is configuration for this adapter, not for the
  # request, and must not be forwarded. `reasoning_effort` bounds how much a
  # reasoning model spends on internal reasoning tokens before it ever emits
  # output — capping `max_tokens` alone only truncates a call after that
  # spend already happened.
  @request_option_keys ~w(
    base_url max_tokens max_retries receive_timeout temperature top_p reasoning_effort
  )a
  @req_http_option_keys ~w(pool_timeout)a

  @doc """
  Generates one schema-constrained object.

  Returns an error when the call succeeds but carries no object, because an
  empty success would be validated as malformed output anyway. Which error
  depends on how the response ended: `:provider_upstream_error`,
  `:provider_output_truncated`, `:provider_content_filtered`, or
  `:missing_structured_object` when the model simply answered without calling
  the tool it was given.
  """
  @impl true
  def structured(%Role{} = config, messages, schema, opts) do
    case ReqLLM.generate_object(
           model_spec(config),
           messages,
           schema,
           structured_request_opts(config, opts)
         ) do
      {:ok, response} ->
        case ReqLLM.Response.object(response) do
          value when is_map(value) ->
            {:ok,
             %Result{
               value: value,
               usage: usage(response.usage),
               metadata: %{response_model: response.model}
             }}

          _unusable ->
            {:error, incomplete_reason(response.finish_reason, :missing_structured_object)}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Generates free text.

  Returns an error when the call succeeds but the response carries no text,
  with the same four reasons `structured/4` uses and `:missing_text_response`
  in place of `:missing_structured_object`. Blank text counts as no text: a
  caller is about to persist or present this string, and an empty one is not
  an answer.
  """
  @impl true
  def chat(%Role{} = config, messages, opts) do
    case ReqLLM.generate_text(model_spec(config), messages, request_opts(config, opts)) do
      {:ok, response} ->
        case ReqLLM.Response.text(response) do
          value when is_binary(value) and value != "" ->
            {:ok,
             %Result{
               value: value,
               usage: usage(response.usage),
               metadata: %{response_model: response.model}
             }}

          _unusable ->
            {:error, incomplete_reason(response.finish_reason, :missing_text_response)}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  # Names why a call that returned 200 carries nothing usable. `fallback` is the
  # reason for a response that ended normally and is simply empty, which is a
  # model or prompt problem rather than a transport one.
  #
  # The split matters because the three named reasons need different responses.
  # An upstream failure, a cancellation, or a truncated stream is transient and
  # the caller's job retry is the fix. Hitting the output cap repeats
  # identically on every retry until the cap is raised. A withheld answer
  # repeats until the input or the model changes. Reporting all of them as one
  # "missing output" name hides that difference from whoever reads the trace.
  defp incomplete_reason(finish_reason, _fallback)
       when finish_reason in [:error, :cancelled, :incomplete],
       do: :provider_upstream_error

  defp incomplete_reason(:length, _fallback), do: :provider_output_truncated
  defp incomplete_reason(:content_filter, _fallback), do: :provider_content_filtered
  defp incomplete_reason(_finish_reason, fallback), do: fallback

  @doc """
  Embeds texts through an API-backed embedding endpoint.

  Two response shapes are handled because usage reporting is optional across
  endpoints: with counts, they are recorded; without, the vectors are still
  returned and the usage row simply shows zero tokens rather than a guess.
  """
  @impl true
  def embed(%Role{} = config, texts, opts) do
    req_opts = Keyword.put(request_opts(config, opts), :return_usage, true)

    case ReqLLM.embed(model_spec(config), texts, req_opts) do
      {:ok, %{embedding: vectors, usage: provider_usage}} ->
        {:ok,
         %Result{
           value: vectors,
           usage: embedding_usage(provider_usage),
           metadata: %{vector_count: length(vectors)}
         }}

      {:ok, vectors} when is_list(vectors) ->
        {:ok, %Result{value: vectors, metadata: %{vector_count: length(vectors)}}}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Reranks documents against a query, returning the endpoint's ranked results.

  The shipped OpenRouter Voyage role uses its native endpoint. General-purpose
  reasoning models do not expose that capability; deadline-free callers can
  produce the same index-and-score contract through strict structured
  generation instead.
  """
  @impl true
  def rerank(
        %Role{provider: "openrouter", model: "voyageai/rerank-2.5"} = config,
        query,
        documents,
        opts
      ) do
    request_opts = request_opts(config, opts)

    with api_key when is_binary(api_key) and api_key != "" <- Keyword.get(request_opts, :api_key),
         {:ok, response} <- openrouter_rerank_request(config, query, documents, request_opts),
         {:ok, results} <- openrouter_rerank_results(response.body, documents) do
      {:ok,
       %Result{
         value: results,
         usage: openrouter_rerank_usage(response.body),
         metadata: %{result_count: length(results)}
       }}
    else
      nil -> {:error, :missing_api_key}
      "" -> {:error, :missing_api_key}
      {:error, error} -> {:error, error}
    end
  end

  def rerank(%Role{} = config, query, documents, opts) do
    req_opts =
      config
      |> request_opts(opts)
      |> Keyword.merge(query: query, documents: documents)

    case ReqLLM.Rerank.rerank(model_spec(config), req_opts) do
      {:ok, response} ->
        {:ok,
         %Result{
           value: response.results,
           usage: response.meta |> Map.get(:usage, %{}) |> usage(),
           metadata: %{result_count: length(response.results)}
         }}

      {:error, %ReqLLM.Error.Invalid.Parameter{parameter: parameter}}
      when is_binary(parameter) ->
        if String.ends_with?(parameter, "does not support reranking operations") and
             not Keyword.get(opts, :deadline?, false) do
          rerank_with_structured_generation(config, query, documents, opts)
        else
          # Structured generation is deliberately available for offline analysis,
          # but is an expensive fallback and cannot sit inside a retrieval deadline.
          {:error, :rerank_endpoint_required_within_deadline}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp openrouter_rerank_request(config, query, documents, request_opts) do
    base_url = Map.get(config.options, "base_url") || "https://openrouter.ai/api/v1"

    http_opts =
      request_opts
      |> Keyword.get(:req_http_options, [])
      |> ReqLLM.Provider.Defaults.merge_finch_options()

    request =
      Req.new(
        [
          url: String.trim_trailing(base_url, "/") <> "/rerank",
          method: :post,
          headers: [{"authorization", "Bearer #{Keyword.fetch!(request_opts, :api_key)}"}],
          json: openrouter_rerank_body(config, query, documents),
          receive_timeout: Keyword.get(request_opts, :receive_timeout, 30_000)
        ] ++ http_opts
      )
      |> ReqLLM.Step.Retry.attach(request_opts)

    case ReqLLM.TimeoutBudget.request(request, ReqLLM.TimeoutBudget.deadline(request_opts)) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:rerank_http_status, status}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp openrouter_rerank_results(body, documents) when is_map(body) do
    case Map.get(body, "results") || Map.get(body, :results) do
      results when is_list(results) and results != [] ->
        Enum.reduce_while(results, {:ok, []}, fn result, {:ok, acc} ->
          case openrouter_rerank_result(result, documents) do
            {:ok, ranking} -> {:cont, {:ok, [ranking | acc]}}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)
        |> then(fn
          {:ok, parsed} -> validate_complete_rerank_results(Enum.reverse(parsed), documents)
          error -> error
        end)

      _invalid ->
        {:error, :invalid_rerank_response}
    end
  end

  defp openrouter_rerank_results(_body, _documents), do: {:error, :invalid_rerank_response}

  defp openrouter_rerank_result(result, documents) when is_map(result) do
    index = Map.get(result, "index") || Map.get(result, :index)
    score = Map.get(result, "relevance_score") || Map.get(result, :relevance_score)

    with true <- is_integer(index) and index >= 0 and index < length(documents),
         true <- is_number(score),
         document when is_binary(document) <- Enum.at(documents, index) do
      {:ok, %{index: index, relevance_score: score * 1.0, document: document}}
    else
      _invalid -> {:error, :invalid_rerank_response}
    end
  end

  defp openrouter_rerank_result(_result, _documents), do: {:error, :invalid_rerank_response}

  defp validate_complete_rerank_results(results, documents) do
    expected_indexes =
      case length(documents) do
        0 -> []
        count -> Enum.to_list(0..(count - 1))
      end

    indexes = results |> Enum.map(& &1.index) |> Enum.sort()

    if indexes == expected_indexes,
      do: {:ok, results},
      else: {:error, :invalid_rerank_response}
  end

  defp openrouter_rerank_usage(body) do
    total_tokens = get_in(body, ["usage", "total_tokens"]) || 0

    if is_integer(total_tokens) and total_tokens >= 0,
      do: %{input_tokens: total_tokens, output_tokens: 0},
      else: %{}
  end

  defp rerank_with_structured_generation(config, query, documents, opts) do
    messages = [
      %{
        role: "system",
        content:
          "Rank the supplied documents by relevance to the query. Return every index exactly once. Higher relevance_score means more relevant."
      },
      %{
        role: "user",
        content:
          Jason.encode!(%{
            query: query,
            documents:
              documents
              |> Enum.with_index()
              |> Enum.map(fn {document, index} -> %{index: index, document: document} end)
          })
      }
    ]

    case ReqLLM.generate_object(
           model_spec(config),
           messages,
           rerank_schema(),
           structured_request_opts(config, opts)
         ) do
      {:ok, response} ->
        rankings = response |> ReqLLM.Response.object() |> Map.get("rankings", [])

        {:ok,
         %Result{
           value: rankings,
           usage: usage(response.usage),
           metadata: %{result_count: length(rankings)}
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp rerank_schema do
    %{
      "type" => "object",
      "properties" => %{
        "rankings" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "index" => %{"type" => "integer", "minimum" => 0},
              "relevance_score" => %{"type" => "number"}
            },
            "required" => ["index", "relevance_score"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["rankings"],
      "additionalProperties" => false
    }
  end

  # An OpenAI-compatible endpoint is addressed as the OpenAI provider plus an
  # explicit base URL, which is how a self-hosted or proxied server is reached
  # without needing its own adapter. The nil base URL is dropped rather than
  # passed, so the library's own default applies when none is configured.
  defp model_spec(%Role{provider: provider, model: model, options: options})
       when provider in ["openai", "openai-compatible"] do
    %{
      provider: :openai,
      id: model,
      base_url: Map.get(options, "base_url")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> ReqLLM.model!()
  end

  # Every other provider is named directly, so adding support for one that the
  # underlying library already knows needs no code change here.
  defp model_spec(%Role{provider: provider, model: model}) do
    "#{provider}:#{model}"
  end

  # Builds the outbound request options: allowlisted configured values, then the
  # resolved credential, then per-call overrides last so a caller's explicit
  # timeout or temperature wins over the stored default. ReqLLM validates its
  # generation options before a request is built. The public
  # `request_timeout` role option maps to ReqLLM's `total_timeout`, which owns
  # the complete call budget, including transport retries.
  defp request_opts(%Role{options: options} = config, overrides) do
    configured =
      @request_option_keys
      |> Enum.reduce([], fn key, acc ->
        case Map.get(options, Atom.to_string(key)) do
          nil -> acc
          value -> [{key, normalize_option_value(key, value)} | acc]
        end
      end)

    req_http_options =
      @req_http_option_keys
      |> Enum.reduce([], fn key, acc ->
        value = Keyword.get(overrides, key, Map.get(options, Atom.to_string(key)))
        if is_nil(value), do: acc, else: [{key, value} | acc]
      end)

    total_timeout =
      Keyword.get(overrides, :request_timeout, Map.get(options, "request_timeout"))

    configured
    |> maybe_put(:api_key, resolve_api_key(options))
    |> Keyword.merge(Keyword.take(overrides, @request_option_keys))
    |> maybe_put(:total_timeout, total_timeout)
    |> maybe_put(:req_http_options, req_http_options)
    |> maybe_put(:provider_options, openrouter_provider_options(config))
  end

  # A campaign route is an actual wire constraint, not provenance decoration.
  # `only` plus disabled fallbacks prevents OpenRouter from silently selecting
  # a different upstream when the approved route is unavailable.
  defp openrouter_provider_options(%Role{provider: "openrouter"} = config) do
    case Map.get(config.options, "upstream_route") do
      route when is_binary(route) and route != "" ->
        [openrouter_provider: openrouter_provider(config)]

      _absent ->
        nil
    end
  end

  defp openrouter_provider_options(_config), do: nil

  defp openrouter_provider(%Role{} = config) do
    case Map.get(config.options, "upstream_route") do
      route when is_binary(route) and route != "" ->
        %{only: [route], allow_fallbacks: false}

      _absent ->
        nil
    end
  end

  defp openrouter_rerank_body(config, query, documents) do
    body = %{
      model: config.model,
      query: query,
      documents: documents,
      top_n: length(documents)
    }

    case openrouter_provider(config) do
      nil -> body
      provider -> Map.put(body, :provider, provider)
    end
  end

  # OpenRouter's forced synthetic tool is not reliable for gpt-oss models: it
  # may finish after reasoning without making the required call. Its native
  # JSON-schema response path returns the same object while avoiding that
  # model-level failure mode. This is limited to structured generation; chat
  # continues to use normal tool calling where callers explicitly need tools.
  #
  # The mode is merged into any provider options the caller supplied rather than
  # replacing them, so a caller asking for an unrelated provider feature does
  # not silently lose the schema-enforced response path with it.
  defp structured_request_opts(%Role{} = config, overrides) do
    opts = request_opts(config, overrides)

    case structured_output_mode(config) do
      nil -> opts
      {key, mode} -> put_structured_output_mode(opts, key, mode)
    end
  end

  # The two adapters read the mode from different places: OpenRouter's from the
  # nested provider options, OpenAI's from the top level. Putting it in the
  # wrong one is not an error — it is ignored, and the call silently reverts to
  # the forced tool call. The wire-level tests are what hold each placement.
  defp put_structured_output_mode(opts, :openrouter_structured_output_mode = key, mode) do
    Keyword.update(opts, :provider_options, [{key, mode}], &Keyword.put(&1, key, mode))
  end

  defp put_structured_output_mode(opts, key, mode), do: Keyword.put(opts, key, mode)

  # `json_schema` is the default only for a role naming OpenRouter directly.
  # The same endpoint is also reachable as `openai-compatible` plus a base URL,
  # and there the underlying library decides the mode from its model database,
  # which does not recognise an OpenRouter model id and falls back to the
  # unreliable forced tool call. A role in that shape must set
  # `structured_output_mode` itself; `MemHouse.Model.Probe` is what shows an
  # operator that it was needed.
  defp structured_output_mode(%Role{provider: provider, options: options}) do
    case Map.get(options, "structured_output_mode", default_structured_output_mode(provider)) do
      nil ->
        nil

      "json_schema" ->
        {structured_output_mode_key(provider), :json_schema}

      other ->
        # A typo must not degrade silently into forced tool calling, which is
        # the exact failure this option exists to prevent.
        raise ArgumentError,
              "structured_output_mode must be \"json_schema\" or absent, got: #{inspect(other)}"
    end
  end

  defp default_structured_output_mode("openrouter"), do: "json_schema"
  defp default_structured_output_mode(_provider), do: nil

  defp structured_output_mode_key("openrouter"), do: :openrouter_structured_output_mode

  defp structured_output_mode_key(provider) when provider in ["openai", "openai-compatible"],
    do: :openai_structured_output_mode

  defp structured_output_mode_key(provider) do
    raise ArgumentError,
          "structured_output_mode is not supported for provider #{inspect(provider)}"
  end

  # Role options are always string-valued so they stay printable/exportable
  # regardless of source (see `MemHouse.Model.Config.Role`), but req_llm's
  # NimbleOptions schema validates `reasoning_effort` against a fixed atom
  # enum and rejects a string outright — every provider request would fail
  # this validation before making any call. Only some of req_llm's own
  # provider adapters (e.g. its OpenAI adapter, but not OpenRouter) tolerate a
  # string here, so the conversion must happen for every provider, not rely on
  # the adapter reached.
  defp normalize_option_value(:reasoning_effort, value) when is_binary(value) do
    String.to_existing_atom(value)
  end

  defp normalize_option_value(_key, value), do: value

  # Reads the credential at call time from the environment variable that the
  # role's `api_key_ref` names. Only the reference is ever persisted; the key
  # itself lives in the process environment and exists in memory only for the
  # duration of the request. A reference in any other form yields no key, so a
  # value accidentally pasted in place of a reference is not used as one.
  #
  # The application-level `:models` entry is the older single-key configuration
  # and still wins when set, so an existing deployment keeps working after roles
  # were introduced.
  defp resolve_api_key(options) do
    legacy = Application.get_env(:memhouse, :models, [])

    Keyword.get(legacy, :api_key) ||
      case Map.get(options, "api_key_ref") || Keyword.get(legacy, :api_key_ref) do
        "env:" <> variable -> System.get_env(variable)
        _other -> nil
      end
  end

  # A missing or blank credential is omitted entirely rather than sent as an
  # empty string, so an unauthenticated local endpoint works and a
  # misconfigured hosted one fails with a clear authentication error.
  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, _key, ""), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp usage(value), do: ReqLLM.Usage.normalize(value || %{})

  # Embedding endpoints report their consumption as input tokens. Recording it
  # separately as embedding tokens keeps the ledger able to distinguish cheap
  # bulk embedding from generation spend, and output tokens are forced to zero
  # because an embedding produces none.
  defp embedding_usage(value) do
    normalized = usage(value)

    normalized
    |> Map.put(:embedding_tokens, Map.get(normalized, :input_tokens, 0) || 0)
    |> Map.put(:output_tokens, 0)
  end
end
