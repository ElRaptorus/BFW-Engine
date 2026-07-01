# Implementing REST API Extensions

REST API Extensions allow plugins to mount additional HTTP routes under a configured prefix on the engine's web server.

## Behaviour

```elixir
@behaviour EvilEngine.Plugin.RestApiExtension

@callback router_module() :: module()
```

The `router_module/0` callback returns the Phoenix Router module that defines the plugin's routes.

## Registration

```elixir
def on_load(facade) do
  facade.register_rest_api_extension.("/my-extension", MyPlugin.Router)
  :ok
end
```

Routes defined in `MyPlugin.Router` will be accessible under `/my-extension/...`.

## Status

This is a stub behaviour planned for full implementation in Phase 4. The registration mechanism and route mounting infrastructure are defined but not fully wired.

## Related

- [Getting Started](getting-started.md) -- plugin lifecycle
- [Engine Facade Reference](engine-facade.md) -- registration API
