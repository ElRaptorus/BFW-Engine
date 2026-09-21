# Implementing REST API Extensions

REST API Extensions allow plugins to mount additional HTTP routes under a configured prefix on the engine's web server.

JWT is resolved and `conn.assigns.identity` is set **after** a plugin prefix matches. Unknown paths return 404 without requiring a token. **Engine claim policy is not applied** — plugins enforce their own rules from `Identity.claims`.

Plugin routes are **not** included in the OpenAPI spec. They are unknown at spec-author time.

## Behaviour

The registered handler is a **Plug** (`call/2`). A Phoenix router qualifies because it implements Plug.

```elixir
@behaviour Plug
@behaviour BfwEngine.Plugin.RestApiExtension

@callback call(Plug.Conn.t(), Plug.opts()) :: Plug.Conn.t()

# Optional. Defaults to the implementing module.
@callback router_module() :: module()
```

## Registration

```elixir
def on_load(facade) do
  facade.register_rest_api_extension.("/my-extension", MyPlugin.Router)
  :ok
end
```

Routes on `MyPlugin.Router` are reachable under `/my-extension/...` after the engine strips the matched prefix from `path_info`.

Reserved prefixes (`/processes`, `/decisions`, `/process-instances`, `/user-tasks`, `/timer-schedules`, `/timer-events`, `/messages`, `/signals`, `/escalations`, `/adhoc-subprocesses`, `/stats`, `/api`, `/admin`, `/health`, `/info`, `/metrics`) are rejected with `{:error, :reserved_prefix}`. Engine routes always win over the plugin catch-all.

See `examples/plugins/rest_api_extension/echo/` for a `GET /echo-ext/ping` example. See `examples/plugins/event_sinks/sse/` for `GET /events/stream` (prefix `/events` is not reserved).

## Related

- [Getting Started](getting-started.md) -- plugin lifecycle
- [Engine Facade Reference](engine-facade.md) -- registration API
