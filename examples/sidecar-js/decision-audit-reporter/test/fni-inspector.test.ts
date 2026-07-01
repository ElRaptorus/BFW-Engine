import { describe, expect, it, vi } from 'vitest';

import { FniInspector } from '../src/fni-inspector.js';
import type { SidecarPlugin } from '../src/types.js';

function createMockPlugin(
  responses: Record<string, Record<string, unknown> | null>,
): SidecarPlugin {
  return {
    connect: async () => {},
    register: async () => {},
    onEvent: () => {},
    evaluateDecision: async () => ({ result: {}, matchedRules: [] }),
    getFlowNodeInstance: vi.fn(async (fniId: string) => responses[fniId] ?? null),
    disconnect: async () => {},
  };
}

describe('FniInspector', () => {
  it('queries FNI via mocked plugin and extracts type_properties', async () => {
    const plugin = createMockPlugin({
      'fni-1': {
        typeProperties: {
          decision_ref: 'employee-benefits',
          duration_us: 2500,
          matched_rules: ['rule_1', 'rule_2'],
          trace: { decisions: [] },
        },
      },
    });

    const inspector = new FniInspector(plugin);
    const results = await inspector.fetchAll(['fni-1']);

    expect(results).toHaveLength(1);
    expect(results[0]).toEqual({
      flowNodeInstanceId: 'fni-1',
      decisionRef: 'employee-benefits',
      durationUs: 2500,
      matchedRules: ['rule_1', 'rule_2'],
      trace: { decisions: [] },
    });
  });

  it('handles not-found FNI gracefully when plugin returns null', async () => {
    const plugin = createMockPlugin({});
    const inspector = new FniInspector(plugin);
    const results = await inspector.fetchAll(['missing-fni']);

    expect(results).toEqual([]);
  });

  it('handles missing type_properties with defaults', async () => {
    const plugin = createMockPlugin({
      'fni-2': {},
    });

    const inspector = new FniInspector(plugin);
    const results = await inspector.fetchAll(['fni-2']);

    expect(results[0]).toEqual({
      flowNodeInstanceId: 'fni-2',
      decisionRef: 'unknown',
      durationUs: 0,
      matchedRules: [],
      trace: null,
    });
  });

  it('skips FNIs that throw on fetch', async () => {
    const plugin: SidecarPlugin = {
      connect: async () => {},
      register: async () => {},
      onEvent: () => {},
      evaluateDecision: async () => ({ result: {}, matchedRules: [] }),
      getFlowNodeInstance: vi.fn(async (fniId: string) => {
        if (fniId === 'fni-error') throw new Error('connection lost');
        return {
          typeProperties: { decision_ref: 'employee-benefits', duration_us: 100 },
        };
      }),
      disconnect: async () => {},
    };

    const inspector = new FniInspector(plugin);
    const results = await inspector.fetchAll(['fni-error', 'fni-ok']);

    expect(results).toHaveLength(1);
    expect(results[0].flowNodeInstanceId).toBe('fni-ok');
  });
});
