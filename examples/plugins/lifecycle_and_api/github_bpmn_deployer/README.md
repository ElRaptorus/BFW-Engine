# GitHub BPMN deployer plugin (auto-deploy from repository)

An in-BEAM plugin that fetches `.bpmn` files from a GitHub repository and deploys them to the engine at startup. Designed for SysAdmins who maintain BPMN process definitions in a Git repository and want the engine to self-provision on boot.

## How it works

```
Engine boots
  └─ on_load:  validate env vars, stash facade
  └─ on_ready: start worker GenServer
       ├─ GitHub Contents API → list .bpmn files
       ├─ Download each file (raw content)
       ├─ EvilEngine.BPMN.parse_and_validate/1
       ├─ facade.processes.deploy.(batch)
       └─ Log summary, self-terminate
```

The worker runs exactly once and stops — no polling, no file watchers. Restarting the engine re-triggers the deploy. Already-deployed versions are handled idempotently (the engine returns `{:error, :version_exists, conflicts}` and the plugin logs a notice).

## Environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `GITHUB_BPMN_REPO_OWNER` | yes | — | Repository owner or organisation (e.g. `acme-corp`) |
| `GITHUB_BPMN_REPO_NAME` | yes | — | Repository name (e.g. `bpmn-definitions`) |
| `GITHUB_ACCESS_TOKEN` | yes | — | Personal access token (`repo` scope for private repos, `public_repo` for public) |
| `GITHUB_BPMN_BRANCH` | no | `main` | Branch to read from |
| `GITHUB_BPMN_PATH` | no | *(root)* | Subdirectory inside the repo containing `.bpmn` files |
| `GITHUB_API_BASE_URL` | no | `https://api.github.com` | API base URL (set for GitHub Enterprise) |

## Modules

| File | Responsibility |
|------|----------------|
| [`lib/github_bpmn_deployer_plugin.ex`](lib/github_bpmn_deployer_plugin.ex) | `on_load/1` validates config + stashes facade; `on_ready/1` starts the worker |
| [`lib/github_bpmn_deployer_worker.ex`](lib/github_bpmn_deployer_worker.ex) | GenServer running the fetch → parse → deploy pipeline |
| [`lib/github_client.ex`](lib/github_client.ex) | Thin HTTP wrapper around the GitHub Contents API (uses `:httpc`) |
| [`lib/facade_store.ex`](lib/facade_store.ex) | Agent-backed facade stash |

## Dependencies

The plugin calls `EvilEngine.BPMN.parse_and_validate/1`, so the hosting OTP app must depend on `core_bpmn` in addition to `engine_sdk`. The HTTP client uses Erlang's built-in `:httpc` — no external HTTP library required.

## Integration

1. Copy the `lib/` files into your own OTP application
2. Add to your `mix.exs`:

```elixir
def application do
  [
    extra_applications: [:logger, :inets, :ssl],
    env: [plugin_module: YourApp.GithubBpmnDeployerPlugin]
  ]
end

defp deps do
  [
    {:engine_sdk, path: "../engine_sdk"},
    {:core_bpmn, path: "../core_bpmn"}
  ]
end
```

3. Set the required environment variables
4. Add your OTP app name to `TDE_PLUGINS_INBEAM`

## Example: repository layout

```
acme-corp/bpmn-definitions (GitHub)
├── processes/
│   ├── order-process.bpmn
│   ├── invoice-workflow.bpmn
│   └── onboarding.bpmn
└── README.md
```

With `GITHUB_BPMN_PATH=processes`, the plugin discovers and deploys all three `.bpmn` files.

## Tests

`test/github_bpmn_deployer_worker_test.exs` uses injected stub modules for the GitHub client — no network calls, no live engine needed. Copy the tree into an umbrella app before running `mix test`.

## Limitations

- **Flat directory only**: the plugin lists files in the configured path but does not recurse into subdirectories. Nested layouts require multiple plugin instances or a wrapper that flattens the tree.
- **No incremental sync**: every engine restart re-deploys the full set. The engine's version-exists guard prevents duplicates, so this is safe but not bandwidth-optimal for large repositories.
- **No webhook trigger**: this is a pull-on-startup model. For push-based deploys (GitHub webhook → engine), pair with a REST API extension plugin or an external CI pipeline calling the engine's deploy endpoint.
