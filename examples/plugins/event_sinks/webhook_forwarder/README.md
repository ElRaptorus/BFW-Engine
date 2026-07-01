# Webhook forwarder — example event sink

Forwards `EvilEngine.Types.Event.*` structs to a single HTTP endpoint as JSON.
Use this as a starting point for Zapier, n8n, or your own automation receiver.

## Usage

1. Copy `lib/webhook_plugin.ex` and `lib/webhook_sink.ex` into your OTP application.
2. Replace the placeholder `url` in `WebhookPlugin.on_load/1` with your HTTPS endpoint
   (or read it from `Application.get_env/3`).
3. Replace `default_deliver_payload/3` in `WebhookSink` with a real client.

## Configuration

| Option | Description |
|--------|-------------|
| `url` | Recipient URL (required). |
| `headers` | Request headers (default `[{"content-type", "application/json"}]`). |
| `filter_types` | Optional list of allowed `event.__struct__` modules; `nil` or `[]` means accept all. |
| `deliver_payload` | Optional `fn url, headers, json_body -> :ok end` for tests. |

## Crash isolation

Each sink runs inside a dedicated supervised worker (`EvilEngine.Events.SinkWorker`). If
`handle_event/2` raises, the worker is restarted, other sinks keep running, and the bus emits
`%EvilEngine.Types.Event.SinkFailed{}` for observability. Your webhook endpoint should be
idempotent when possible so retries remain safe.

## Further reading

- [`EvilEngine.Plugin.EventSink`](../../../../apps/engine_sdk/lib/evil_engine/plugin/event_sink.ex)
- [`docs/architecture/event-system.md`](../../../../docs/architecture/event-system.md)
