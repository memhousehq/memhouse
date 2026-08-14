# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Operations.LifecycleSchedulerTest do
  use ExUnit.Case, async: true

  alias MemHouse.Pipeline.Idempotency

  test "the Cron slot is part of each Account-scoped lifecycle replay key" do
    account_id = "cd1f4e88-358f-40fd-8a71-c4f3365c8df2"
    slot = ~U[2026-08-08 12:00:00Z]

    assert Idempotency.lifecycle_sweep(account_id, "expiry", slot) ==
             Idempotency.lifecycle_sweep(account_id, "expiry", slot)

    refute Idempotency.lifecycle_sweep(account_id, "expiry", slot) ==
             Idempotency.lifecycle_sweep(account_id, "revalidation", slot)

    refute Idempotency.lifecycle_sweep(account_id, "expiry", slot) ==
             Idempotency.lifecycle_sweep(account_id, "expiry", DateTime.add(slot, 1, :hour))
  end

  test "the Cron slot is the Account reconciliation replay key" do
    account_id = "cd1f4e88-358f-40fd-8a71-c4f3365c8df2"
    slot = ~U[2026-08-08 12:00:00Z]

    assert Idempotency.reconciler(account_id, slot) == Idempotency.reconciler(account_id, slot)

    refute Idempotency.reconciler(account_id, slot) ==
             Idempotency.reconciler(account_id, DateTime.add(slot, 1, :hour))
  end
end
