# Custom validator named scripts

This folder is a copy-paste starter (no `mix.exs`) showing how one `BfwEngine.Plugin` module can register several [`BfwEngine.Plugin.NamedScript`](https://github.com/ElRaptorus/BFW-Engine/blob/main/apps/engine_sdk/lib/bfw_engine/plugin/named_script.ex) handlers through `facade.register_named_script/2`.

## Behaviour

Process modelling references each handler with `<bfw:scriptRef>...</bfw:scriptRef>` on a `<bpmn:scriptTask>`. The engine resolves the key, calls `handle_enter/3`, and expects an immediate `{:ok, map()}` or `{:error, term()}`. There is no async parking.

## Layout

| module | script key |
|--------|------------|
| `Examples.Plugins.CustomValidators.Scripts.PayloadValidator` | `validate_payload` |
| `Examples.Plugins.CustomValidators.Scripts.CurrencyConverter` | `convert_currency` |
| `Examples.Plugins.CustomValidators.Scripts.IdempotencyGuard` | `idempotency_guard` |

`idempotency_guard` follows `convert_currency` in `bpmn/scripted_process.bpmn` (Start → validate → convert → idempotency guard → End).

## BPMN

See `bpmn/scripted_process.bpmn` for a linear Start → validate → convert → End flow.

## Docs

- Lifecycle and registration: [Plugin Development — Getting Started](https://github.com/ElRaptorus/BFW-Engine/blob/main/docs/guides/plugins/getting-started.md)
- Named scripts in the architecture reference: [plugins.md — NamedScript](https://github.com/ElRaptorus/BFW-Engine/blob/main/docs/architecture/plugins.md)
- Cheat sheet: [plugin-behaviours.cheatmd](https://github.com/ElRaptorus/BFW-Engine/blob/main/docs/guides/cheatsheets/plugin-behaviours.cheatmd)

## Tests

Add this directory as a path dependency (or copy the modules into your plugin OTP app), then run `mix test` from that app. `test/validators_test.exs` exercises the pure script modules without a running engine.
