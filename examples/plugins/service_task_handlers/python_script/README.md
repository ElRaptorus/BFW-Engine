# Python Script Service Task — Example Plugin

Async Service Task that delegates work to an operator-reviewed Python script.
The engine stays in Elixir; `python3` runs as the engine OS user with JSON on
stdin and JSON on stdout.

This is **not** a Named Script. Script Tasks with `bfw:scriptRef` stay
synchronous. Other-language **work** belongs on a Service Task — compare
[`named_scripts/local_script_runner`](../../named_scripts/local_script_runner/).

## Async contract

`handle_enter/3` returns `{:async, flow_node_instance_id}`. A `Task` runs
[`Examples.Plugins.Shared.ScriptSandbox`](../../shared/script_sandbox.ex). Success
calls `finish_async` with the decoded JSON object. Timeout, non-zero exit, path
rejection, missing interpreter, or non-object JSON call `fail_async`.

Never interpolate payload fields into the shell command. The sandbox writes JSON
to a temp file and redirects stdin.

## Usage

1. Copy `lib/` plus [`examples/plugins/shared/script_sandbox.ex`](../../shared/script_sandbox.ex)
   into your OTP application.
2. Set `:plugin_module` and allowlisted scripts directory:

   ```elixir
   config :my_plugin, :plugin_module, Examples.ServiceTaskHandlers.PythonScript.PythonScriptPlugin
   config :python_script_example, :allowed_scripts_directory, "/opt/engine/scripts/python"
   config :python_script_example, :timeout_milliseconds, 30_000
   ```

3. Add your OTP app name to `BFE_PLUGINS_INBEAM`.

## BPMN dispatch

```xml
<bpmn:serviceTask id="Task_python" implementation="python_script" />
```

Default script is `echo.py`. Override with token payload `"script": "fail.py"`
(relative to the allowlisted directory).

## fail_async + error boundary

[`bpmn/fail_async_error_boundary.bpmn`](bpmn/fail_async_error_boundary.bpmn) shows
`fail_async` with code `script_failed` caught by an interrupting Error Boundary
(`errorRef` → global `<bpmn:error errorCode="script_failed">`). Start that
process with `{"script":"fail.py"}`.

## Further reading

- [Service Task Handler guide](../../../../docs/guides/plugins/service-task-handler.md)
- [`docs/architecture/plugins.md`](../../../../docs/architecture/plugins.md)
- [`BfwEngine.Plugin.ServiceTaskHandler`](../../../../apps/engine_sdk/lib/bfw_engine/plugin/service_task_handler.ex)
