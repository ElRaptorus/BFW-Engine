# BPMN parser example (`parse-bpmn`)

Demonstrates `@elraptorus/daemonengine_sdk` `parseBpmn` on a moderately complex BPMN file. No running engine is required.

## Run

From the repository root:

```bash
cd packages/js
pnpm install
pnpm --filter @elraptorus/daemonengine_sdk run build
pnpm --filter @daemonengine/example-sdk-parse-bpmn run start
```

Run tests:

```bash
pnpm --filter @daemonengine/example-sdk-parse-bpmn run test
```

## Expected output

A text tree listing global message/signal/error definitions, the executable process (`evil:version`, `evil:correlationKey`), each flow node with type-specific fields (including service task `implementation` and handler-specific extensions in `serviceTaskTypeConfig`), and sequence flows with conditions where present.
