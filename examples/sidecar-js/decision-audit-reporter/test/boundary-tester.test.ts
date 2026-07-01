import { describe, expect, it, vi } from 'vitest';

import { BoundaryTester } from '../src/boundary-tester.js';
import type { SidecarPlugin } from '../src/types.js';

describe('BoundaryTester', () => {
  it('evaluates decision with inputs via mocked plugin and records success results', async () => {
    const evaluateDecision = vi.fn(async (_modelId: string, input: Record<string, unknown>) => ({
      result: { tier: 'gold' },
      matchedRules: [{ rule_id: 'rule_2' }],
    }));

    const plugin: SidecarPlugin = {
      connect: async () => {},
      register: async () => {},
      onEvent: () => {},
      evaluateDecision,
      getFlowNodeInstance: async () => null,
      disconnect: async () => {},
    };

    const tester = new BoundaryTester(plugin);
    const results = await tester.testAll([
      {
        decisionRef: 'employee-benefits',
        boundaryInputs: [
          {
            testCase: 'gold_outstanding',
            input: {
              yearsOfService: 12,
              department: 'sales',
              performanceRating: 'outstanding',
              employeeType: 'full_time',
            },
          },
        ],
      },
    ]);

    const modelResults = results.get('employee-benefits');
    expect(modelResults).toHaveLength(1);
    expect(modelResults![0]).toEqual({
      testCase: 'gold_outstanding',
      input: {
        yearsOfService: 12,
        department: 'sales',
        performanceRating: 'outstanding',
        employeeType: 'full_time',
      },
      result: { tier: 'gold' },
      error: null,
    });
    expect(evaluateDecision).toHaveBeenCalledWith(
      'employee-benefits',
      modelResults![0].input,
    );
  });

  it('records error results when evaluation fails', async () => {
    const plugin: SidecarPlugin = {
      connect: async () => {},
      register: async () => {},
      onEvent: () => {},
      evaluateDecision: vi.fn(async () => {
        throw new Error('dmn_evaluation_error');
      }),
      getFlowNodeInstance: async () => null,
      disconnect: async () => {},
    };

    const tester = new BoundaryTester(plugin);
    const results = await tester.testAll([
      {
        decisionRef: 'employee-benefits',
        boundaryInputs: [
          { testCase: 'invalid_input', input: { yearsOfService: -1 } },
        ],
      },
    ]);

    const modelResults = results.get('employee-benefits');
    expect(modelResults![0].result).toBeNull();
    expect(modelResults![0].error).toBe('Error: dmn_evaluation_error');
  });
});
