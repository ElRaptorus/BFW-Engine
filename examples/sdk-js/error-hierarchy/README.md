# Error class reference (`error-hierarchy`)

Instantiates each `@elraptorus/daemonengine_sdk` HTTP-mapping error class, prints status codes and notable fields, and shows `instanceof` patterns plus a small `mapDaemonEngineError` helper. No running engine is required.

## Run

```bash
cd packages/js
pnpm install
pnpm --filter @elraptorus/daemonengine_sdk run build
pnpm --filter @daemonengine/example-sdk-error-hierarchy run start
pnpm --filter @daemonengine/example-sdk-error-hierarchy run test
```

## Expected output

A reference tree (all SDK errors extend `DaemonEngineError` directly), one section per class with `statusCode` / `errorCode` / `message` / extra properties, an `instanceof` demonstration, and a sample `mapDaemonEngineError` line for an `UnauthorizedError`.
