# graphql-queries

Runs several typed GraphQL list and get calls against an engine that already has data deployed elsewhere: field selection, sorting, filtering, offset pagination, cursor pagination, and a short offset walk.

## Prerequisites

- Engine with `/api/v1/graphql` available.
- Useful output assumes at least some process models or instances exist; empty lists are still valid.

## Run

```bash
pnpm --filter @daemonengine/example-graphql-queries start
```

## Expected output

Formatted JSON for each query plus a few pagination progress lines.

## Test

Vitest placeholder only.
