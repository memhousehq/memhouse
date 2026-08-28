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

  alias MemHouse.Model.CampaignBuild
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
  @public_status_key {__MODULE__, :public_status}
  @provider_shutdown_timeout_ms 5_000

  defmodule Refused do
    @moduledoc "A content-free campaign admission rejection."
    defexception [:reason]

    @impl true
    def message(error), do: "campaign admission refused: #{error.reason}"
  end

  @doc false
  def start_link(opts \\ []) do
    :persistent_term.put(@public_status_key, %{active: false, status: "recovering"})
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

  @doc "Returns the bounded campaign state safe for the public health probe."
  def public_status,
    do: :persistent_term.get(@public_status_key, %{active: false, status: "inactive"})

  @doc false
  def dispatch(reservation, lifecycle_owner \\ self()),
    do: GenServer.call(__MODULE__, {:dispatch, reservation, lifecycle_owner})

  @doc false
  def complete(reservation, result),
    do: GenServer.call(__MODULE__, {:complete, reservation, terminal_usage(result)})

  @doc false
  def cancel(reservation), do: GenServer.call(__MODULE__, {:cancel, reservation})

  @doc """
  Atomically reserves one worst-case paid provider attempt.

  Input and output values are upper bounds calculated before the provider
  callback. The return is `{:ok, :inactive}` outside a campaign,
  `{:ok, reservation}` when admitted, or `{:error, %Refused{}}` before spend.
  """
  def reserve(
        %Role{} = config,
        operation,
        input_tokens,
        output_tokens,
        provider_module,
        opts \\ []
      )
      when is_atom(provider_module) do
    identity = Keyword.get(opts, :campaign_identity)
    campaign_role = Keyword.get(opts, :campaign_role)

    GenServer.call(
      __MODULE__,
      {:reserve, config, operation, input_tokens, output_tokens, provider_module, identity,
       campaign_role}
    )
  end

  @doc "True only while an immutable campaign claim is active on this node."
  def active?, do: status().active?

  @impl true
  def init(opts) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    state = %{active: nil, clock: clock}
    activation = Keyword.get(opts, :activate, Application.get_env(:memhouse, :campaign_admission))

    case activation do
      nil ->
        publish_public_status(nil)
        {:ok, state}

      {path, digest, activate_opts} ->
        activate_state(state, path, digest, Keyword.put(activate_opts, :recover, true))
    end
  end

  @impl true
  def handle_call({:activate, path, digest, opts}, _from, %{active: nil} = state) do
    case load(path, digest, Keyword.put(opts, :now_ms, state.clock.())) do
      {:ok, active} -> {:reply, {:ok, active.identity}, put_active(state, active)}
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
      digest: active.digest,
      definition_id: active.definition_id,
      arm: active.arm,
      run_id: active.run_id,
      backend: active.backend,
      abort_policy: active.abort_policy,
      rerun_policy: active.rerun_policy,
      target_revision: active.target_revision,
      reserved: active.reserved,
      hard_caps: active.hard_caps,
      role_caps: active.role_caps,
      role_reserved: active.role_reserved,
      role_usage: active.role_usage,
      routes: public_routes(active.routing)
    }

    {:reply, reply, state}
  end

  def handle_call(
        {:reserve, _config, _operation, _input, _output, _provider, nil, nil},
        _from,
        %{active: nil} = state
      ) do
    {:reply, {:ok, :inactive}, state}
  end

  def handle_call(
        {:reserve, _config, _operation, _input, _output, _provider, _identity, _role},
        _from,
        %{active: nil} = state
      ) do
    {:reply, refused(:missing_admission), state}
  end

  def handle_call(
        {:reserve, config, operation, input, output, provider, identity, role},
        {owner, _tag},
        state
      ) do
    request = %{
      operation: operation,
      input: input,
      output: output,
      provider_module: provider,
      identity: identity,
      role: role,
      owner: owner,
      now_ms: state.clock.()
    }

    case reserve_active(state.active, config, request) do
      {:ok, reservation, active} ->
        {:reply, {:ok, reservation}, put_active(state, active)}

      {:error, reason} ->
        {:reply, refused(reason), state}
    end
  end

  def handle_call({:dispatch, reservation, lifecycle_owner}, {owner, _tag}, state) do
    case transition_dispatch(state.active, reservation, owner, lifecycle_owner) do
      {:ok, active} -> {:reply, :ok, put_active(state, active)}
      {:error, reason} -> {:reply, refused(reason), state}
    end
  end

  def handle_call({:complete, reservation, terminal}, _from, state) do
    case transition_complete(state.active, reservation, terminal) do
      {:ok, active} -> {:reply, :ok, put_active(state, active)}
      {:error, reason} -> {:reply, refused(reason), state}
    end
  end

  def handle_call({:cancel, %{attempt_id: attempt_id}}, {owner, _tag}, state) do
    attempt = state.active && state.active.attempts[attempt_id]

    case attempt do
      %{state: :pending, owner: ^owner} ->
        case cancel_pending(state.active, attempt_id) do
          {:ok, active} -> {:reply, :ok, put_active(state, active)}
          {:error, reason} -> {:reply, refused(reason), state}
        end

      _other ->
        {:reply, refused(:invalid_campaign_attempt), state}
    end
  end

  def handle_call({:cancel, _reservation}, _from, state) do
    {:reply, refused(:invalid_campaign_attempt), state}
  end

  @impl true
  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{active: active} = state) do
    case attempt_by_monitor(active, reference) do
      nil ->
        {:noreply, state}

      {attempt_id, %{state: :pending}} ->
        case cancel_pending(active, attempt_id) do
          {:ok, active} -> {:noreply, put_active(state, active)}
          {:error, :campaign_ledger_unavailable} -> {:noreply, state}
        end

      {attempt_id, %{state: :in_flight}} ->
        case transition_complete(
               active,
               %{attempt_id: attempt_id},
               %{status: :error, usage: nil},
               false
             ) do
          {:ok, active} -> {:noreply, put_active(state, active)}
          {:error, :campaign_ledger_unavailable} -> {:noreply, state}
        end

      {_attempt_id, _attempt} ->
        {:noreply, state}
    end
  end

  defp activate_state(state, path, digest, opts) do
    case load(path, digest, Keyword.put(opts, :now_ms, state.clock.())) do
      {:ok, active} -> {:ok, put_active(state, active)}
      {:error, reason} -> {:stop, %Refused{reason: reason}}
    end
  end

  defp put_active(state, active) do
    publish_public_status(active)
    %{state | active: active}
  end

  defp publish_public_status(nil) do
    :persistent_term.put(@public_status_key, %{active: false, status: "inactive"})
  end

  defp publish_public_status(active) do
    :persistent_term.put(@public_status_key, %{
      active: true,
      status: "active",
      identity: active.identity,
      digest: active.digest,
      definition_id: active.definition_id,
      arm: active.arm,
      run_id: active.run_id,
      backend: active.backend,
      target_revision: active.target_revision,
      # The benchmark contract names admitted packet caps role_reserved. This is
      # deliberately distinct from the consumed reservations in active.role_reserved.
      role_reserved: active.role_caps,
      role_usage: public_role_usage(active.role_usage)
    })
  end

  defp load(path, expected_digest, opts) do
    with :ok <- valid_digest(expected_digest),
         {:ok, bytes} <- read_packet(path),
         :ok <- exact_digest(bytes, expected_digest),
         {:ok, packet} <- decode_packet(bytes),
         {:ok, target_revision} <- target_revision(opts),
         {:ok, active} <- validate_packet(packet, expected_digest, target_revision, opts),
         {:ok, claim} <- claim_once(expected_digest, active.identity, opts) do
      restore_accounting(active, claim)
    end
  end

  # A successful activation consumes this exact packet permanently before any
  # provider call. If the process, node, or later application boot fails, the
  # marker remains and the same approved allowance cannot be reset or replayed.
  # The ledger directory is durable operator-controlled startup configuration.
  # sobelow_skip ["Traversal.FileModule"]
  defp claim_once(digest, identity, opts) do
    ledger_dir = Keyword.get(opts, :ledger_dir)

    with true <- is_binary(ledger_dir) and Path.type(ledger_dir) == :absolute,
         :ok <- File.mkdir_p(ledger_dir) do
      marker = Path.join(ledger_dir, digest <> ".memhouse-started")

      claim_marker(marker, identity, Keyword.get(opts, :recover, false))
    else
      _invalid -> {:error, :campaign_ledger_unavailable}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp claim_marker(marker, identity, recover?) do
    case File.open(marker, [:write, :exclusive, :sync]) do
      {:ok, io} ->
        result = :file.write(io, identity <> "\n")
        :ok = File.close(io)

        case result do
          :ok -> {:ok, :new}
          {:error, _reason} -> {:error, :campaign_ledger_unavailable}
        end

      {:error, :eexist} when recover? ->
        case File.read(marker) do
          {:ok, contents} ->
            if contents == identity <> "\n",
              do: {:ok, :recovered},
              else: {:error, :campaign_already_consumed}

          {:error, _reason} ->
            {:error, :campaign_ledger_unavailable}
        end

      {:error, :eexist} ->
        {:error, :campaign_already_consumed}

      {:error, _reason} ->
        {:error, :campaign_ledger_unavailable}
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
    actual = CampaignBuild.revision()

    cond do
      not is_binary(revision) ->
        {:error, :missing_target_revision}

      not Regex.match?(@full_sha, revision) ->
        {:error, :invalid_target_revision}

      not Regex.match?(@full_sha, actual) ->
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
         {:ok, execution} <- execution_identity(packet, opts),
         :ok <- matching_target_revision(packet, target_revision),
         {:ok, arm} <- campaign_arm(packet, opts),
         {:ok, models} <- models(packet),
         {:ok, routing} <- routing(packet, models),
         {:ok, pricing} <- pricing(packet, models),
         {:ok, roles} <- roles(packet, models, pricing, routing),
         {:ok, hard_caps} <- hard_caps(packet, roles),
         {:ok, wall_seconds} <- positive_integer(hard_caps.wall_seconds, :invalid_wall_ceiling) do
      now_ms = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))

      {:ok,
       %{
         identity: "#{definition_id}:#{execution.run_id}:#{execution.backend["mode"]}:#{digest}",
         definition_id: definition_id,
         arm: arm,
         run_id: execution.run_id,
         backend: execution.backend,
         abort_policy: execution.abort_policy,
         rerun_policy: execution.rerun_policy,
         target_revision: target_revision,
         routing: routing,
         models: models,
         roles: roles,
         hard_caps: Map.delete(hard_caps, :wall_seconds),
         deadline_ms: now_ms + wall_seconds * 1_000,
         digest: digest,
         ledger_dir: Keyword.get(opts, :ledger_dir),
         recovered?: false,
         reserved: empty_usage(),
         role_caps: Map.new(roles, fn {role, caps} -> {role, public_role_caps(role, caps)} end),
         role_reserved: Map.new(@paid_roles, &{&1, empty_usage()}),
         role_usage: Map.new(@paid_roles, &{&1, empty_role_usage()}),
         attempts: %{}
       }}
    end
  end

  defp approved_packet(packet) do
    if packet["schema_version"] == "membench-campaign-admission-2" and
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
      not valid_public_id?(value) -> {:error, :invalid_campaign_identity}
      not valid_public_id?(expected) -> {:error, :missing_campaign_identity}
      expected != value -> {:error, :campaign_identity_mismatch}
      true -> {:ok, value}
    end
  end

  defp execution_identity(packet, opts) do
    run_id = get_in(packet, ["execution", "run_id"])
    backend = get_in(packet, ["execution", "backend"])
    abort_policy = get_in(packet, ["execution", "abort_policy"])
    rerun_policy = get_in(packet, ["execution", "rerun_policy"])
    expected_run_id = Keyword.get(opts, :run_id)
    expected_backend = Keyword.get(opts, :backend)

    cond do
      not valid_run_id?(run_id) ->
        {:error, :invalid_campaign_run}

      not valid_backend?(backend) ->
        {:error, :invalid_campaign_backend}

      abort_policy != "consume-packet-no-resume" or
          rerun_policy != "new-packet-new-run-id" ->
        {:error, :invalid_campaign_restart_policy}

      not valid_run_id?(expected_run_id) ->
        {:error, :missing_campaign_run}

      not valid_backend?(expected_backend) ->
        {:error, :missing_campaign_backend}

      expected_run_id != run_id ->
        {:error, :campaign_run_mismatch}

      expected_backend != backend ->
        {:error, :campaign_backend_mismatch}

      true ->
        {:ok,
         %{
           run_id: run_id,
           backend: backend,
           abort_policy: abort_policy,
           rerun_policy: rerun_policy
         }}
    end
  end

  defp valid_run_id?(value) when is_binary(value),
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/, value)

  defp valid_run_id?(_value), do: false

  defp valid_public_id?(value) when is_binary(value),
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/, value)

  defp valid_public_id?(_value), do: false

  defp valid_backend?(
         backend = %{
           "engine" => "postgres",
           "mode" => mode,
           "sqlite" => "unsupported"
         }
       )
       when mode in ["external", "pg0"] and map_size(backend) == 3,
       do: true

  defp valid_backend?(_backend), do: false

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
      if is_binary(requested_id) and requested_id != "" and is_list(arms),
        do: Enum.find(arms, &(&1["id"] == requested_id)),
        else: nil

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
      when is_binary(id) and is_binary(prompt) ->
        if valid_public_id?(id) and valid_public_id?(prompt),
          do: {:ok, %{id: id, prompt_version: prompt, batching: batching}},
          else: {:error, :campaign_arm_mismatch}

      _invalid ->
        {:error, :campaign_arm_mismatch}
    end
  end

  defp routing(packet, models) do
    raw = get_in(packet, ["execution", "routes"])

    if is_map(raw) and Map.keys(raw) |> Enum.sort() == Enum.sort(@paid_roles) do
      Enum.reduce_while(@paid_roles, {:ok, %{}}, fn role, {:ok, acc} ->
        case validated_paid_role_route(raw[role], role, models) do
          {:ok, route} ->
            {:cont, {:ok, Map.put(acc, role, route)}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    else
      {:error, :unpriceable_routing}
    end
  end

  defp validated_paid_role_route(raw, role, models) do
    with {:ok, route} <- paid_role_route(raw),
         true <- compatible_model_route?(role, model_for_role(role, models), route) do
      {:ok, route}
    else
      false -> {:error, :unpriceable_routing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp paid_role_route(
         raw_route = %{
           "provider" => "openrouter",
           "endpoint" => endpoint,
           "upstream_route" => upstream_route,
           "credential_ref" => "env:" <> variable
         }
       )
       when map_size(raw_route) == 4 and is_binary(endpoint) and endpoint != "" and
              is_binary(upstream_route) and upstream_route != "" do
    cond do
      String.trim(endpoint) == "" or String.trim(upstream_route) == "" ->
        {:error, :unpriceable_routing}

      not Regex.match?(~r/\A[A-Z_][A-Z0-9_]*\z/, variable) ->
        {:error, :unpriceable_routing}

      is_nil(System.get_env(variable)) or String.trim(System.get_env(variable)) == "" ->
        {:error, :campaign_credentials_unavailable}

      true ->
        {:ok,
         %{
           credential_ref: "env:" <> variable,
           credential_status: :present,
           credential_variable: variable,
           endpoint: endpoint,
           provider: "openrouter",
           upstream_route: upstream_route
         }}
    end
  end

  defp paid_role_route(_invalid), do: {:error, :unpriceable_routing}

  defp compatible_model_route?(
         "target.reranker",
         "voyageai/rerank-2.5",
         %{upstream_route: "voyageai"}
       ),
       do: true

  defp compatible_model_route?(role, model, %{upstream_route: route})
       when role != "target.reranker" and model != "voyageai/rerank-2.5" and route != "voyageai",
       do: true

  defp compatible_model_route?(_role, _model, _route), do: false

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

  defp roles(packet, models, pricing, routing) do
    raw = packet["paid_roles"]

    if is_map(raw) and Map.keys(raw) |> Enum.sort() == Enum.sort(@paid_roles) do
      Enum.reduce_while(@paid_roles, {:ok, %{}}, fn role, {:ok, acc} ->
        model = model_for_role(role, models)

        with {:ok, caps} <- role_caps(raw[role]),
             :ok <- cap_prices_tokens(caps, pricing[model]) do
          configured =
            caps
            |> Map.put(:model, model)
            |> Map.put(:rates, pricing[model])
            |> Map.put(:route, routing[role])

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
       %{
         requests: requests,
         input_tokens: input,
         output_tokens: output,
         usd_micros: usd_micros
       }}
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
         %Role{provider: provider, role: role},
         %{provider_module: provider_module, identity: identity}
       )
       when provider in @local_providers and
              role not in [:ingest_extractor, :dream_reasoner, :dialectic_agent, :reranker] do
    with :ok <- matching_identity(active, identity),
         :ok <- matching_provider_module(provider, provider_module) do
      {:ok, :local, active}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp reserve_active(
         active,
         config,
         %{
           operation: operation,
           input: input,
           output: output,
           provider_module: provider_module,
           identity: identity,
           role: role,
           owner: owner,
           now_ms: now
         }
       ) do
    with :ok <- dispatchable(active),
         :ok <- matching_identity(active, identity),
         {:ok, paid_role} <- paid_role(config, operation, role),
         :ok <- matching_route(active, config, paid_role),
         {:ok, input} <- non_negative_integer(input),
         {:ok, output} <- non_negative_integer(output),
         :ok <- before_deadline(active, now),
         {:ok, charge} <- charge(active, paid_role, input, output),
         :ok <- within_caps(active, paid_role, charge),
         :ok <- matching_provider_module(config.provider, provider_module) do
      attempt_id = attempt_id()
      reference = Process.monitor(owner)
      reservation = reservation(paid_role, charge, active.deadline_ms - now, attempt_id)
      active = apply_charge(active, paid_role, charge, attempt_id, reference, owner)

      case persist_accounting(active) do
        :ok ->
          {:ok, reservation, active}

        {:error, _reason} ->
          Process.demonitor(reference, [:flush])
          {:error, :campaign_ledger_unavailable}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatchable(%{recovered?: true}), do: {:error, :campaign_already_consumed}
  defp dispatchable(_active), do: :ok

  defp matching_identity(_active, nil), do: :ok
  defp matching_identity(%{identity: identity}, identity), do: :ok
  defp matching_identity(_active, _other), do: {:error, :campaign_identity_mismatch}

  defp matching_provider_module("openrouter", MemHouse.Model.Providers.ReqLLM), do: :ok
  defp matching_provider_module("deterministic", MemHouse.Model.Providers.Deterministic), do: :ok
  defp matching_provider_module("ortex", MemHouse.Model.Providers.Ortex), do: :ok
  defp matching_provider_module(_provider, _module), do: {:error, :provider_override}

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
    route = active.roles[role].route

    prompt_matches? =
      role != "target.ingest_extractor" or config.prompt_version == active.arm.prompt_version

    batching_matches? =
      role != "target.ingest_extractor" or current_batching() == active.arm.batching

    if config.provider == route.provider and config.model == expected_model and
         Map.get(config.options, "base_url") == route.endpoint and
         Map.get(config.options, "upstream_route") == route.upstream_route and
         Map.get(config.options, "api_key_ref") == route.credential_ref and
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

  defp apply_charge(active, role, charge, attempt_id, reference, owner) do
    %{
      active
      | reserved: add_usage(active.reserved, charge),
        role_reserved: Map.update!(active.role_reserved, role, &add_usage(&1, charge)),
        role_usage:
          Map.update!(
            active.role_usage,
            role,
            &Map.update!(&1, :pending_attempts, fn n -> n + 1 end)
          ),
        attempts:
          Map.put(active.attempts, attempt_id, %{
            role: role,
            state: :pending,
            occurred_at: nil,
            monitor: reference,
            owner: owner
          })
    }
  end

  defp reservation(role, charge, remaining_wall_ms, attempt_id) do
    charge
    |> Map.put(:role, role)
    |> Map.put(:remaining_wall_ms, remaining_wall_ms)
    |> Map.put(:attempt_id, attempt_id)
  end

  defp add_usage(left, right) do
    Map.new(left, fn {key, value} -> {key, value + Map.fetch!(right, key)} end)
  end

  defp empty_usage do
    %{requests: 0, input_tokens: 0, output_tokens: 0, reranker_input_tokens: 0, usd_micros: 0}
  end

  defp public_role_caps(role, caps) do
    %{
      requests: caps.requests,
      input_tokens: caps.input_tokens,
      output_tokens: caps.output_tokens,
      reranker_input_tokens: if(role == "target.reranker", do: caps.input_tokens, else: 0),
      usd_micros: caps.usd_micros
    }
  end

  defp public_role_usage(role_usage) do
    Map.new(role_usage, fn {role, usage} -> {role, Map.delete(usage, :usd_micros)} end)
  end

  defp empty_role_usage do
    %{
      attempts: 0,
      errors: 0,
      unmetered_attempts: 0,
      pending_attempts: 0,
      in_flight: 0,
      input_tokens: 0,
      output_tokens: 0,
      usd_micros: 0,
      first_occurred_at: nil,
      last_occurred_at: nil
    }
  end

  defp transition_dispatch(active, reservation, _owner, _lifecycle_owner)
       when reservation in [:inactive, :local],
       do: {:ok, active}

  defp transition_dispatch(%{recovered?: true}, _reservation, _owner, _lifecycle_owner),
    do: {:error, :campaign_already_consumed}

  defp transition_dispatch(active, %{attempt_id: attempt_id}, owner, lifecycle_owner)
       when is_pid(lifecycle_owner) do
    case active.attempts[attempt_id] do
      %{state: :pending, role: role, owner: ^owner} = attempt ->
        occurred_at = DateTime.utc_now() |> DateTime.to_iso8601()
        current = active.role_usage[role]
        previous_monitor = attempt.monitor

        lifecycle_monitor =
          if lifecycle_owner == owner,
            do: previous_monitor,
            else: Process.monitor(lifecycle_owner)

        usage =
          current
          |> Map.update!(:pending_attempts, &(&1 - 1))
          |> Map.update!(:in_flight, &(&1 + 1))
          |> Map.update!(:attempts, &(&1 + 1))
          |> Map.put(:first_occurred_at, current.first_occurred_at || occurred_at)
          |> Map.put(:last_occurred_at, occurred_at)

        updated = %{
          active
          | role_usage: Map.put(active.role_usage, role, usage),
            attempts:
              Map.put(active.attempts, attempt_id, %{
                attempt
                | state: :in_flight,
                  occurred_at: occurred_at,
                  monitor: lifecycle_monitor,
                  owner: lifecycle_owner
              })
        }

        case persist_transition(updated) do
          {:ok, _active} = success ->
            if lifecycle_monitor != previous_monitor,
              do: Process.demonitor(previous_monitor, [:flush])

            success

          {:error, _reason} = error ->
            if lifecycle_monitor != previous_monitor,
              do: Process.demonitor(lifecycle_monitor, [:flush])

            error
        end

      _other ->
        {:error, :invalid_campaign_attempt}
    end
  end

  defp transition_dispatch(_active, _reservation, _owner, _lifecycle_owner),
    do: {:error, :invalid_campaign_attempt}

  defp transition_complete(active, reservation, terminal, demonitor? \\ true)

  defp transition_complete(active, reservation, _terminal, _demonitor?)
       when reservation in [:inactive, :local],
       do: {:ok, active}

  defp transition_complete(active, %{attempt_id: attempt_id}, terminal, demonitor?) do
    case active.attempts[attempt_id] do
      %{state: :in_flight, role: role, monitor: reference} = attempt ->
        usage = complete_usage(active.role_usage[role], terminal, active.roles[role].rates)

        updated = %{
          active
          | role_usage: Map.put(active.role_usage, role, usage),
            attempts:
              Map.put(active.attempts, attempt_id, %{
                attempt
                | state: :terminal,
                  monitor: nil,
                  owner: nil
              })
        }

        case persist_transition(updated) do
          {:ok, _active} = success ->
            if demonitor? and is_reference(reference), do: Process.demonitor(reference, [:flush])
            success

          {:error, _reason} = error ->
            error
        end

      %{state: :terminal} ->
        {:ok, active}

      _other ->
        {:error, :invalid_campaign_attempt}
    end
  end

  defp transition_complete(_active, _reservation, _terminal, _demonitor?),
    do: {:error, :invalid_campaign_attempt}

  defp cancel_pending(active, attempt_id) do
    %{role: role, monitor: reference} = active.attempts[attempt_id]
    usage = Map.update!(active.role_usage[role], :pending_attempts, &(&1 - 1))

    updated = %{
      active
      | role_usage: Map.put(active.role_usage, role, usage),
        attempts: Map.delete(active.attempts, attempt_id)
    }

    case persist_transition(updated) do
      {:ok, _active} = success ->
        if is_reference(reference), do: Process.demonitor(reference, [:flush])
        success

      {:error, _reason} = error ->
        error
    end
  end

  defp complete_usage(usage, %{status: status, usage: metering}, rates) do
    complete? =
      is_map(metering) and is_integer(metering[:input_tokens]) and metering[:input_tokens] >= 0 and
        is_integer(metering[:output_tokens]) and metering[:output_tokens] >= 0

    usage = Map.update!(usage, :in_flight, &(&1 - 1))
    usage = if status == :error, do: Map.update!(usage, :errors, &(&1 + 1)), else: usage

    if complete? do
      input = metering.input_tokens
      output = metering.output_tokens

      usage
      |> Map.update!(:input_tokens, &(&1 + input))
      |> Map.update!(:output_tokens, &(&1 + output))
      |> Map.update!(:usd_micros, &(&1 + cost_micros(input, output, rates)))
    else
      Map.update!(usage, :unmetered_attempts, &(&1 + 1))
    end
  end

  defp terminal_usage({:ok, %MemHouse.Model.Provider.Result{usage: usage}}),
    do: %{status: :ok, usage: usage}

  defp terminal_usage({:error, _reason}), do: %{status: :error, usage: nil}
  defp terminal_usage(_other), do: %{status: :error, usage: nil}

  defp attempt_by_monitor(nil, _reference), do: nil

  defp attempt_by_monitor(active, reference) do
    Enum.find(active.attempts, fn {_id, attempt} -> attempt.monitor == reference end)
  end

  defp attempt_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp persist_transition(active) do
    case persist_accounting(active) do
      :ok -> {:ok, active}
      {:error, _reason} -> {:error, :campaign_ledger_unavailable}
    end
  end

  defp accounting_path(active),
    do: Path.join(active.ledger_dir, active.digest <> ".memhouse-accounting.json")

  # The operator-selected directory and authenticated digest determine this
  # path. Provider and request content never contributes to it.
  # sobelow_skip ["Traversal.FileModule"]
  defp persist_accounting(active) do
    path = accounting_path(active)
    temporary = path <> ".tmp"

    payload = %{
      schema_version: "memhouse-campaign-accounting-1",
      identity: active.identity,
      digest: active.digest,
      definition_id: active.definition_id,
      run_id: active.run_id,
      backend: active.backend,
      reserved: active.reserved,
      role_reserved: active.role_reserved,
      role_usage: active.role_usage,
      attempts:
        Map.new(active.attempts, fn {id, attempt} ->
          {id, Map.take(attempt, [:role, :state, :occurred_at])}
        end)
    }

    with :ok <- File.write(temporary, Jason.encode!(payload), [:sync]),
         :ok <- File.rename(temporary, path),
         :ok <- sync_directory(Path.dirname(path)) do
      :ok
    else
      _error -> {:error, :campaign_ledger_unavailable}
    end
  end

  defp sync_directory(directory) do
    with {:ok, descriptor} <- :file.open(String.to_charlist(directory), [:read, :raw, :directory]) do
      result = :file.sync(descriptor)
      :ok = :file.close(descriptor)
      result
    end
  end

  defp restore_accounting(active, :new), do: {:ok, active}

  # sobelow_skip ["Traversal.FileModule"]
  defp restore_accounting(active, :recovered) do
    with :ok <- stop_interrupted_provider_tasks() do
      restore_recovered_accounting(active)
    end
  end

  # The ledger path is derived only from the validated operator-selected
  # directory and the authenticated fixed-length digest.
  # sobelow_skip ["Traversal.FileModule"]
  defp restore_recovered_accounting(active) do
    case File.read(accounting_path(active)) do
      {:error, :enoent} ->
        {:ok, %{active | recovered?: true}}

      {:ok, bytes} ->
        with {:ok, payload} <- Jason.decode(bytes),
             :ok <- matching_accounting_identity(active, payload),
             {:ok, restored} <- restore_payload(active, payload),
             {:ok, reconciled} <- reconcile_recovered_attempts(restored),
             :ok <- persist_accounting(reconciled) do
          {:ok, %{reconciled | recovered?: true}}
        else
          _invalid -> {:error, :campaign_ledger_unavailable}
        end

      {:error, _reason} ->
        {:error, :campaign_ledger_unavailable}
    end
  end

  defp stop_interrupted_provider_tasks do
    case Process.whereis(MemHouse.Model.CampaignProviderTaskSupervisor) do
      nil ->
        :ok

      _supervisor ->
        MemHouse.Model.CampaignProviderTaskSupervisor
        |> Task.Supervisor.children()
        |> Enum.reduce_while(:ok, &stop_interrupted_provider_task/2)
    end
  end

  defp stop_interrupted_provider_task(provider_task, :ok) do
    reference = Process.monitor(provider_task)

    case Task.Supervisor.terminate_child(
           MemHouse.Model.CampaignProviderTaskSupervisor,
           provider_task
         ) do
      :ok -> reduce_provider_shutdown(await_provider_task_down(reference, provider_task))
      {:error, :not_found} -> demonitor_missing_provider(reference)
    end
  end

  defp reduce_provider_shutdown(:ok), do: {:cont, :ok}
  defp reduce_provider_shutdown({:error, _reason} = error), do: {:halt, error}

  defp demonitor_missing_provider(reference) do
    Process.demonitor(reference, [:flush])
    {:cont, :ok}
  end

  defp await_provider_task_down(reference, provider_task) do
    receive do
      {:DOWN, ^reference, :process, ^provider_task, _reason} -> :ok
    after
      @provider_shutdown_timeout_ms ->
        Process.demonitor(reference, [:flush])
        {:error, :campaign_ledger_unavailable}
    end
  end

  defp matching_accounting_identity(active, payload) do
    if payload["schema_version"] == "memhouse-campaign-accounting-1" and
         payload["identity"] == active.identity and payload["digest"] == active.digest and
         payload["definition_id"] == active.definition_id and payload["run_id"] == active.run_id and
         payload["backend"] == active.backend,
       do: :ok,
       else: {:error, :campaign_ledger_unavailable}
  end

  defp restore_payload(active, payload) do
    with {:ok, reserved} <- restore_map(payload["reserved"], empty_usage()),
         {:ok, role_reserved} <- restore_roles(payload["role_reserved"], empty_usage()),
         {:ok, role_usage} <- restore_roles(payload["role_usage"], empty_role_usage()),
         {:ok, attempts} <- restore_attempts(payload["attempts"]) do
      {:ok,
       %{
         active
         | reserved: reserved,
           role_reserved: role_reserved,
           role_usage: role_usage,
           attempts: attempts
       }}
    end
  end

  defp reconcile_recovered_attempts(active) do
    Enum.reduce_while(active.attempts, {:ok, active}, fn
      {attempt_id, %{state: :pending, role: role}}, {:ok, current} ->
        usage = current.role_usage[role]

        if usage.pending_attempts > 0 do
          reconciled_usage = Map.update!(usage, :pending_attempts, &(&1 - 1))

          {:cont,
           {:ok,
            %{
              current
              | role_usage: Map.put(current.role_usage, role, reconciled_usage),
                attempts: Map.delete(current.attempts, attempt_id)
            }}}
        else
          {:halt, {:error, :campaign_ledger_unavailable}}
        end

      {attempt_id, %{state: :in_flight, role: role} = attempt}, {:ok, current} ->
        usage = current.role_usage[role]

        if usage.in_flight > 0 do
          reconciled_usage =
            usage
            |> Map.update!(:in_flight, &(&1 - 1))
            |> Map.update!(:errors, &(&1 + 1))
            |> Map.update!(:unmetered_attempts, &(&1 + 1))

          terminal_attempt = %{attempt | state: :terminal, monitor: nil, owner: nil}

          {:cont,
           {:ok,
            %{
              current
              | role_usage: Map.put(current.role_usage, role, reconciled_usage),
                attempts: Map.put(current.attempts, attempt_id, terminal_attempt)
            }}}
        else
          {:halt, {:error, :campaign_ledger_unavailable}}
        end

      {_attempt_id, %{state: :terminal}}, {:ok, current} ->
        {:cont, {:ok, current}}
    end)
  end

  defp restore_roles(value, shape) when is_map(value) do
    if Map.keys(value) |> Enum.sort() == Enum.sort(@paid_roles) do
      Enum.reduce_while(value, {:ok, %{}}, fn {role, fields}, {:ok, acc} ->
        case restore_map(fields, shape) do
          {:ok, restored} -> {:cont, {:ok, Map.put(acc, role, restored)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, :campaign_ledger_unavailable}
    end
  end

  defp restore_roles(_value, _shape), do: {:error, :campaign_ledger_unavailable}

  defp restore_map(value, shape) when is_map(value) do
    Enum.reduce_while(shape, {:ok, %{}}, fn {key, default}, {:ok, acc} ->
      raw = value[Atom.to_string(key)]

      cond do
        is_integer(default) and is_integer(raw) and raw >= 0 ->
          {:cont, {:ok, Map.put(acc, key, raw)}}

        is_nil(default) and valid_occurrence_time?(raw) ->
          {:cont, {:ok, Map.put(acc, key, raw)}}

        true ->
          {:halt, {:error, :campaign_ledger_unavailable}}
      end
    end)
  end

  defp restore_map(_value, _shape), do: {:error, :campaign_ledger_unavailable}

  defp restore_attempts(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {id, attempt}, {:ok, acc} ->
      state = attempt["state"]
      role = attempt["role"]
      occurred_at = attempt["occurred_at"]

      if role in @paid_roles and state in ["pending", "in_flight", "terminal"] and
           valid_attempt_time?(state, occurred_at) do
        restored = %{
          role: role,
          state: state_atom(state),
          occurred_at: occurred_at,
          monitor: nil,
          owner: nil
        }

        {:cont, {:ok, Map.put(acc, id, restored)}}
      else
        {:halt, {:error, :campaign_ledger_unavailable}}
      end
    end)
  end

  defp restore_attempts(_value), do: {:error, :campaign_ledger_unavailable}

  defp state_atom("pending"), do: :pending
  defp state_atom("in_flight"), do: :in_flight
  defp state_atom("terminal"), do: :terminal

  defp valid_attempt_time?("pending", nil), do: true

  defp valid_attempt_time?(state, value) when state in ["in_flight", "terminal"] do
    with true <- is_binary(value) and byte_size(value) <= 40,
         {:ok, parsed, _offset} <- DateTime.from_iso8601(value),
         true <- parsed.time_zone == "Etc/UTC" do
      true
    else
      _invalid -> false
    end
  end

  defp valid_attempt_time?(_state, _value), do: false

  defp valid_occurrence_time?(nil), do: true

  defp valid_occurrence_time?(value) do
    valid_attempt_time?("terminal", value)
  end

  defp model_for_role("target.reranker", models), do: models.reranker
  defp model_for_role("harness.judge", models), do: models.judge
  defp model_for_role(_role, models), do: models.answerer

  defp public_routes(routing) do
    Map.new(routing, fn {role, route} ->
      public = %{
        credential: %{status: route.credential_status, variable: route.credential_variable},
        endpoint: route.endpoint,
        provider: route.provider,
        upstream_route: route.upstream_route
      }

      {role, public}
    end)
  end

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

  defp non_negative_usd_micros(value) when is_number(value) and value >= 0 do
    {:ok,
     Decimal.new(to_string(value))
     |> Decimal.mult(1_000_000)
     |> Decimal.round(0, :ceiling)
     |> Decimal.to_integer()}
  end

  defp non_negative_usd_micros(_value), do: {:error, :invalid_price}

  defp cost_micros(input, output, %{input: input_rate, output: output_rate}) do
    numerator = input * input_rate + output * output_rate
    div(numerator + 999_999, 1_000_000)
  end

  defp refused(reason), do: {:error, %Refused{reason: reason}}
end
