# Business Rule Task Trace Example

Demonstrates deploying matching DMN and BPMN artifacts, starting a process
whose Business Rule Task evaluates a decision table, and reading
`typeProperties` from the completed Business Rule Task flow node instance
via the typed GraphQL client.

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

1. Deploys the discount DMN definitions used by the process
2. Deploys a minimal BPMN process with `implementation="dmn"` on the Business Rule Task
3. Starts the process with `customerType` and `orderTotal` on the start payload
4. Queries flow node instances filtered to `business_rule_task` and prints state and `typeProperties` (where decision trace metadata is exposed)

The DMN file must remain in sync with `evil:decisionRef` on the Business Rule Task.
