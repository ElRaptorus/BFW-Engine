# Local script runner (`local_script`)

This starter wires [`BfwEngine.Plugin.NamedScript`](https://github.com/ElRaptorus/BFW-Engine/blob/main/apps/engine_sdk/lib/bfw_engine/plugin/named_script.ex) to files on the operator’s machine. The BPMN carries the relative path in the standard `<bpmn:script>` body while `<bfw:scriptRef>local_script</bfw:scriptRef>` selects this handler.

Companion BPMN: `bpmn/scripted_file_process.bpmn`. Sample payloads live under `scripts/`.

## Security (read this first)

1. **Script safety is the operator’s responsibility** — anything placed in the scripts directory is executed with the engine’s OS privileges. Review, version, and deploy scripts like application code.
2. **The engine survives bad scripts** — malformed output, timeouts, and non-zero exit codes surface as `{:error, _}` to the Script Task handler; the FNI transitions `:fatal` while the engine keeps running (see [script-tasks.md](https://github.com/ElRaptorus/BFW-Engine/blob/main/docs/guides/handbook/script-tasks.md)).
3. **Restrict `allowed_scripts_directory`** — pass `allowed_scripts_directory:` to `ScriptSandbox.execute/3` (or configure `Application.put_env(:local_script_runner_example, :allowed_scripts_directory, ...)`) so only one audited tree is reachable.
4. **Never interpolate unsanitized payload fields into shell strings** — `ScriptSandbox` sends JSON on stdin only; keep subprocess arguments limited to vetted paths and interpreter flags.
5. **Build an audit trail** — log `script_path`, start timestamp, duration, exit status, and `flow_node_instance_id` from `context.flow_node_instance_id` (available in full engine runs) alongside stderr/stdout excerpts for troubleshooting.

## Dependencies

Copy the modules into an OTP app that already depends on `engine_sdk` **and** add [`:jason`](https://hex.pm/packages/jason) to `deps/0` because `ScriptSandbox` encodes/decodes JSON.

## Configuration

| `Application` env tuple | Purpose |
|-------------------------|---------|
| `{:local_script_runner_example, :allowed_scripts_directory}` | Base path for resolving relative script paths (default `./scripts` under `File.cwd!/0`) |
| `{:local_script_runner_example, :timeout_milliseconds}` | Kill hung interpreters after this many milliseconds (default `30_000`) |

## Behaviour source

- [`ScriptSandbox`](../../shared/script_sandbox.ex) — path validation and JSON-stdin execution (`python3` / `node` / `bash`)
- [`ScriptRunner`](lib/script_runner.ex) — reads `type_data.script` / `type_data["script"]`

## Tests

Run from an app that compiles these modules: `mix test test/script_runner_test.exs`. Python is required for the happy-path test; Bash for the failure-path test.

## Further reading

- [`BfwEngine.EngineFacade`](https://github.com/ElRaptorus/BFW-Engine/blob/main/apps/engine_sdk/lib/bfw_engine/engine_facade.ex)
- [plugins architecture](https://github.com/ElRaptorus/BFW-Engine/blob/main/docs/architecture/plugins.md)
