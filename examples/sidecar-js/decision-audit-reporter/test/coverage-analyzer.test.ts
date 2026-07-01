import { describe, expect, it } from 'vitest';

import { CoverageAnalyzer } from '../src/coverage-analyzer.js';
import type { FniDetails } from '../src/types.js';

const ALL_RULES = ['rule_1', 'rule_2', 'rule_3', 'rule_4', 'rule_5', 'rule_6'];

function buildFniDetails(matchedRules: string[]): FniDetails {
  return {
    flowNodeInstanceId: 'fni-1',
    decisionRef: 'employee-benefits',
    durationUs: 1000,
    matchedRules,
    trace: null,
  };
}

describe('CoverageAnalyzer', () => {
  const analyzer = new CoverageAnalyzer();

  it('computes matched vs total rules', () => {
    const result = analyzer.analyze(
      [buildFniDetails(['rule_1', 'rule_2']), buildFniDetails(['rule_2', 'rule_3'])],
      ALL_RULES,
    );

    expect(result.totalRules).toBe(6);
    expect(result.matchedRules).toBe(3);
    expect(result.coveragePercent).toBe(50);
  });

  it('identifies dead rules correctly', () => {
    const result = analyzer.analyze([buildFniDetails(['rule_1'])], ALL_RULES);

    expect(result.deadRules).toEqual(['rule_2', 'rule_3', 'rule_4', 'rule_5', 'rule_6']);
  });

  it('returns 0% coverage for empty FNI input', () => {
    const result = analyzer.analyze([], ALL_RULES);

    expect(result.matchedRules).toBe(0);
    expect(result.coveragePercent).toBe(0);
    expect(result.deadRules).toEqual(ALL_RULES);
  });

  it('returns 100% coverage when all rules are matched', () => {
    const result = analyzer.analyze(
      [
        buildFniDetails(['rule_1', 'rule_2', 'rule_3']),
        buildFniDetails(['rule_4', 'rule_5', 'rule_6']),
      ],
      ALL_RULES,
    );

    expect(result.coveragePercent).toBe(100);
    expect(result.deadRules).toEqual([]);
  });

  it('returns 0% coverage when allRuleIds is empty', () => {
    const result = analyzer.analyze([buildFniDetails(['rule_1'])], []);

    expect(result.totalRules).toBe(0);
    expect(result.coveragePercent).toBe(0);
  });
});
