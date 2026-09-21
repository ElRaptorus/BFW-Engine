# BPMN parser example (`parse-bpmn`)

Demonstrates `@elraptorus/bfw_engine_sdk` `parseBpmn` on a moderately complex BPMN file. No running engine is required.

## Run

From the repository root:

```bash
cd packages/js
pnpm install
pnpm --filter @elraptorus/bfw_engine_sdk run build
pnpm --filter @bfw-engine/example-sdk-parse-bpmn run start
```

Run tests:

```bash
pnpm --filter @bfw-engine/example-sdk-parse-bpmn run test
```

## Expected output

A text tree listing global message/signal/error definitions, the executable process (`bfw:version`, `bfw:correlationKey`), each flow node with type-specific fields (including service task `implementation` and the typed HTTP handler fields such as `httpUrl` and `httpMethod`), and sequence flows with conditions where present.
