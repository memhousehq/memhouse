# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Governance.UnattendedMode do
  @moduledoc """
  Reports whether the deployment has no human governance participant.

  `MEMHOUSE_GOVERNANCE_UNATTENDED=true` applies to every Account, unlike per-Account
  `consent_mode`, and supports headless benchmarks or evaluation.

  It grants consent for personal knowledge and safely rejects restricted proposals before they
  can require a human decision. It is boot-time configuration except in tests.
  """

  @restricted_reason "restricted_unattended_policy"

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

  @doc "Stable lifecycle reason for restricted proposals withheld in unattended mode."
  @spec restricted_reason() :: String.t()
  def restricted_reason, do: @restricted_reason
end
