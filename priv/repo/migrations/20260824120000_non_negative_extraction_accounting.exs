# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.NonNegativeExtractionAccounting do
  use Ecto.Migration

  def up do
    create constraint(:pipeline_runs, :pipeline_runs_attempt_count_non_negative,
             check: "attempt_count >= 0"
           )

    create constraint(:usage_events, :usage_events_counts_non_negative,
             check:
               "input_tokens >= 0 AND output_tokens >= 0 AND embedding_tokens >= 0 AND duration_ms >= 0"
           )

    create constraint(:extraction_budget_guards, :extraction_budget_caps_positive,
             check: "request_cap > 0 AND token_cap > 0 AND usd_micros_cap > 0"
           )

    create constraint(:extraction_budget_guards, :extraction_budget_rates_non_negative,
             check: "input_usd_micros_per_million >= 0 AND output_usd_micros_per_million >= 0"
           )

    create constraint(:extraction_budget_guards, :extraction_budget_reservations_non_negative,
             check: "requests_reserved >= 0 AND tokens_reserved >= 0 AND usd_micros_reserved >= 0"
           )
  end

  def down do
    drop constraint(:extraction_budget_guards, :extraction_budget_reservations_non_negative)
    drop constraint(:extraction_budget_guards, :extraction_budget_rates_non_negative)
    drop constraint(:extraction_budget_guards, :extraction_budget_caps_positive)
    drop constraint(:usage_events, :usage_events_counts_non_negative)
    drop constraint(:pipeline_runs, :pipeline_runs_attempt_count_non_negative)
  end
end
