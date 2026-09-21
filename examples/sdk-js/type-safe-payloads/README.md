# Typed REST payloads (`type-safe-payloads`)

Builds representative `StartRequest`, user-task, and deploy-related object shapes using SDK types and enums. No running engine is required.

## Run

```bash
cd packages/js
pnpm install
pnpm --filter @elraptorus/bfw_engine_sdk run build
pnpm --filter @bfw-engine/example-sdk-type-safe-payloads run start
pnpm --filter @bfw-engine/example-sdk-type-safe-payloads run test
```

## Expected output

Formatted JSON for each payload plus enum examples. Commented-out lines in `src/main.ts` illustrate constructs that fail the TypeScript compiler.
