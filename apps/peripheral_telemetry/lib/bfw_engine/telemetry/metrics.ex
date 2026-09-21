defmodule BfwEngine.Telemetry.Metrics do
  @moduledoc "Defines the Prometheus metric set exported at `GET /metrics`."

  import Telemetry.Metrics

  @doc "Returns the list of metric definitions for the Prometheus reporter."
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      counter("bfw_engine.http.request.total",
        event_name: [:bfw_engine, :http, :stop],
        tags: [:method, :route, :status]
      ),
      distribution("bfw_engine.http.request.duration_ms",
        event_name: [:bfw_engine, :http, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [5, 10, 25, 50, 100, 250, 500, 1000, 5000]]
      ),
      counter("bfw_engine.process_instance.state_change.total",
        event_name: [:bfw_engine, :process_instance, :state_change],
        tags: [:old_state, :new_state]
      ),
      last_value("bfw_engine.process_instance.active.count",
        event_name: [:bfw_engine, :process_instance, :active],
        measurement: :count
      ),
      counter("bfw_engine.flow_node_instance.started.total",
        event_name: [:bfw_engine, :flow_node_instance, :started]
      ),
      counter("bfw_engine.flow_node_instance.state_change.total",
        event_name: [:bfw_engine, :flow_node_instance, :state_change],
        tags: [:flow_node_type, :terminal_state]
      ),
      counter("bfw_engine.event_bus.events.total",
        event_name: [:bfw_engine, :event_bus],
        tags: [:event_type]
      ),
      last_value("bfw_engine.process_instance.capacity.ratio",
        event_name: [:bfw_engine, :process_instance, :capacity],
        measurement: :ratio
      ),
      counter("bfw_engine.dmn.evaluations.total",
        event_name: [:bfw_engine, :dmn, :evaluate, :stop],
        tags: [:hit_policy],
        description: "Total DMN evaluations"
      ),
      distribution("bfw_engine.dmn.evaluate.duration.milliseconds",
        event_name: [:bfw_engine, :dmn, :evaluate, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]],
        description: "DMN evaluation duration"
      ),
      counter("bfw_engine.dmn.evaluations.exceptions.total",
        event_name: [:bfw_engine, :dmn, :evaluate, :exception],
        description: "DMN evaluation exceptions"
      ),
      counter("bfw_engine.dmn.cache.hit.total",
        event_name: [:bfw_engine, :dmn, :cache, :hit],
        description: "DMN ModelCache hits"
      ),
      counter("bfw_engine.dmn.cache.miss.total",
        event_name: [:bfw_engine, :dmn, :cache, :miss],
        description: "DMN ModelCache misses"
      ),
      # --- Escalation metrics ---
      counter("bfw_engine.escalation.raised.total",
        event_name: [:bfw_engine, :escalation, :raised],
        tags: [:throw_type],
        description: "Total escalations raised (both caught and uncaught)"
      ),
      counter("bfw_engine.escalation.uncaught.total",
        event_name: [:bfw_engine, :escalation, :uncaught],
        description: "Total uncaught escalations reaching root process instance"
      ),
      # --- DB pool metrics ---
      distribution("bfw_engine.db.query.queue_time_ms",
        event_name: [:bfw_engine, :db, :query],
        measurement: :queue_time_ms,
        tags: [:repo],
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000]],
        description: "Time waiting for a DB pool connection (ms)"
      ),
      distribution("bfw_engine.db.query.total_time_ms",
        event_name: [:bfw_engine, :db, :query],
        measurement: :total_time_ms,
        tags: [:repo],
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000]],
        description: "Total DB query round-trip time (ms)"
      ),
      counter("bfw_engine.db.query.count",
        event_name: [:bfw_engine, :db, :query],
        tags: [:repo, :source],
        description: "Total DB queries by repo and source table"
      ),
      last_value("bfw_engine.db.pool.size",
        event_name: [:bfw_engine, :db, :pool],
        measurement: :size,
        tags: [:repo],
        description: "Configured DB pool size"
      ),
      last_value("bfw_engine.db.pool.checked_out",
        event_name: [:bfw_engine, :db, :pool],
        measurement: :checked_out,
        tags: [:repo],
        description: "Currently checked-out DB connections"
      ),
      last_value("bfw_engine.db.pool.idle",
        event_name: [:bfw_engine, :db, :pool],
        measurement: :idle,
        tags: [:repo],
        description: "Currently idle DB connections"
      ),

      # --- VM metrics ---
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.memory.processes", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),
      last_value("vm.system_counts.process_count")
    ]
  end
end
