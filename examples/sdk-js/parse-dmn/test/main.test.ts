import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import { DmnDecisionTable, DmnHitPolicy, parseDmn } from '@elraptorus/daemonengine_sdk';

describe('parse-dmn example', () => {
  const decisionModelFilePath = resolve(import.meta.dirname, '../dmn/sample.dmn');
  const dmnXml = readFileSync(decisionModelFilePath, 'utf8');
  const definitions = parseDmn(dmnXml);

  it('parses the definitions', () => {
    expect(definitions.id).toBe('definitions_discount');
    expect(definitions.name).toBe('Discount Rules');
  });

  it('contains one decision', () => {
    expect(definitions.decisions).toHaveLength(1);
    expect(definitions.decisions[0]!.name).toBe('Discount Percentage');
  });

  it('has UNIQUE hit policy', () => {
    const table = definitions.decisions[0]!.expression as DmnDecisionTable;
    expect(table.hitPolicy).toBe(DmnHitPolicy.Unique);
  });

  it('has 2 inputs and 1 output', () => {
    const table = definitions.decisions[0]!.expression as DmnDecisionTable;
    expect(table.inputs).toHaveLength(2);
    expect(table.outputs).toHaveLength(1);
  });

  it('has 4 rules', () => {
    const table = definitions.decisions[0]!.expression as DmnDecisionTable;
    expect(table.rules).toHaveLength(4);
  });
});
