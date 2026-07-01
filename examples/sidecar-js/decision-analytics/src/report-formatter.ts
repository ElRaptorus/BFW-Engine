import type { DecisionStats } from './analytics-collector.js';
import { LatencyHistogram } from './latency-histogram.js';

export interface AnalyticsReport {
  generatedAt: string;
  decisions: Array<{
    decisionRef: string;
    evaluationCount: number;
    avgLatencyUs: number;
    p95LatencyUs: number;
    p99LatencyUs: number;
    minLatencyUs: number;
    maxLatencyUs: number;
    topRules: Array<[string, number]>;
  }>;
  totals: {
    totalEvaluations: number;
    uniqueDecisions: number;
  };
}

export class ReportFormatter {
  static format(stats: Map<string, DecisionStats>): AnalyticsReport {
    const decisions = Array.from(stats.values()).map((stat) => {
      const histogram = new LatencyHistogram();
      histogram.addAll(stat.latencies);

      const topRules = Array.from(stat.ruleHitCounts.entries())
        .sort((left, right) => right[1] - left[1])
        .slice(0, 10);

      return {
        decisionRef: stat.decisionRef,
        evaluationCount: stat.evaluationCount,
        avgLatencyUs: Math.round(histogram.average),
        p95LatencyUs: histogram.p95,
        p99LatencyUs: histogram.p99,
        minLatencyUs: histogram.min,
        maxLatencyUs: histogram.max,
        topRules,
      };
    });

    let totalEvaluations = 0;
    for (const decision of decisions) {
      totalEvaluations += decision.evaluationCount;
    }

    return {
      generatedAt: new Date().toISOString(),
      decisions,
      totals: { totalEvaluations, uniqueDecisions: decisions.length },
    };
  }
}
