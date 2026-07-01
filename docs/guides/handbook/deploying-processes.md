# Deploying Processes

This guide covers how to deploy BPMN process definitions to the engine, manage versions, and configure deploy-time quality gates.

## The `evil:version` Requirement

Every executable BPMN process must include the `<evil:version>` extension element. The engine rejects any process without it:

```xml
<bpmn:process id="order_process" isExecutable="true">
  <bpmn:extensionElements>
    <evil:version>2.1.0</evil:version>
  </bpmn:extensionElements>
  <!-- flow nodes and flows -->
</bpmn:process>
```

## Deploying via REST

Deploy one or more BPMN definitions in a single atomic batch by sending a JSON body with a `sources` array:

```bash
# Single file
curl -X POST http://localhost:4000/processes \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"sources": ["'"$(cat order_process.bpmn)"'"]}'

# Multiple files
curl -X POST http://localhost:4000/processes \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"sources": ["'"$(cat order_process.bpmn)"'", "'"$(cat payment_process.bpmn)"'"]}'
```

On success, the engine returns `201` with details for each deployed version. All sources in a batch are validated together — if any source fails, the entire batch is rejected.

| Status | Meaning |
|--------|---------|
| `201` | Deployed successfully |
| `400` | Missing or invalid `sources` array, or XML parse error |
| `401` | Missing or invalid JWT |
| `413` | Request body exceeds size limit |
| `422` | Validation failed (missing `evil:version`, structural errors, or linter gate rejection) |

For the complete endpoint specification, see [REST API Reference](../api/rest-reference.md).

## Version Management

Each deploy creates a new `process_version` row. The engine always resolves to the **latest non-deleted** version when starting a process instance.

### Delete a Version

```bash
curl -X DELETE http://localhost:4000/processes/order_process/versions/2.1.0 \
  -H "Authorization: Bearer $TOKEN"
```

Returns `204 No Content` on success. Deleted versions no longer participate in version resolution. Already-running PIs on a deleted version continue unaffected.

### Undeploy a Process

```bash
curl -X DELETE http://localhost:4000/processes/order_process \
  -H "Authorization: Bearer $TOKEN"
```

Deletes all versions of a process, effectively undeploying it. Returns `204 No Content` on success. Returns `404` for unknown or already-undeployed processes.

### Enable / Disable a Process

```bash
# Disable — new PIs cannot be started
curl -X PUT http://localhost:4000/processes/order_process/disable \
  -H "Authorization: Bearer $TOKEN"

# Enable
curl -X PUT http://localhost:4000/processes/order_process/enable \
  -H "Authorization: Bearer $TOKEN"
```

Both return `204 No Content` on success. Starting a PI on a disabled process returns `403`.

### `isExecutable` Sync on Deploy

On every deployment, the engine synchronizes the process `enabled` flag with the BPMN `isExecutable` attribute:

- `isExecutable="true"` → process is enabled (even if it was previously disabled)
- `isExecutable="false"` → process is disabled (new starts return `403`)

This means an operator can manually override via `PUT /enable` or `PUT /disable`, but the next deployment will reset `enabled` to match the BPMN's `isExecutable` flag.

## Seeding Directory

For automated deployments at startup, set `EVIL_SEEDING_DIRECTORY` to a filesystem path containing `.bpmn` files. The engine deploys them exactly like `POST /processes` calls during boot. Failing files are skipped without halting startup.

## Linter Gate

An optional deploy-time quality gate checks linter scores embedded in the BPMN XML by external tools (e.g., Evil Studio's linter extension). Configure via `EVIL_LINTER_GATE`:

```bash
EVIL_LINTER_GATE='[{"rulesetId":"bpmn-production-ready","minScorePercent":100,"maxErrors":0}]'
```

When a BPMN file fails the gate, the deploy returns `422` with structured failure details. See [Deployment](../operations/deployment.md) for full configuration options.

The gate can be disabled for seeding-directory deploys only via `EVIL_LINTER_GATE_SKIP_SEEDING=true`.

## Related

- [Starting Process Instances](starting-instances.md) -- run a deployed process
- [REST API Reference](../api/rest-reference.md) -- complete endpoint documentation
- [Authentication](../api/authentication.md) -- JWT requirements for deploy operations
