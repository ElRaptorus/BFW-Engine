# Metrics pipeline (event sink + Service Task)

This example is an **ETL-style plugin**: an event sink **extracts** execution
signals into shared storage, and a Service Task handler **loads** an aggregated
summary into the token on demand. Treat it as a blueprint for a small
**in-process microservice** with two registered capabilities and one shared data
plane (ETS).

## Moving parts

- **`MetricsPipelinePlugin`** — creates the named counter table (when missing),
  registers `"metrics_collector"` plus the `"aggregate_metrics"` handler.
- **`MetricsCollectorSink`** — updates ETS rows keyed by `{:pi_state, state}` and
  `{:fni_type, flow_node_type}` with `:ets.update_counter/4`.
- **`MetricsAggregatorHandler`** — reads `:ets.tab2list/1`, groups counters, and
  completes the FNI asynchronously via `finish_async` with a payload shaped as:

  ```elixir
  %{
    process_instance_states: %{optional(atom()) => integer()},
    flow_node_types: %{optional(atom()) => integer()}
  }
  ```

For isolated unit tests, pass a dedicated table name into
`MetricsCollectorSink.init/1` and set
`Process.put(:metrics_pipeline_ets_table, table_name)` before invoking
`MetricsAggregatorHandler.handle_enter/3`. The handler follows the async-only
contract — it spawns a Task that calls `finish_async` on the facade.

`bpmn/metrics_pipeline_process.bpmn` wires `implementation="aggregate_metrics"` on the
service task, which the engine uses to dispatch to the registered handler.

## Further reading

- Plugin behaviours and registration order: [`docs/architecture/plugins.md`](../../../../docs/architecture/plugins.md)
- Event fan-out and sink isolation: [`docs/architecture/event-system.md`](../../../../docs/architecture/event-system.md)

## Tests

```bash
mix test apps/peripheral_plugins/test/examples/metrics_pipeline_from_examples_test.exs
```

Or from the project root, if your Mix project includes `examples/` in its test paths:

```bash
mix test examples/plugins/combined/metrics_pipeline/test/metrics_pipeline_test.exs
```
