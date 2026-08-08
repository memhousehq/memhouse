# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Clock do
  @moduledoc """
  Provides the current time through an injectable implementation.

  Production uses the system clock. Tests may replace it process-locally; callers should use this
  module instead of reading wall time directly.
  """

  @callback utc_now() :: DateTime.t()
  @callback monotonic_ms() :: integer()

  @doc """
  The current wall-clock time in UTC, for anything that will be stored or compared.

  Use this for belief times, valid times, decision timestamps, and expiry
  checks. Do not use it to measure how long something took.
  """
  def utc_now do
    Application.get_env(:memhouse, :clock, __MODULE__.System).utc_now()
  end

  @doc """
  A monotonically increasing millisecond reading, for durations and deadlines.

  The absolute number is arbitrary and only differences between two readings on
  the same node mean anything. Use this for remaining-deadline arithmetic and
  latency measurement; never store it as a timestamp.
  """
  def monotonic_ms do
    Application.get_env(:memhouse, :clock, __MODULE__.System).monotonic_ms()
  end

  defmodule System do
    @moduledoc """
    The real clock: the default implementation, backed by the host's system time.

    This is what runs unless configuration names something else. It holds no
    state and adds nothing to the underlying calls — the indirection exists for
    substitutability, not behaviour, so this module must stay a thin pass-through.
    """

    @behaviour MemHouse.Clock

    @impl true
    def utc_now, do: DateTime.utc_now()

    @impl true
    def monotonic_ms, do: :erlang.monotonic_time(:millisecond)
  end
end
