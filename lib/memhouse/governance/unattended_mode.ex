# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Governance.UnattendedMode do
  @moduledoc """
  Reports whether the deployment has no human governance participant.

  `MEMHOUSE_GOVERNANCE_UNATTENDED=true` applies to every Account, unlike per-Account
  `consent_mode`, and supports headless benchmarks or evaluation.

  It affects consent resolution only, not Gate A/B rules. It is boot-time configuration except in
  tests.
  """

  @doc """
  True when `MEMHOUSE_GOVERNANCE_UNATTENDED` was set at boot.

  False whenever the config key is absent, so an unconfigured deployment
  behaves exactly as it did before this module existed.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    :memhouse
    |> Application.get_env(:governance, [])
    |> Keyword.get(:unattended, false)
  end
end
