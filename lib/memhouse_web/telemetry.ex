# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.Telemetry do
  @moduledoc """
  Supervises periodic measurements and declares content-safe metrics for reporters.

  The poller samples queue depth; `metrics/0` declares aggregations but starts no reporter. Tags may
  contain route patterns, queue/state, event, and status classes—never content, credentials, or
  subject ids. Route patterns avoid raw-path ids and unbounded cardinality.
  """

  use Supervisor

  import Telemetry.Metrics

  @doc """
  Starts the telemetry supervisor under the application's supervision tree.
  """
  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  # Restart poller and future reporters independently.
  @impl true
  def init(_arg) do
    children = [
      # Poll every 10,000 ms: responsive within a deploy window with negligible query load.
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # A reporter goes here when an operator wants these metrics exported, for example:
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  The metric definitions a reporter attaches to.

  Returns a list of `Telemetry.Metrics` structs covering HTTP and channel timings, database
  timings, Oban queue depth, whole-Account export/import duration, and BEAM vitals. Calling
  this function records nothing; it only describes what should be aggregated.
  """
  def metrics do
    [
      # Framework timings are native units; route tags use matched patterns, never raw ids.
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Separate pool wait from query time; never tag SQL text.
      summary("memhouse.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("memhouse.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("memhouse.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("memhouse.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("memhouse.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Queue depth is a current gauge, aggregated with `last_value`.
      last_value("memhouse.operations.queue.depth",
        tags: [:queue, :state],
        description: "Current Oban queue depth by queue and state"
      ),
      # Portability emitters already report milliseconds; tag status only.
      summary("memhouse.portability.export.duration",
        unit: {:millisecond, :millisecond},
        tags: [:status]
      ),
      summary("memhouse.portability.import.duration",
        unit: {:millisecond, :millisecond},
        tags: [:status]
      ),

      # CPU and IO run queues distinguish busy scheduling from blocked work.
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  # Queue depth has no event, so sample it; database failure stays silent to protect the poller.
  defp periodic_measurements do
    [
      {MemHouse.Operations.Health, :emit_queue_metrics, []}
    ]
  end
end
