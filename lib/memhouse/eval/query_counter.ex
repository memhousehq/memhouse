# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.QueryCounter do
  @moduledoc """
  Counts Ecto queries during one serial execute-variant run.

  The handler records counts and timings only. It never inspects SQL, parameters,
  results, query sources, or Account identifiers. Attach and detach bound the
  measurement so the snapshot queries on either side are deliberately excluded.
  """

  @event [:mem_house, :repo, :query]
  @slots %{queries: 1, query_time: 2, decode_time: 3, queue_time: 4, idle_time: 5}

  @doc "Returns `{result, content_free_metrics}` for `fun`."
  def measure(fun) when is_function(fun, 0) do
    counters = :counters.new(map_size(@slots), [:atomics])
    handler_id = {__MODULE__, make_ref()}

    :ok = :telemetry.attach(handler_id, @event, &__MODULE__.handle_event/4, counters)

    try do
      result = fun.()

      {result,
       %{
         "queries" => value(counters, :queries),
         "query_time_ms" => native_ms(value(counters, :query_time)),
         "decode_time_ms" => native_ms(value(counters, :decode_time)),
         "queue_time_ms" => native_ms(value(counters, :queue_time)),
         "idle_time_ms" => native_ms(value(counters, :idle_time))
       }}
    after
      :telemetry.detach(handler_id)
    end
  end

  @doc false
  def handle_event(@event, measurements, _metadata, counters) do
    increment(counters, :queries, 1)
    increment(counters, :query_time, Map.get(measurements, :query_time, 0))
    increment(counters, :decode_time, Map.get(measurements, :decode_time, 0))
    increment(counters, :queue_time, Map.get(measurements, :queue_time, 0))
    increment(counters, :idle_time, Map.get(measurements, :idle_time, 0))
  end

  defp increment(counters, key, amount) when is_integer(amount),
    do: :counters.add(counters, Map.fetch!(@slots, key), amount)

  defp increment(_counters, _key, _amount), do: :ok

  defp value(counters, key), do: :counters.get(counters, Map.fetch!(@slots, key))
  defp native_ms(value), do: System.convert_time_unit(value, :native, :microsecond) / 1_000
end
