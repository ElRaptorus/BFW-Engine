defmodule EvilEngine.Plugin.NamedScript do
  @moduledoc """
  Behaviour for plugin-provided script handlers dispatched via `evil:scriptRef`.

  A named script is registered with the Plugin Registry under the
  `:named_script` capability type. The descriptor must include a
  `script_key` that matches the `evil:scriptRef` value in BPMN XML
  and a `module` implementing this behaviour.

  ## Registration

      facade.register_named_script.("my_validation", MyPlugin.CustomScript)

  ## Dispatch

  When the engine encounters a `<bpmn:scriptTask>` with
  `<evil:scriptRef>my_validation</evil:scriptRef>`, it looks up the
  `:named_script` capability whose `script_key` matches and calls
  `handle_enter/3` on the registered module.

  ## Why Sync-Only

  Named Scripts are always synchronous — the handler must return
  immediately. This is a deliberate design choice:

  - **Script Tasks represent engine-local computation**, not external
    delegation. Inline FEEL scripts run synchronously; Named Scripts
    are simply an extension point for computation that is too complex
    or domain-specific for FEEL.
  - **Service Tasks are the correct element for async/external work.**
    A plugin that needs to call a remote system, park the FNI, and
    wait for a callback should register as a `ServiceTaskHandler`
    on a Service Task element, not as a Named Script.
  - This boundary ensures that the BPMN task type is a reliable
    indicator of execution model: Script = local/instant,
    Service = external/async.

  ## Uniqueness

  Each `script_key` must be unique across all loaded plugins. Duplicate
  registrations are quarantined by the Registry.
  """

  @doc """
  Execute the named script.

  Receives the flow node struct (including `type_data` with
  `script_format`, `script`, etc.), the current token payload
  (post input-mapping), and the handler context.

  Must return `{:ok, result_map}` or `{:error, reason}`.
  """
  @callback handle_enter(
              flow_node :: map(),
              payload :: map(),
              context :: map()
            ) :: {:ok, map()} | {:error, term()}
end
