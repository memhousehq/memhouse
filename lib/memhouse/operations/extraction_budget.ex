# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Operations.ExtractionBudget do
  @moduledoc """
  Durably reserves worst-case extraction spend before a provider attempt.

  Guards are scoped to one corpus path. Each structured extractor attempt
  atomically reserves one request, its counted input, the configured maximum
  output, and the corresponding harness-supplied price. A provider callback is
  never started when any remaining cap cannot cover that reservation.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Pipeline.ExtractionAdmission
  alias MemHouse.Pipeline.Extractor
  alias MemHouse.Repo

  @registration_keys MapSet.new(~w(
    scope_root request_cap token_cap usd_micros_cap deadline_at
    input_usd_micros_per_million output_usd_micros_per_million
  ))

  defmodule ExceededError do
    defexception [:reason]
    @impl true
    def message(error), do: "extraction budget admission refused: #{error.reason}"
  end

  def register(actor, attrs) do
    with {:ok, values} <- validate(attrs) do
      DataLayer.in_account_transaction(actor.account_id, fn ->
        result =
          Repo.query!(
            """
            INSERT INTO extraction_budget_guards
              (account_id, scope_root, request_cap, token_cap, usd_micros_cap,
               deadline_at, input_usd_micros_per_million,
               output_usd_micros_per_million, inserted_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now(), now())
            ON CONFLICT (account_id, scope_root) DO UPDATE SET
              request_cap = EXCLUDED.request_cap,
              token_cap = EXCLUDED.token_cap,
              usd_micros_cap = EXCLUDED.usd_micros_cap,
              deadline_at = EXCLUDED.deadline_at,
              input_usd_micros_per_million = EXCLUDED.input_usd_micros_per_million,
              output_usd_micros_per_million = EXCLUDED.output_usd_micros_per_million,
              updated_at = now()
            RETURNING requests_reserved, tokens_reserved, usd_micros_reserved
            """,
            [
              Ecto.UUID.dump!(actor.account_id),
              values.scope_root,
              values.request_cap,
              values.token_cap,
              values.usd_micros_cap,
              values.deadline_at,
              values.input_usd_micros_per_million,
              values.output_usd_micros_per_million
            ]
          )

        [reserved] = result.rows

        budget =
          values
          |> Map.merge(reserved_map(reserved))
          |> Map.put(:extraction_identity, extraction_identity())

        {:ok, budget}
      end)
    end
  end

  defp extraction_identity do
    %{
      prompt_version: Extractor.prompt_version(),
      pipeline_version: Extractor.pipeline_version(),
      batching_enabled: ExtractionAdmission.enabled?(),
      batching_identity: ExtractionAdmission.config()[:identity]
    }
  end

  def reserve(context, messages, schema) do
    account_id = Map.get(context, :account_id)
    scope_path = Map.get(context, :scope_path)
    actor = Map.get(context, :actor)

    if is_binary(account_id) and is_binary(scope_path) and is_struct(actor, MemHouse.Actor) do
      input_tokens = ExtractionAdmission.count(%{"messages" => messages, "schema" => schema})
      output_tokens = ExtractionAdmission.config()[:reserved_output_tokens]

      DataLayer.in_account_transaction(account_id, fn ->
        reserve_locked(account_id, scope_path, input_tokens, output_tokens)
      end)
    else
      {:ok, nil}
    end
  end

  defp reserve_locked(account_id, scope_path, input_tokens, output_tokens) do
    result =
      Repo.query!(
        """
        WITH selected AS (
          SELECT account_id, scope_root,
                 CEIL(($3::numeric * input_usd_micros_per_million +
                       $4::numeric * output_usd_micros_per_million) / 1000000)::bigint AS usd,
                 deadline_at
          FROM extraction_budget_guards
          WHERE account_id = $1
            AND ($2 = scope_root OR
                 LEFT($2, length(scope_root) + 1) = scope_root || '/')
          ORDER BY length(scope_root) DESC
          LIMIT 1
        )
        UPDATE extraction_budget_guards AS guard
        SET requests_reserved = requests_reserved + 1,
            tokens_reserved = tokens_reserved + $3 + $4,
            usd_micros_reserved = usd_micros_reserved + selected.usd,
            updated_at = now()
        FROM selected
        WHERE guard.account_id = selected.account_id
          AND guard.scope_root = selected.scope_root
          AND now() < selected.deadline_at
          AND guard.requests_reserved + 1 <= guard.request_cap
          AND guard.tokens_reserved + $3 + $4 <= guard.token_cap
          AND guard.usd_micros_reserved + selected.usd <= guard.usd_micros_cap
        RETURNING GREATEST(
          1,
          FLOOR(EXTRACT(EPOCH FROM (selected.deadline_at - now())) * 1000)
        )::bigint
        """,
        [Ecto.UUID.dump!(account_id), scope_path, input_tokens, output_tokens]
      )

    case result.rows do
      [[remaining_ms]] -> {:ok, remaining_ms}
      [] -> guard_or_unbounded(account_id, scope_path)
    end
  end

  defp guard_or_unbounded(account_id, scope_path) do
    result =
      Repo.query!(
        """
        SELECT 1 FROM extraction_budget_guards
        WHERE account_id = $1
          AND ($2 = scope_root OR
               LEFT($2, length(scope_root) + 1) = scope_root || '/')
        LIMIT 1
        """,
        [Ecto.UUID.dump!(account_id), scope_path]
      )

    if result.num_rows == 0,
      do: {:ok, nil},
      else: {:error, %ExceededError{reason: "request, token, USD, or wall-time cap"}}
  end

  defp validate(attrs) when is_map(attrs) do
    true = MapSet.equal?(MapSet.new(Map.keys(attrs)), @registration_keys)
    scope_root = fetch_binary!(attrs, "scope_root")
    {:ok, deadline_at, _offset} = attrs |> Map.fetch!("deadline_at") |> DateTime.from_iso8601()

    values = %{
      scope_root: scope_root,
      request_cap: fetch_positive!(attrs, "request_cap"),
      token_cap: fetch_positive!(attrs, "token_cap"),
      usd_micros_cap: fetch_positive!(attrs, "usd_micros_cap"),
      deadline_at: deadline_at,
      input_usd_micros_per_million: fetch_non_negative!(attrs, "input_usd_micros_per_million"),
      output_usd_micros_per_million: fetch_non_negative!(attrs, "output_usd_micros_per_million")
    }

    if DateTime.after?(deadline_at, DateTime.utc_now()),
      do: {:ok, values},
      else: {:error, :invalid}
  rescue
    _error -> {:error, :invalid}
  end

  defp validate(_attrs), do: {:error, :invalid}

  defp fetch_binary!(attrs, key) do
    value = Map.fetch!(attrs, key)
    if is_binary(value) and String.starts_with?(value, "/"), do: value, else: raise(ArgumentError)
  end

  defp fetch_positive!(attrs, key) do
    value = Map.fetch!(attrs, key)
    if is_integer(value) and value > 0, do: value, else: raise(ArgumentError)
  end

  defp fetch_non_negative!(attrs, key) do
    value = Map.fetch!(attrs, key)
    if is_integer(value) and value >= 0, do: value, else: raise(ArgumentError)
  end

  defp reserved_map([requests, tokens, usd]),
    do: %{requests_reserved: requests, tokens_reserved: tokens, usd_micros_reserved: usd}
end
