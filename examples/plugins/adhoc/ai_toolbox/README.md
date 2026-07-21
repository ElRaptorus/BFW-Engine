# AI Agent Toolbox — Ad-hoc Sub-Process Example Plugin

Demonstrates **plugin-managed** Ad-hoc Sub-Process control via
`EvilEngine.EngineFacade.adhoc_subprocesses`. Copy this plugin into an OTP
application that already depends on `engine_sdk` (for `EvilEngine.Plugin`
and `EvilEngine.Plugin.EventSink`) and `core_types` (for `EvilEngine.Types.Event`).

## Scenario

The bundled BPMN (`bpmn/ai_toolbox_process.bpmn`) models an AI agent handling a
customer inquiry. The Ad-hoc Sub-Process `AdHocSubprocess_Toolbox` carries
`implementation="ai-toolbox"` (plugin-managed mode, no `evil:ordering`
override — defaults to `Parallel`) and offers five tools as inner tasks, none
connected by sequence flow (all free-standing, all enabled from the start):

| Tool | Purpose |
|------|---------|
| `LookupOrder` | Look up the customer's order |
| `CheckInventory` | Check stock for a requested item |
| `CreateTicket` | Open a support ticket |
| `SendEmail` | Send a confirmation email |
| `EscalateToHuman` | Hand off to a human agent |

Because the sub-process is plugin-managed, the engine does **not** decide
which tool runs next — it exposes the enabled/performed state via the facade
and waits for the plugin to call `activate_activity` and eventually
`complete`.

## How it works

1. `AiToolboxPlugin.on_load/1` registers `AiToolboxSink` as an event sink
   (`facade.register_event_sink.("ai-toolbox", AiToolboxSink, facade: facade)`).
2. `AiToolboxSink` accepts three event types:
   - `SubProcessChildStarted` with `is_ad_hoc_subprocess: true` — a new
     ad-hoc scope has started. The sink calls `get_enabled_activities/1`,
     picks the highest-priority untried tool (`@tool_priority`), and calls
     `activate_activity/2`.
   - `FlowNodeInstanceFinished` with `terminal_state: :finished` for a flow
     node inside a tracked ad-hoc scope — one tool finished. The sink decides
     whether to stop (`EscalateToHuman` ran, or 3 tools have run) or pick and
     activate the next tool.
   - `AdHocSubProcessCompleted` — the scope finished (via `complete/1` or
     because no eligible tool remained); the sink forgets that scope.
3. When the sink decides the inquiry is resolved, it calls
   `complete/1` — the engine stops accepting new activations and finishes the
   Ad-hoc Sub-Process once any in-flight activity drains (governed by
   `cancelRemainingInstances` on the `bpmn:adHocSubProcess` element).

## Key facade calls

```elixir
{:ok, activities} = facade.adhoc_subprocesses.get_enabled_activities.(child_process_instance_id)
# [%{id: "LookupOrder", name: "Look Up Order", type: "task", enabled: true, performed_count: 0, active_count: 0}, ...]

{:ok, %{flow_node_instance_id: fni_id}} =
  facade.adhoc_subprocesses.activate_activity.(child_process_instance_id, "LookupOrder")

:ok = facade.adhoc_subprocesses.complete.(child_process_instance_id)

{:ok, status} = facade.adhoc_subprocesses.get_status.(child_process_instance_id)
# %{active_count: 0, performed_activities: [...], enabled_activities: [...], completion_signaled: true}
```

All four closures take the **ad-hoc scope's own process instance ID** — the
child PI spawned by the `AdHocSubProcess` handler — never the parent PI or
the shell flow node instance ID. `SubProcessChildStarted.child_process_instance_id`
and every subsequent `AdHocActivityActivated` / `AdHocSubProcessCompleted` /
`FlowNodeInstanceFinished` event's `process_instance_id` all refer to that
same child PI, so no separate ID lookup is needed once the scope has started.

## Running the demo

This plugin only wires an event sink — it takes no action on its own. To see
it work, deploy `bpmn/ai_toolbox_process.bpmn` and start an instance through
any normal entry point (REST, plugin facade, or the Studio). The sink reacts
as soon as the Ad-hoc Sub-Process's child PI starts.

## Adapting this example

- **Different selection strategy:** replace `choose_next_tool/2`'s static
  priority list with a call into an actual LLM/reasoning service, using the
  `AdHocActivity.name` and `type` fields to build a prompt.
  `LookupOrder` may run more than once with different arguments — the
  ad-hoc contract allows repeated activation of the same inner activity
  (each call creates a new flow node instance); this example intentionally
  excludes already-performed tools for simplicity, but a real agent could
  track distinct invocation arguments in the FNI's initial payload instead.
- **Sequential ordering:** if the modeled sub-process uses
  `ordering="Sequential"`, the engine itself will reject a second
  `activate_activity` call while one is still active
  (`{:error, :adhoc_sequential_busy}`) — the plugin does not need to enforce
  this itself, but should treat that error as "wait for
  `FlowNodeInstanceFinished`" rather than a fatal condition. A call after
  `complete/1` has already been signaled returns `{:error, :adhoc_already_completing}`.
- **Human-in-the-loop:** swap the sink's automatic decisions for a REST
  endpoint or user task that calls `facade.adhoc_subprocesses.activate_activity`
  based on operator input (see the "Repair Workshop" example in
  `docs/guides/handbook/adhoc-subprocesses.md` §2.2).
