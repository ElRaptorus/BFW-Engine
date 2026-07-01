import { CoverageAnalyzer } from './coverage-analyzer.js';
import type {
  AuditReport,
  BoundaryTestResult,
  CoverageResult,
  FniDetails,
} from './types.js';

export const DEFAULT_SLA_THRESHOLD_US = 100_000;

export interface AuditReportBuildInput {
  collectionWindowMinutes: number;
  fniDetails: FniDetails[];
  boundaryResults: Map<string, BoundaryTestResult[]>;
  allRuleIdsByModel: Map<string, string[]>;
  slaThresholdUs?: number;
}

export class AuditReportBuilder {
  private static readonly coverageAnalyzer = new CoverageAnalyzer();

  static build(input: AuditReportBuildInput): AuditReport {
    const slaThresholdUs = input.slaThresholdUs ?? DEFAULT_SLA_THRESHOLD_US;
    const groupedByDecisionRef = groupFniDetailsByDecisionRef(input.fniDetails);

    const decisionRefs = new Set<string>([
      ...groupedByDecisionRef.keys(),
      ...input.boundaryResults.keys(),
      ...input.allRuleIdsByModel.keys(),
    ]);

    const perModel = [...decisionRefs].sort().map((decisionRef) => {
      const modelFnis = groupedByDecisionRef.get(decisionRef) ?? [];
      const latencies = modelFnis.map((fni) => fni.durationUs);
      const ruleIds = input.allRuleIdsByModel.get(decisionRef) ?? [];
      const ruleCoverage = AuditReportBuilder.coverageAnalyzer.analyze(modelFnis, ruleIds);

      return {
        decisionRef,
        executionCount: modelFnis.length,
        avgLatencyUs: average(latencies),
        ruleCoverage,
        boundaryTestResults: input.boundaryResults.get(decisionRef) ?? [],
      };
    });

    const allLatencies = input.fniDetails.map((fni) => fni.durationUs);
    const boundaryTests = [...input.boundaryResults.values()].flat();
    const boundaryErrorCount = boundaryTests.filter((test) => test.error !== null).length;

    return {
      generatedAt: new Date().toISOString(),
      collectionWindowMinutes: input.collectionWindowMinutes,
      summary: {
        totalDecisionExecutions: input.fniDetails.length,
        uniqueDecisionModels: decisionRefs.size,
        avgLatencyUs: average(allLatencies),
        p95LatencyUs: percentile(allLatencies, 95),
        errorRate:
          boundaryTests.length > 0 ? boundaryErrorCount / boundaryTests.length : 0,
      },
      perModel,
      compliance: {
        allModelsEvaluated: perModel.every((model) => model.executionCount > 0),
        noDeadRulesFound: perModel.every((model) => model.ruleCoverage.deadRules.length === 0),
        latencyWithinSla: perModel.every((model) => model.avgLatencyUs < slaThresholdUs),
      },
    };
  }
}

function groupFniDetailsByDecisionRef(
  fniDetails: FniDetails[],
): Map<string, FniDetails[]> {
  const grouped = new Map<string, FniDetails[]>();
  for (const fni of fniDetails) {
    const existing = grouped.get(fni.decisionRef) ?? [];
    existing.push(fni);
    grouped.set(fni.decisionRef, existing);
  }
  return grouped;
}

function average(values: number[]): number {
  if (values.length === 0) return 0;
  return Math.round(values.reduce((sum, value) => sum + value, 0) / values.length);
}

function percentile(values: number[], percentileRank: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((left, right) => left - right);
  const index = Math.ceil((percentileRank / 100) * sorted.length) - 1;
  return sorted[Math.max(0, Math.min(index, sorted.length - 1))];
}
