# SSE Event Sink + RestApiExtension

Production-realistic plugin: consume `EvilEngine.Types.Event.*` via an EventSink
and push JSON frames to browsers/`curl` over **the engine's existing HTTP
server**. There is no second Bandit listener.

`GET /events/stream` is `text/event-stream`. JWT is required (same as
[`rest_api_extension/echo`](../../rest_api_extension/echo/)). Optional
`?severity=info|warning|error` filters frames. `?maxEvents=1` is useful in tests.

This is the cookbook proof of "Plugins Over Features": SSE/watch is not in
engine core.

## Usage

1. Copy `lib/` into your OTP application.
2. Set `:plugin_module`:

   ```elixir
   config :my_plugin, :plugin_module, Examples.EventSinks.Sse.SsePlugin
   ```

3. Add your OTP app name to `EVIL_PLUGINS_INBEAM`.

## Lifecycle

`on_load/1` registers EventSink `"sse"` and RestApiExtension prefix `/events`.
`/events` is **not** a reserved engine prefix.

## Try it

```bash
curl -N -H "Authorization: Bearer $TOKEN" "$ENGINE_URL/events/stream"
```

## Further reading

- [Event Sink guide](../../../../docs/guides/plugins/event-sink.md)
- [REST API Extension guide](../../../../docs/guides/plugins/api-extension.md)
- [`docs/architecture/event-system.md`](../../../../docs/architecture/event-system.md)
- [`docs/architecture/plugins.md`](../../../../docs/architecture/plugins.md) §9.3 — `PluginQuarantined` is delivered to this sink like any other
