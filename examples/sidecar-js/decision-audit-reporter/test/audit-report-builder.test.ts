import { describe, expect, it } from 'vitest';

import {
  AuditReportBuilder,
  DEFAULT_SLA_THRESHOLD_US,
} from '../src/audit-report-builder.js';
import type { BoundaryTestResult, FniDetails } from '../src/types.js';

const ALL_RULES = ['rule_1', 'rule_2', 'rule_3', 'rule_4', 'rule_5', 'rule_6'];

function buildFniDetails(
  overrides: Partial<FniDetails> & { matchedRules?: string[] },
): FniDetails {
  return {
    flowNodeInstanceId: 'fni-1',
    decisionRef: 'employee-benefits',
    durationUs: 50_000,
    matchedRules: ['rule_1', 'rule_2', 'rule_3', 'rule_4', 'rule_5', 'rule_6'],
    trace: null,
    ...overrides,
  };
}

describe('AuditReportBuilder', () => {
  it('assembles complete report with all sections', () => {
    const boundaryResults = new Map<string, BoundaryTestResult[]>([
      [
        'employee-benefits',
        [
          {
            testCase: 'platinum',
            input: { yearsOfService: 25 },
            result: { tier: 'platinum' },
            error: null,
          },
        ],
      ],
    ]);

    const report = AuditReportBuilder.build({
      collectionWindowMinutes: 5,
      fniDetails: [
        buildFniDetails({ flowNodeInstanceId: 'fni-1', durationUs: 40_000 }),
        buildFniDetails({ flowNodeInstanceId: 'fni-2', durationUs: 60_000 }),
      ],
      boundaryResults,
      allRuleIdsByModel: new Map([['employee-benefits', ALL_RULES]]),
    });

    expect(report.collectionWindowMinutes).toBe(5);
    expect(report.generatedAt).toMatch(/^\d{4}-\d{2}-\d{2}T/);
    expect(report.summary.totalDecisionExecutions).toBe(2);
    expect(report.summary.uniqueDecisionModels).toBe(1);
    expect(report.summary.avgLatencyUs).toBe(50_000);
    expect(report.perModel).toHaveLength(1);
    expect(report.perModel[0].decisionRef).toBe('employee-benefits');
    expect(report.perModel[0].executionCount).toBe(2);
    expect(report.perModel[0].ruleCoverage.coveragePercent).toBe(100);
    expect(report.perModel[0].boundaryTestResults).toHaveLength(1);
    expect(report.compliance).toBeDefined();
  });

  it('computes compliance flags correctly', () => {
    const passingReport = AuditReportBuilder.build({
      collectionWindowMinutes: 1,
      fniDetails: [buildFniDetails({ durationUs: 10_000 })],
      boundaryResults: new Map(),
      allRuleIdsByModel: new Map([['employee-benefits', ALL_RULES]]),
      slaThresholdUs: DEFAULT_SLA_THRESHOLD_US,
    });

    expect(passingReport.compliance.allModelsEvaluated).toBe(true);
    expect(passingReport.compliance.noDeadRulesFound).toBe(true);
    expect(passingReport.compliance.latencyWithinSla).toBe(true);

    const failingReport = AuditReportBuilder.build({
      collectionWindowMinutes: 1,
      fniDetails: [
        buildFniDetails({
          durationUs: 200_000,
          matchedRules: ['rule_1'],
        }),
      ],
      boundaryResults: new Map([
        [
          'employee-benefits',
          [
            {
              testCase: 'bad',
              input: {},
              result: null,
              error: 'Error: failed',
            },
          ],
        ],
      ]),
      allRuleIdsByModel: new Map([['employee-benefits', ALL_RULES]]),
    });

    expect(failingReport.compliance.noDeadRulesFound).toBe(false);
    expect(failingReport.compliance.latencyWithinSla).toBe(false);
    expect(failingReport.summary.errorRate).toBe(1);
  });

  it('produces valid report with zero counts for empty data', () => {
    const report = AuditReportBuilder.build({
      collectionWindowMinutes: 10,
      fniDetails: [],
      boundaryResults: new Map(),
      allRuleIdsByModel: new Map(),
    });

    expect(report.summary.totalDecisionExecutions).toBe(0);
    expect(report.summary.uniqueDecisionModels).toBe(0);
    expect(report.summary.avgLatencyUs).toBe(0);
    expect(report.summary.p95LatencyUs).toBe(0);
    expect(report.perModel).toEqual([]);
    expect(report.compliance.allModelsEvaluated).toBe(true);
    expect(report.compliance.noDeadRulesFound).toBe(true);
    expect(report.compliance.latencyWithinSla).toBe(true);
  });

  it('includes models from boundary results even without executions', () => {
    const report = AuditReportBuilder.build({
      collectionWindowMinutes: 1,
      fniDetails: [],
      boundaryResults: new Map([
        [
          'employee-benefits',
          [{ testCase: 'probe', input: {}, result: { tier: 'bronze' }, error: null }],
        ],
      ]),
      allRuleIdsByModel: new Map([['employee-benefits', ALL_RULES]]),
    });

    expect(report.perModel).toHaveLength(1);
    expect(report.perModel[0].executionCount).toBe(0);
    expect(report.compliance.allModelsEvaluated).toBe(false);
  });
});
