# Parse DMN Example

Demonstrates using the `@elraptorus/daemonengine_sdk` to parse DMN XML into a typed
decision table model. No running engine required.

## Prerequisites

- Node.js 24.20+
- pnpm

## Usage

```bash
pnpm install
pnpm start
```

## Test

```bash
pnpm test
```

## What it does

1. Reads a DMN XML file (`dmn/sample.dmn`) containing a discount rules table
2. Parses it with `parseDmn(xml)` into a typed `DmnDefinitions` model
3. Prints the decision structure: decisions, hit policy, inputs, outputs, rules
