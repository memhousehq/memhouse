# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Operations.RetentionTest do
  @moduledoc "Tests bounded deletion of expired operational history."
  use MemHouse.DataCase, async: false

  alias MemHouse.DataLayer
  alias MemHouse.Operations.Retention
  alias MemHouse.Repo

  setup do
    original = Application.fetch_env!(:memhouse, :retention)

    Application.put_env(:memhouse, :retention,
      oban_jobs_days: 7,
      pipeline_runs_days: 1,
      usage_events_days: 1,
      gate_decisions_days: 1,
      lifecycle_events_days: 1,
      batch_size: 100
    )

    on_exit(fn -> Application.put_env(:memhouse, :retention, original) end)
    :ok
  end

  test "prunes expired terminal runs and usage while preserving active and recent rows" do
    account_key = "retention-#{System.unique_integer([:positive])}"

    {account, ids, actor} =
      DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account,
                                                                                   actor ->
        old_completed = insert_run!(account.id, "completed", 2)
        old_pending = insert_run!(account.id, "pending", 2)
        recent_completed = insert_run!(account.id, "completed", 0)
        old_usage = insert_usage!(account.id, 2)
        recent_usage = insert_usage!(account.id, 0)

        {account,
         %{
           old_completed: old_completed,
           old_pending: old_pending,
           recent_completed: recent_completed,
           old_usage: old_usage,
           recent_usage: recent_usage
         }, actor}
      end)

    zero_durable_summary = MemHouse.Operations.Metering.summary(actor)
    assert zero_durable_summary.storage.operational_bytes > 0
    assert is_nil(zero_durable_summary.storage.operational_to_durable_ratio)

    counts =
      DataLayer.with_account_id(account.id, [role: :system, pipeline?: true], fn _account,
                                                                                 actor ->
        Retention.prune(account.id, actor)
      end)

    assert counts.pipeline_runs == 1
    assert counts.usage_events == 1
    assert counts.gate_decisions == 0
    assert counts.lifecycle_events == 0

    DataLayer.with_actor(actor, fn _account, _actor ->
      refute exists?("pipeline_runs", ids.old_completed)
      assert exists?("pipeline_runs", ids.old_pending)
      assert exists?("pipeline_runs", ids.recent_completed)
      refute exists?("usage_events", ids.old_usage)
      assert exists?("usage_events", ids.recent_usage)
    end)
  end

  defp insert_run!(account_id, status, age_days) do
    id = Ecto.UUID.generate()
    timestamp = DateTime.add(DateTime.utc_now(), -age_days, :day)

    Repo.query!(
      """
      INSERT INTO pipeline_runs
        (id, account_id, kind, target_type, idempotency_key, payload, status,
         attempt_count, inserted_at, updated_at)
      VALUES ($1, $2, 'reconciler', 'account', $3, '{}', $4, 0, $5, $5)
      """,
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(account_id), "retention:#{id}", status, timestamp]
    )

    id
  end

  defp insert_usage!(account_id, age_days) do
    id = Ecto.UUID.generate()
    timestamp = DateTime.add(DateTime.utc_now(), -age_days, :day)

    Repo.query!(
      """
      INSERT INTO usage_events
        (id, account_id, call_id, operation, model_role, provider, model_name,
         model_version, prompt_version, pipeline_version, input_tokens, output_tokens,
         embedding_tokens, duration_ms, status, metadata, occurred_at, inserted_at)
      VALUES
        ($1, $2, $3, 'retention.test', 'edge', 'none', 'none', 'none', 'none',
         'f10-1', 0, 0, 0, 0, 'ok', '{}', $4, $4)
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(account_id),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        timestamp
      ]
    )

    id
  end

  defp exists?(table, id) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM #{table} WHERE id = $1", [Ecto.UUID.dump!(id)])

    count == 1
  end
end
