# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.CampaignAdmission do
  @moduledoc """
  Node-wide pre-spend admission for an explicitly approved model campaign.

  Normal production requests are unchanged while no campaign is active. An
  active campaign binds every hosted provider call on the node to one exact
  admission-file digest, target revision, route, role, and set of hard caps.
  Reservations are atomic and permanent: a provider failure can still incur a
  charge, so a failed attempt never returns budget to the campaign.

  Admission files contain only model identities, routing, aggregate limits,
  and approval state. This process never receives prompts, answers,
  credentials, or Account content.
  """

  use GenServer

  alias MemHouse.Model.Config.Role

  @paid_roles ~w(
    target.ingest_extractor
    target.dialectic_agent
    target.dream_reasoner
    target.reranker
    harness.answerer
    harness.judge
  )
  @local_providers ~w(deterministic ortex)
  @full_sha ~r/\A[0-9a-f]{40}\z/
  @digest ~r/\A[0-9a-f]{64}\z/

  defmodule Refused do
    @moduledoc "A content-free campaign admission rejection."
    defexception [:reason]

    @impl true
    def message(error), do: "campaign admission refused: #{error.reason}"
  end

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Activates one immutable admission packet.

  `expected_sha256` is supplied outside the packet. A changed, missing, or
  malformed file fails before any campaign can become active.
  """
  def activate(path, expected_sha256, opts) when is_binary(path) and is_binary(expected_sha256) do
    GenServer.call(__MODULE__, {:activate, path, expected_sha256, opts})
  end

  @doc "Returns content-free active identity, cap, and reservation state."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Atomically reserves one worst-case paid provider attempt.

  Input and output values are upper bounds calculated before the provider
  callback. The return is `{:ok, :inactive}` outside a campaign,
  `{:ok, reservation}` when admitted, or `{:error, %Refused{}}` before spend.
  """
  def reserve(%Role{} = config, operation, input_tokens, output_tokens, opts \\ []) do
    identity = Keyword.get(opts, :campaign_identity)
    campaign_role = Keyword.get(opts, :campaign_role)
    now_ms = Keyword.get(opts, :campaign_now_ms, System.monotonic_time(:millisecond))

    GenServer.call(
      __MODULE__,
      {:reserve, config, operation, input_tokens, output_tokens, identity, campaign_role, now_ms}
    )
  end

  @impl true
  def init(opts) do
    state = %{active: nil}
    activation = Keyword.get(opts, :activate, Application.get_env(:memhouse, :campaign_admission))

    case activation do
      nil -> {:ok, state}
      {path, digest, activate_opts} -> activate_state(state, path, digest, activate_opts)
    end
  end

  @impl true
  def handle_call({:activate, path, digest, opts}, _from, %{active: nil} = state) do
    case load(path, digest, opts) do
      {:ok, active} -> {:reply, {:ok, active.identity}, %{state | active: active}}
      {:error, reason} -> {:reply, {:error, %Refused{reason: reason}}, state}
    end
  end

  def handle_call({:activate, _path, _digest, _opts}, _from, state) do
    {:reply, {:error, %Refused{reason: :campaign_already_active}}, state}
  end

  def handle_call(:status, _from, %{active: nil} = state), do: {:reply, %{active?: false}, state}

  def handle_call(:status, _from, %{active: active} = state) do
    reply = %{
      active?: true,
      identity: active.identity,
      definition_id: active.definition_id,
      arm: active.arm,
      target_revision: active.target_revision,
      reserved: active.reserved,
      hard_caps: active.hard_caps,
      role_reserved: active.role_reserved
    }

    {:reply, reply, state}
  end

  def handle_call(
        {:reserve, _config, _operation, _input, _output, nil, _role, _now},
        _from,
        %{active: nil} = state
      ) do
    {:reply, {:ok, :inactive}, state}
  end

  def handle_call(
        {:reserve, _config, _operation, _input, _output, _identity, _role, _now},
        _from,
        %{active: nil} = state
      ) do
    {:reply, refused(:missing_admission), state}
  end

  def handle_call({:reserve, config, operation, input, output, identity, role, now}, _from, state) do
    case reserve_active(state.active, config, operation, input, output, identity, role, now) do
      {:ok, reservation, active} ->
        {:reply, {:ok, reservation}, %{state | active: active}}

      {:error, reason} ->
        {:reply, refused(reason), state}
    end
  end

  defp activate_state(state, path, digest, opts) do
    case load(path, digest, opts) do
      {:ok, active} -> {:ok, %{state | active: active}}
      {:error, reason} -> {:stop, %Refused{reason: reason}}
    end
  end

  defp load(path, expected_digest, opts) do
    with :ok <- valid_digest(expected_digest),
         {:ok, bytes} <- read_packet(path),
         :ok <- exact_digest(bytes, expected_digest),
         {:ok, packet} <- decode_packet(bytes),
         {:ok, target_revision} <- target_revision(opts) do
      validate_packet(packet, expected_digest, target_revision, opts)
    end
  end

  defp valid_digest(digest) do
    if Regex.match?(@digest, digest), do: :ok, else: {:error, :invalid_admission_digest}
  end

  # Operator-only startup configuration deliberately selects this file. The
  # separately supplied digest authenticates its exact bytes before use; no
  # request input contributes to the path.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_packet(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> {:error, :missing_admission}
    end
  end

  defp exact_digest(bytes, expected) do
    actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    if actual == expected, do: :ok, else: {:error, :dirty_admission}
  end

  defp decode_packet(bytes) do
    case Jason.decode(bytes) do
      {:ok, packet} when is_map(packet) -> {:ok, packet}
      _invalid -> {:error, :invalid_admission}
    end
  end

  defp target_revision(opts) do
    revision = Keyword.get(opts, :target_revision)
    actual = Keyword.get(opts, :actual_revision, Application.get_env(:memhouse, :build_sha))

    cond do
      not is_binary(revision) ->
        {:error, :missing_target_revision}

      not Regex.match?(@full_sha, revision) ->
        {:error, :invalid_target_revision}

      not is_binary(actual) or not Regex.match?(@full_sha, actual) ->
        {:error, :unknown_build_revision}

      actual != revision ->
        {:error, :target_revision_mismatch}

      true ->
        {:ok, revision}
    end
  end

  defp validate_packet(packet, digest, target_revision, opts) do
    with :ok <- approved_packet(packet),
         {:ok, definition_id} <- definition_id(packet, opts),
         :ok <- matching_target_revision(packet, target_revision),
         {:ok, arm} <- campaign_arm(packet, opts),
         {:ok, routing} <- routing(packet),
         {:ok, models} <- models(packet),
         {:ok, pricing} <- pricing(packet, models),
         {:ok, roles} <- roles(packet, models, pricing),
         {:ok, hard_caps} <- hard_caps(packet, roles),
         {:ok, wall_seconds} <- positive_integer(hard_caps.wall_seconds, :invalid_wall_ceiling) do
      now_ms = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))

      {:ok,
       %{
         identity: "#{definition_id}:#{digest}",
         definition_id: definition_id,
         arm: arm,
         target_revision: target_revision,
         routing: routing,
         models: models,
         roles: roles,
         hard_caps: Map.delete(hard_caps, :wall_seconds),
         deadline_ms: now_ms + wall_seconds * 1_000,
         reserved: empty_usage(),
         role_reserved: Map.new(@paid_roles, &{&1, empty_usage()})
       }}
    end
  end

  defp approved_packet(packet) do
    if packet["schema_version"] == "membench-campaign-admission-1" and
         packet["admitted"] == true and packet["provider_calls_permitted"] == true and
         packet["blockers"] == [] do
      :ok
    else
      {:error, :unapproved_admission}
    end
  end

  defp definition_id(packet, opts) do
    value = packet["definition_id"]
    expected = Keyword.get(opts, :definition_id)

    cond do
      not is_binary(value) or value == "" -> {:error, :invalid_campaign_identity}
      is_binary(expected) and expected != value -> {:error, :campaign_identity_mismatch}
      true -> {:ok, value}
    end
  end

  defp matching_target_revision(packet, target_revision) do
    arms = packet["arms"]

    if is_list(arms) and arms != [] and
         Enum.all?(arms, &(is_map(&1) and &1["target_ref"] == target_revision)) do
      :ok
    else
      {:error, :target_revision_mismatch}
    end
  end

  defp campaign_arm(packet, opts) do
    arms = packet["arms"]
    requested_id = Keyword.get(opts, :arm_id)

    selected =
      case {requested_id, arms} do
        {nil, [only]} ->
          only

        {id, values} when is_binary(id) and is_list(values) ->
          Enum.find(values, &(&1["id"] == id))

        _other ->
          nil
      end

    batching =
      Keyword.get_lazy(opts, :batching, fn ->
        :memhouse
        |> Application.get_env(:extraction_batching, [])
        |> Keyword.get(:enabled, false)
      end)

    case selected do
      %{
        "id" => id,
        "prompt_version" => prompt,
        "batching" => ^batching,
        "runtime_prompt_available" => true
      }
      when is_binary(id) and id != "" and is_binary(prompt) and prompt != "" ->
        {:ok, %{id: id, prompt_version: prompt, batching: batching}}

      _invalid ->
        {:error, :campaign_arm_mismatch}
    end
  end

  defp routing(packet) do
    case packet["execution"] do
      %{
        "provider" => "openrouter",
        "endpoint" => endpoint,
        "upstream_route" => route
      }
      when is_binary(endpoint) and endpoint != "" and is_binary(route) and route != "" ->
        {:ok, %{provider: "openrouter", endpoint: endpoint, upstream_route: route}}

      _invalid ->
        {:error, :unpriceable_routing}
    end
  end

  defp models(packet) do
    case packet["models"] do
      %{"answerer" => answerer, "judge" => judge, "reranker" => reranker}
      when is_binary(answerer) and answerer != "" and is_binary(judge) and judge != "" and
             is_binary(reranker) and reranker != "" ->
        {:ok, %{answerer: answerer, judge: judge, reranker: reranker}}

      _invalid ->
        {:error, :unpriceable_models}
    end
  end

  defp pricing(packet, models) do
    required_models = models |> Map.values() |> Enum.uniq()

    Enum.reduce_while(required_models, {:ok, %{}}, fn model, {:ok, acc} ->
      case get_in(packet, ["pricing_usd_per_million", model]) do
        %{"input" => input, "output" => output} ->
          with {:ok, input_rate} <- non_negative_micros(input),
               {:ok, output_rate} <- non_negative_micros(output) do
            {:cont, {:ok, Map.put(acc, model, %{input: input_rate, output: output_rate})}}
          else
            _invalid -> {:halt, {:error, :unpriceable_models}}
          end

        _missing ->
          {:halt, {:error, :unpriceable_models}}
      end
    end)
  end

  defp roles(packet, models, pricing) do
    raw = packet["paid_roles"]

    if is_map(raw) and Map.keys(raw) |> Enum.sort() == Enum.sort(@paid_roles) do
      Enum.reduce_while(@paid_roles, {:ok, %{}}, fn role, {:ok, acc} ->
        model = model_for_role(role, models)

        with {:ok, caps} <- role_caps(raw[role]),
             :ok <- cap_prices_tokens(caps, pricing[model]) do
          configured = caps |> Map.put(:model, model) |> Map.put(:rates, pricing[model])
          {:cont, {:ok, Map.put(acc, role, configured)}}
        else
          _invalid -> {:halt, {:error, :unpriceable_roles}}
        end
      end)
    else
      {:error, :unknown_paid_roles}
    end
  end

  defp role_caps(%{
         "requests" => requests,
         "input_tokens" => input,
         "output_tokens" => output,
         "usd" => usd
       }) do
    with {:ok, requests} <- non_negative_integer(requests),
         {:ok, input} <- non_negative_integer(input),
         {:ok, output} <- non_negative_integer(output),
         {:ok, usd_micros} <- non_negative_usd_micros(usd) do
      {:ok,
       %{requests: requests, input_tokens: input, output_tokens: output, usd_micros: usd_micros}}
    end
  end

  defp role_caps(_invalid), do: {:error, :invalid_role_caps}

  defp cap_prices_tokens(caps, rates) do
    required = cost_micros(caps.input_tokens, caps.output_tokens, rates)

    if caps.usd_micros >= required,
      do: :ok,
      else: {:error, :usd_cap_below_token_ceiling}
  end

  defp hard_caps(packet, roles) do
    caps = get_in(packet, ["volume", "hard_caps"])

    with %{} <- caps,
         {:ok, requests} <- non_negative_integer(caps["paid_requests"]),
         {:ok, input} <- non_negative_integer(caps["input_tokens"]),
         {:ok, output} <- non_negative_integer(caps["output_tokens"]),
         {:ok, reranker_input} <- non_negative_integer(caps["reranker_input_tokens"]),
         {:ok, usd_micros} <- non_negative_usd_micros(caps["usd"]),
         {:ok, wall_seconds} <- non_negative_integer(caps["wall_seconds"]),
         :ok <- exact_hard_caps(roles, requests, input, output, reranker_input, usd_micros) do
      {:ok,
       %{
         requests: requests,
         input_tokens: input,
         output_tokens: output,
         reranker_input_tokens: reranker_input,
         usd_micros: usd_micros,
         wall_seconds: wall_seconds
       }}
    else
      _invalid -> {:error, :invalid_hard_caps}
    end
  end

  defp exact_hard_caps(roles, requests, input, output, reranker_input, usd) do
    sums =
      Enum.reduce(roles, empty_usage(), fn {role, cap}, acc ->
        acc
        |> Map.update!(:requests, &(&1 + cap.requests))
        |> Map.update!(:input_tokens, &(&1 + cap.input_tokens))
        |> Map.update!(:output_tokens, &(&1 + cap.output_tokens))
        |> Map.update!(:usd_micros, &(&1 + cap.usd_micros))
        |> Map.update!(:reranker_input_tokens, fn value ->
          if role == "target.reranker", do: value + cap.input_tokens, else: value
        end)
      end)

    if sums == %{
         requests: requests,
         input_tokens: input,
         output_tokens: output,
         reranker_input_tokens: reranker_input,
         usd_micros: usd
       },
       do: :ok,
       else: {:error, :hard_cap_mismatch}
  end

  defp reserve_active(
         active,
         %Role{provider: provider},
         _operation,
         _input,
         _output,
         identity,
         _role,
         _now
       )
       when provider in @local_providers do
    case matching_identity(active, identity) do
      :ok -> {:ok, :local, active}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reserve_active(active, config, operation, input, output, identity, role, now) do
    with :ok <- matching_identity(active, identity),
         {:ok, paid_role} <- paid_role(config, operation, role),
         :ok <- matching_route(active, config, paid_role),
         {:ok, input} <- non_negative_integer(input),
         {:ok, output} <- non_negative_integer(output),
         :ok <- before_deadline(active, now),
         {:ok, charge} <- charge(active, paid_role, input, output),
         :ok <- within_caps(active, paid_role, charge) do
      {:ok, reservation(paid_role, charge), apply_charge(active, paid_role, charge)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp matching_identity(_active, nil), do: :ok
  defp matching_identity(%{identity: identity}, identity), do: :ok
  defp matching_identity(_active, _other), do: {:error, :campaign_identity_mismatch}

  defp paid_role(%Role{role: config_role}, _operation, requested) when is_binary(requested) do
    if requested in allowed_paid_roles(config_role),
      do: {:ok, requested},
      else: {:error, :unknown_paid_role}
  end

  defp paid_role(%Role{role: :ingest_extractor}, :structured, nil),
    do: {:ok, "target.ingest_extractor"}

  defp paid_role(%Role{role: :dream_reasoner}, :structured, nil),
    do: {:ok, "target.dream_reasoner"}

  defp paid_role(%Role{role: :dialectic_agent}, operation, nil)
       when operation in [:structured, :chat],
       do: {:ok, "target.dialectic_agent"}

  defp paid_role(%Role{role: :reranker}, :rerank, nil), do: {:ok, "target.reranker"}
  defp paid_role(_config, _operation, _requested), do: {:error, :unknown_paid_role}

  defp allowed_paid_roles(:ingest_extractor), do: ["target.ingest_extractor"]
  defp allowed_paid_roles(:dream_reasoner), do: ["target.dream_reasoner", "harness.judge"]

  defp allowed_paid_roles(:dialectic_agent),
    do: ["target.dialectic_agent", "harness.answerer"]

  defp allowed_paid_roles(:reranker), do: ["target.reranker"]
  defp allowed_paid_roles(_role), do: []

  defp matching_route(active, config, role) do
    expected_model = active.roles[role].model

    prompt_matches? =
      role != "target.ingest_extractor" or config.prompt_version == active.arm.prompt_version

    batching_matches? =
      role != "target.ingest_extractor" or current_batching() == active.arm.batching

    if config.provider == active.routing.provider and config.model == expected_model and
         Map.get(config.options, "base_url") == active.routing.endpoint and
         Map.get(config.options, "upstream_route") == active.routing.upstream_route and
         prompt_matches? and batching_matches? do
      :ok
    else
      {:error, :routing_mismatch}
    end
  end

  defp current_batching do
    :memhouse
    |> Application.get_env(:extraction_batching, [])
    |> Keyword.get(:enabled, false)
  end

  defp before_deadline(%{deadline_ms: deadline}, now) when is_integer(now) and now < deadline,
    do: :ok

  defp before_deadline(_active, _now), do: {:error, :wall_ceiling}

  defp charge(active, role, input, output) do
    pricing = active.roles[role].rates

    charge = %{
      requests: 1,
      input_tokens: input,
      output_tokens: output,
      reranker_input_tokens: if(role == "target.reranker", do: input, else: 0),
      usd_micros: cost_micros(input, output, pricing)
    }

    {:ok, charge}
  end

  defp within_caps(active, role, charge) do
    role_caps = active.roles[role]
    role_used = active.role_reserved[role]

    cond do
      role_used.requests + charge.requests > role_caps.requests or
          active.reserved.requests + charge.requests > active.hard_caps.requests ->
        {:error, :request_ceiling}

      role_used.input_tokens + charge.input_tokens > role_caps.input_tokens or
          active.reserved.input_tokens + charge.input_tokens > active.hard_caps.input_tokens ->
        {:error, :input_token_ceiling}

      role_used.output_tokens + charge.output_tokens > role_caps.output_tokens or
          active.reserved.output_tokens + charge.output_tokens > active.hard_caps.output_tokens ->
        {:error, :output_token_ceiling}

      active.reserved.reranker_input_tokens + charge.reranker_input_tokens >
          active.hard_caps.reranker_input_tokens ->
        {:error, :reranker_token_ceiling}

      role_used.usd_micros + charge.usd_micros > role_caps.usd_micros or
          active.reserved.usd_micros + charge.usd_micros > active.hard_caps.usd_micros ->
        {:error, :usd_ceiling}

      true ->
        :ok
    end
  end

  defp apply_charge(active, role, charge) do
    %{
      active
      | reserved: add_usage(active.reserved, charge),
        role_reserved: Map.update!(active.role_reserved, role, &add_usage(&1, charge))
    }
  end

  defp reservation(role, charge), do: Map.put(charge, :role, role)

  defp add_usage(left, right) do
    Map.new(left, fn {key, value} -> {key, value + Map.fetch!(right, key)} end)
  end

  defp empty_usage do
    %{requests: 0, input_tokens: 0, output_tokens: 0, reranker_input_tokens: 0, usd_micros: 0}
  end

  defp model_for_role("target.reranker", models), do: models.reranker
  defp model_for_role("harness.judge", models), do: models.judge
  defp model_for_role(_role, models), do: models.answerer

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_negative_integer(_value), do: {:error, :not_non_negative_integer}

  defp positive_integer(value, _reason) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value, reason), do: {:error, reason}

  defp non_negative_micros(value) when is_number(value) and value >= 0 do
    {:ok,
     Decimal.new(to_string(value))
     |> Decimal.mult(1_000_000)
     |> Decimal.round(0)
     |> Decimal.to_integer()}
  end

  defp non_negative_micros(_value), do: {:error, :invalid_price}
  defp non_negative_usd_micros(value), do: non_negative_micros(value)

  defp cost_micros(input, output, %{input: input_rate, output: output_rate}) do
    numerator = input * input_rate + output * output_rate
    div(numerator + 999_999, 1_000_000)
  end

  defp refused(reason), do: {:error, %Refused{reason: reason}}
end
