# RabbitMQ → engine orchestration (combined plugin)

Copy these modules into an OTP application that already loads `EvilEngine.Plugin`
(see the engine plugin loading docs). This example shows **multiple capabilities in
one plugin**: a queue-driven `GenServer`, catalog access through `EngineFacade`,
and a co-registered **event sink** that observes both engine events and
application-defined events published through the bus.

## Moving parts

- **`RabbitmqOrchestratorPlugin`** — `on_load/1` caches the facade in `FacadeStore`
  and registers the `"orchestrator_metrics"` sink. `on_ready/1` starts
  `RabbitmqConsumer` once the API tier is listening.
- **`RabbitmqConsumer`** — stubbed AMQP lifecycle with a TODO for a real client.
  Test code and future integration code can deliver bytes through
  `{:deliver_test_message, body}`. Each payload is JSON (use `Jason` in production
  code paths) carrying at least `"process_model_id"` and optional `"payload"`.
- **`OrchestratorMetricsSink`** — counts orchestrator dispatches and process
  instance notifications separately.
- **`OrchestratorCustomEvent`** — plain struct passed to `publish_event/1` so sinks
  can react without extending `EvilEngine.Types.Event.*`.

`bpmn/orchestrated_process.bpmn` is a minimal **Start → echo ServiceTask → End**
diagram you can deploy before firing queue messages whose `process_model_id`
matches `orchestrated-process`.

## Further reading

- Plugin lifecycle, registration, and facade fields: [`docs/architecture/plugins.md`](../../../../docs/architecture/plugins.md)
- EngineEventBus semantics and sinks: [`docs/architecture/event-system.md`](../../../../docs/architecture/event-system.md)

## Tests

Run from the umbrella root (after wiring `Code.require_file/1` or equivalent so
example modules compile in your test Mix project):

```bash
mix test examples/plugins/combined/rabbitmq_to_engine/test/rabbitmq_orchestrator_test.exs
```

(If Mix does not pick up that path, mirror the pattern in
`test/integration/auth/example_auth_providers_test.exs`.)
