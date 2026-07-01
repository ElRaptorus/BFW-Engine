# Script Tasks

Script Tasks evaluate an inline FEEL expression or dispatch to a plugin-registered named script. They are always synchronous — the engine evaluates the script in-line and advances the token immediately. This is the defining distinction from Service Tasks, which are always asynchronous. If your work is local, engine-internal computation, use a Script Task. If it involves external system delegation, use a [Service Task](service-tasks.md) instead.

## How It Works

1. The BPMN process defines a `<bpmn:scriptTask>` with either an inline `<script>` body or an `<evil:scriptRef>` extension element (or both — `scriptRef` wins)
2. At runtime, the engine runs the **input pipeline**: input mappers (FEEL) → payload contract (JSON Schema)
3. The engine evaluates the script:
   - If `evil:scriptRef` is set, dispatches to the registered `NamedScript` plugin handler
   - Otherwise, evaluates the `<script>` body as a FEEL expression
4. The **output pipeline** runs: output mappers (FEEL) → result contract (JSON Schema) → PayloadCap
5. The token advances to the next flow node

## Inline FEEL Script

The simplest form — write a FEEL expression directly in the `<script>` child element:

```xml
<bpmn:scriptTask id="Calc_1" name="Calculate Tax" scriptFormat="feel">
  <bpmn:script>{"taxed": token.amount * 1.19, "original": token.amount}</bpmn:script>
</bpmn:scriptTask>
```

If the FEEL expression returns a scalar value (number, string, boolean), the engine wraps it in `%{"result" => value}`. If it returns a map, the map is used as-is.

> **Note:** `scriptFormat` is optional. When set, it is stored for BPMN fidelity and passed through to plugins, but the engine always evaluates inline scripts as FEEL regardless of the attribute value.

## Plugin-Dispatched Named Script

For complex logic that cannot be expressed in FEEL, use `evil:scriptRef` to dispatch to a plugin:

```xml
<bpmn:scriptTask id="Validate_1" name="Custom Validation">
  <bpmn:extensionElements>
    <evil:scriptRef>my_validation_plugin</evil:scriptRef>
  </bpmn:extensionElements>
</bpmn:scriptTask>
```

The plugin must implement `EvilEngine.Plugin.NamedScript` and register with the matching `script_key`:

```elixir
facade.register_named_script.("my_validation_plugin", MyPlugin.CustomValidation)
```

## Data Pipeline (Mappers + Contracts)

Script Tasks support the same data pipeline as Service Tasks and User Tasks:

```xml
<bpmn:scriptTask id="Mapped_1" name="Mapped Script" scriptFormat="feel">
  <bpmn:script>{"computed": token.input_value * 3}</bpmn:script>
  <bpmn:extensionElements>
    <evil:inputMapping source="token.raw_amount" target="input_value"/>
    <evil:payloadContract>{"type":"object","required":["input_value"]}</evil:payloadContract>
    <evil:outputMapping source="token.computed" target="tripled"/>
    <evil:resultContract>{"type":"object","required":["tripled"]}</evil:resultContract>
  </bpmn:extensionElements>
</bpmn:scriptTask>
```

The full pipeline:

```
token → in_mappings (FEEL) → payload_contract (JSON Schema) → script/plugin → out_mappings (FEEL) → result_contract (JSON Schema) → PayloadCap → downstream
```

| Extension | Purpose |
|-----------|---------|
| `evil:inputMapping` | FEEL expression to transform input before script execution |
| `evil:payloadContract` | JSON Schema to validate the mapped input |
| `evil:outputMapping` | FEEL expression to transform script output |
| `evil:resultContract` | JSON Schema to validate the mapped output |

## Error Handling

All failures in the Script Task pipeline transition the FNI to `fatal`:

- **FEEL evaluation error** (corrupt script syntax) — `{:script_eval_failed, script, reason}`
- **Named script handler error** — `{:named_script_failed, script_ref, reason}`
- **Unknown script_ref** (no handler registered) — `{:no_handler_for_script_ref, script_ref}`
- **Input mapping failure** — `{:in_mapping_failed, details}`
- **Output mapping failure** — `{:out_mapping_failed, details}`
- **Contract violation** — `{:script_task_contract_violation, violations}`
- **Missing both script and scriptRef** — `{:missing_script, message}`

## scriptRef vs. Inline Script Precedence

When both `evil:scriptRef` and `<script>` are set on the same element, `scriptRef` takes precedence. This allows BPMN diagrams to carry a readable FEEL fallback while still dispatching to a plugin at runtime.

## Related

- [Service Tasks](service-tasks.md) — analogous plugin dispatch via `implementation`
- [Expressions](expressions.md) — FEEL expression language reference
- [Error Handling](error-handling.md) — fatal state transitions
- [Plugin Development](../plugins/getting-started.md) — implementing a `NamedScript` plugin
