# BfwEngine.Client

A standalone Elixir client for the [Bifrost Forge World Engine](https://github.com/ElRaptorus/BFW-Engine) — a BPMN 2.0 workflow engine. Wraps the Engine's REST, GraphQL, and WebSocket surfaces for host applications that talk to the Engine as an external service.

## Installation

### With Igniter

```sh
mix igniter.install bfw_engine_client@path:../path/to/bfw_engine_client
```

This runs `mix bfw_engine_client.install`, which:

1. Adds `config :<your_app>, <YourApp>.Engine, base_url: System.get_env("BFE_ENGINE_URL", "http://localhost:4100")` to `config/runtime.exs`.
2. Generates `lib/<your_app>/engine.ex` — `<YourApp>.Engine`, with `client/0` (service token, read from `BFE_ENGINE_TOKEN`) and `client/1` (an explicit per-user token).
3. Adds a `BfwEngine.Client.Notifications` process to your application's supervision tree, named `<YourApp>.Engine.Notifications`.

Re-running the installer changes nothing once these three things exist.

Options:

* `--base-url-env` - environment variable read for the Engine's base URL. Defaults to `BFE_ENGINE_URL`.
* `--token-env` - environment variable read for the service token. Defaults to `BFE_ENGINE_TOKEN`.

### Manual installation

Add the dependency to `mix.exs`:

```elixir
def deps do
  [
    {:bfw_engine_client, path: "../path/to/bfw_engine_client"}
  ]
end
```

Then build a client:

```elixir
client = BfwEngine.Client.new(base_url: "http://localhost:4100", token: System.get_env("BFE_ENGINE_TOKEN"))
{:ok, processes} = BfwEngine.Client.Processes.list(client)
```

## Configuration

The only configuration this library reads is what you pass to `BfwEngine.Client.new/1`:

* `:base_url` (required) - the Engine's HTTP base URL.
* `:token` - a bearer token string, or a zero-arity function called per request to resolve a fresh token.
* `:req_options` - extra options merged into every `Req.Request` built for this client (timeouts, retries, a custom Finch pool, and so on). Requests are not retried unless `:retry` is set here, matching the TypeScript client.

## Token model

The Engine distinguishes two kinds of tokens:

* **Service token** - a long-lived JWT for your application's backend to call the Engine on its own behalf (deploying processes, triggering events, running background jobs). Read from `BFE_ENGINE_TOKEN` by the generated `<YourApp>.Engine.client/0`.
* **Per-user token** - a JWT scoped to one end user (their lanes, their claims), passed explicitly per request via `<YourApp>.Engine.client/1`.

`BfwEngine.Client.Notifications` is a **process**, so it carries exactly one identity for its lifetime. If your application needs real-time events for several distinct identities at once (for example, one WebSocket subscription per logged-in user), start one `Notifications` process per identity rather than sharing a single process across users. The `:client` option accepts an MFA tuple (`{module, function, arguments}`) that is re-resolved on every connection attempt, so a token that expires and is refreshed elsewhere is always picked up fresh on reconnect.

## Modules and operations

| Module | Function | Wire operation |
|---|---|---|
| `BfwEngine.Client.Processes` | `list/1` | `GET /processes` |
| | `start/3` | `POST /processes/:model_id/start` |
| `BfwEngine.Client.ProcessInstances` | `get/2` | GraphQL `getProcessInstance` |
| | `abort/3` | `PUT /process-instances/:id/abort` |
| | `waiting_catches/3` | GraphQL `flowNodeInstances` (catch-side filter; `:limit` and `:offset`) |
| `BfwEngine.Client.UserTasks` | `list_waiting/2` | GraphQL `flowNodeInstances` (user/manual task filter; `:limit` and `:offset`) |
| | `finish/3` | `PUT /user-tasks/:id/finish` |
| | `cancel/3` | `PUT /user-tasks/:id/cancel` |
| `BfwEngine.Client.ManualTasks` | `confirm/2` | `PUT /manual-tasks/:id/confirm` |
| | `cancel/3` | `PUT /manual-tasks/:id/cancel` |
| `BfwEngine.Client.Events` | `trigger_message/3` | `POST /messages/:name/trigger` |
| | `trigger_signal/2` | `POST /signals/:name/trigger` |
| | `trigger_escalation/2` | `POST /escalations/:code/trigger` |
| | `trigger_timer/2` | `POST /timer-events/:id/trigger` |
| `BfwEngine.Client.AdhocSubprocesses` | `activities/2` | `GET /adhoc-subprocesses/:id/activities` |
| | `activate/3` | `POST /adhoc-subprocesses/:id/activities/:activity_id/activate` |
| | `complete/2` | `POST /adhoc-subprocesses/:id/complete` |
| | `status/2` | `GET /adhoc-subprocesses/:id/status` |
| `BfwEngine.Client.Graphql` | `query/3` | `POST /api/v1/graphql` (any document) |
| `BfwEngine.Client.Notifications` | `start_link/1`, `subscribe/3`, `unsubscribe/2` | `/socket/websocket` (Phoenix Channels) |

Every function that carries an HTTP or GraphQL request returns `{:ok, term()}` or `{:error, BfwEngine.Client.Error.t() | Exception.t()}`. Response bodies are decoded JSON with **string keys, exactly as on the wire** — there is no atom conversion of server data, and GraphQL filter values are plain strings (`"user_task"`, `"waiting"`), never enums.

## Errors

`BfwEngine.Client.Error` is the one exception struct every operation can return for a non-2xx HTTP response, or for a GraphQL response whose `errors[]` array is non-empty:

```elixir
%BfwEngine.Client.Error{
  status: 422,          # HTTP status, or `nil` for a GraphQL error
  code: "contract_violation",  # the raw wire error code
  reason: :contract_violation, # a fixed atom, see below
  message: "...",              # human-readable message from the Engine
  body: %{...}                 # the full decoded response body (or the GraphQL error entry)
}
```

`reason` is resolved from a compile-time table mirroring the domain error classes in the TypeScript client (`packages/js/client/src/errors/error-mapper.ts`): a known wire code (`process_disabled`, `contract_violation`, `retry_checkpoint_is_join_gateway`, `dmn_evaluation_error`, and so on) maps to a specific atom; an unrecognized code falls back to a reason derived from the HTTP status (`:bad_request`, `:unauthorized`, `:forbidden`, `:not_found`, `:conflict`, `:validation_error`, `:internal_engine_error`, `:engine_at_capacity`); anything else is `:engine_error`.

**Transport failures are not wrapped.** If the Engine cannot be reached at all (connection refused, timeout, TLS error), `{:error, exception}` carries the underlying `Req` exception unchanged, so you can tell "the Engine answered with an error" apart from "the Engine could not be reached" with a simple `case`:

```elixir
case BfwEngine.Client.Processes.start(client, "order-process") do
  {:ok, %{"processInstanceId" => id}} -> ...
  {:error, %BfwEngine.Client.Error{reason: :process_disabled}} -> ...
  {:error, %BfwEngine.Client.Error{} = error} -> ...
  {:error, exception} -> ... # a Req/Exception.t(), the Engine was unreachable
end
```

## Real-time events

Start one `BfwEngine.Client.Notifications` process per identity and subscribe to any of the Engine's Phoenix Channel topics: `"engine:events"` (everything), `"user_tasks:pending"` (the pending user-task inbox), or `"process_instance:<id>"` (one process instance's descendant events).

```elixir
{:ok, pid} =
  BfwEngine.Client.Notifications.start_link(
    client: {MyApp.Engine, :client, []}
  )

:ok = BfwEngine.Client.Notifications.subscribe(pid, "process_instance:#{process_instance_id}")

receive do
  {:bfw_engine_event, topic, %{"type" => type, "data" => data, "occurredAt" => occurred_at}} ->
    handle_event(type, data, occurred_at)
end
```

Subscriptions are reference-counted per topic: the first `subscribe/2` for a topic joins the underlying channel. Every caller that arrives while that join is still in flight waits for the same result, and the call returns `:ok` after the join succeeds or after a rejection has already been delivered to that subscriber. A subscribe of a topic that is already joined returns immediately. The last matching `unsubscribe/2` (or the subscriber process dying) leaves it. Every subscriber is monitored, so a crashed process never leaves a topic joined forever.

If the Engine rejects a join, or later closes the channel, every current subscriber for that topic receives:

```elixir
receive do
  {:bfw_engine_subscription_error, topic, reason} -> ...
end
```

On disconnect, the process automatically reconnects and rejoins every subscribed topic, re-resolving `:client` so a refreshed token is picked up. The bearer token is only ever placed in the `Authorization` header and the socket handshake's `token` query parameter — it is never logged.
