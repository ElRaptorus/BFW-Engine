# RabbitMQ Roundtrip Service Task — Example Plugin

Demonstrates request–reply over RabbitMQ (async-only contract): the handler
publishes with `correlation_id` equal to `flow_node_instance_id`, parks the Flow
Node Instance, and `RabbitmqConsumer` completes it when a worker sends a JSON
reply body.

## Correlation

Partners must echo the correlation id header so the consumer can call
`finish_async/2` with the right Flow Node Instance. If workers go missing, rely on
engine-level timeouts (configure separately) or add application watchdogs that call
`fail_async/3`.

## Docker one-liner

```bash
docker run --name evil-rabbit -p 5672:5672 -p 15672:15672 -d rabbitmq:3-management-alpine
```

## Further reading

- [`EvilEngine.Plugin.ServiceTaskHandler`](../../../../apps/engine_sdk/lib/evil_engine/plugin/service_task_handler.ex)
- [`docs/architecture/plugins.md`](../../../../docs/architecture/plugins.md)
