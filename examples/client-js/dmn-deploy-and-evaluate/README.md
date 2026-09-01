# DMN Deploy and Evaluate Example

Demonstrates using the `@elraptorus/daemonengine_client` to deploy a DMN decision
table to the engine and evaluate it with different inputs.

## Prerequisites

- Node.js 24.20+
- pnpm
- A running ThomasTheDaemonEngine instance with DMN support (Phase 3+)

## Usage

```bash
export ENGINE_URL=http://localhost:4000
export ENGINE_TOKEN=your-jwt-token
pnpm install
pnpm start
```

## What it does

1. Deploys a discount rules DMN decision table
2. Evaluates with a "gold" customer (high order) → expects 20% discount
3. Evaluates with a "silver" customer, requesting the full execution trace
4. Undeploys the decision definition
