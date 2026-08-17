# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.DreamTime.Gate do
  @moduledoc """
  Pure scoped admission policy for dream-time work.

  It separates accumulated change, inactivity, and minimum-interval decisions
  so a skipped pass is deterministic and testable without a model or database.
  Work caps are returned with an admitted decision and enforced by the caller.
  """

  @doc """
  Returns `{:run, limits}` or `{:skip, reason}`.

  `latest_change_at` is the latest eligible committed change and
  `last_completed_at` is the durable watermark row's update time. Durations use
  whole milliseconds; equality admits the run.
  """
  def decide(delta_count, latest_change_at, last_completed_at, now, config)
      when is_integer(delta_count) and delta_count >= 0 do
    limits = validate!(config)

    cond do
      delta_count == 0 ->
        {:skip, :no_delta}

      delta_count < limits.min_changes ->
        {:skip, :change_threshold}

      elapsed_ms(latest_change_at, now) < limits.idle_seconds * 1_000 ->
        {:skip, :idle_time}

      last_completed_at &&
          elapsed_ms(last_completed_at, now) < limits.min_interval_seconds * 1_000 ->
        {:skip, :minimum_interval}

      true ->
        {:run, limits}
    end
  end

  defp validate!(config) when is_list(config) do
    limits = Map.new(config)

    for key <- [:min_changes, :max_delta_items, :max_working_set_items, :max_elapsed_ms] do
      unless is_integer(limits[key]) and limits[key] > 0,
        do: raise(ArgumentError, "dream-time #{key} must be positive")
    end

    for key <- [:idle_seconds, :min_interval_seconds] do
      unless is_integer(limits[key]) and limits[key] >= 0,
        do: raise(ArgumentError, "dream-time #{key} must be non-negative")
    end

    limits
  end

  defp elapsed_ms(nil, _now), do: 0
  defp elapsed_ms(then, now), do: max(DateTime.diff(now, then, :millisecond), 0)
end
