# Echo RestApiExtension

Minimal in-tree plugin that mounts `GET /echo-ext/ping`.

## Behaviour

The handler is a **Plug** (`call/2`). JWT is already resolved; `conn.assigns.identity` is set. The engine does not apply `deploy_bpmn` or other engine claims.

## Registration

```elixir
def on_load(facade) do
  facade.register_rest_api_extension.("/echo-ext", Examples.Plugins.RestApiExtension.EchoPlug)
  :ok
end
```

With a valid JWT:

```
GET /echo-ext/ping
→ 200 {"pong":true,"identityId":"<sub>"}
```

Without a JWT: **401**.

Plugin routes are not listed in OpenAPI (`spec.yaml`) — they are unknown at spec-author time.

Reserved prefixes such as `/processes` are rejected at registration (`{:error, :reserved_prefix}`).
