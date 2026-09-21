# Error class reference (`error-hierarchy`)

Instantiates each `@elraptorus/bfw_engine_sdk` HTTP-mapping error class, prints status codes and notable fields, and shows `instanceof` patterns plus a small `mapBfwEngineError` helper. No running engine is required.

## Run

```bash
cd packages/js
pnpm install
pnpm --filter @elraptorus/bfw_engine_sdk run build
pnpm --filter @bfw-engine/example-sdk-error-hierarchy run start
pnpm --filter @bfw-engine/example-sdk-error-hierarchy run test
```

## Expected output

A reference tree (all SDK errors extend `BfwEngineError` directly), one section per class with `statusCode` / `errorCode` / `message` / extra properties, an `instanceof` demonstration, and a sample `mapBfwEngineError` line for an `UnauthorizedError`.
