# Structured JSON logger — example event sink

Minimal newline-delimited JSON (NDJSON) writer: one `BfwEngine.Types.Event.*` record per line.
Ideal as a first sink because it avoids HTTP clients, queues, or vendor SDKs.

## Usage

1. Copy `lib/logger_plugin.ex` and `lib/logger_sink.ex` into your OTP application.
2. Choose `output: :stdout` or `output: "/var/log/engine-events.jsonl"` in `LoggerPlugin.on_load/1`.
3. Point your log shipper (Fluent Bit, Vector, promtail) at the file or process stdout.

## Where this fits

- **ELK / OpenSearch** — ingest NDJSON; map `severity` to log level and `event_type` to a facet.
- **Grafana Loki** — label streams by `event_type` or `severity`.
- **CloudWatch / vendor agents** — many accept stdout from containers and parse JSON per line.

## Configuration

| Option | Description |
|--------|-------------|
| `output` | `:stdout` or a file path string (append mode, UTF-8). |

Each line includes `timestamp` (when the line was written, UTC ISO-8601), `severity`
(`info`, `warning`, or `error`), `event_type` (dotted Elixir module name), and every field
from the event struct (strings, ISO-8601 for `DateTime`, atoms as strings).

## Further reading

- [`BfwEngine.Plugin.EventSink`](../../../../apps/engine_sdk/lib/bfw_engine/plugin/event_sink.ex)
- [`docs/architecture/event-system.md`](../../../../docs/architecture/event-system.md)
