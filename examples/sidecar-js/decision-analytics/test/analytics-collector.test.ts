import { describe, expect, it } from 'vitest';

import { AnalyticsCollector } from '../src/analytics-collector.js';
import { LatencyHistogram } from '../src/latency-histogram.js';
import { ReportFormatter } from '../src/report-formatter.js';

function buildDmnFinishedEvent(options: {
  decisionRef?: string;
  durationUs?: number;
  matchedRules?: string[];
}): Record<string, unknown> {
  return {
    flowNodeType: 'business_rule_task',
    payload: {
      typeProperties: {
        mode: 'dmn',
        decision_ref: options.decisionRef ?? 'shipping-rates',
        duration_us: options.durationUs ?? 1000,
        matched_rules: options.matchedRules ?? ['Rule_express_domestic_light'],
      },
    },
  };
}

describe('AnalyticsCollector', () => {
  it('records event and updates per-decision stats', () => {
    const collector = new AnalyticsCollector();
    collector.record(buildDmnFinishedEvent({ decisionRef: 'shipping-rates', durationUs: 500 }));
    collector.record(buildDmnFinishedEvent({ decisionRef: 'shipping-rates', durationUs: 700 }));

    const stats = collector.getStatsForDecision('shipping-rates');
    expect(stats).toBeDefined();
    expect(stats!.evaluationCount).toBe(2);
    expect(stats!.totalDurationUs).toBe(1200);
    expect(stats!.latencies).toEqual([500, 700]);
  });

  it('computes correct average from latency array via report formatting', () => {
    const collector = new AnalyticsCollector();
    collector.record(buildDmnFinishedEvent({ durationUs: 100 }));
    collector.record(buildDmnFinishedEvent({ durationUs: 300 }));

    const report = ReportFormatter.format(collector.getStats());
    const decision = report.decisions[0];
    expect(decision.avgLatencyUs).toBe(200);

    const histogram = new LatencyHistogram();
    histogram.addAll(collector.getStatsForDecision('shipping-rates')!.latencies);
    expect(Math.round(histogram.average)).toBe(200);
  });

  it('tracks per-rule hit distribution', () => {
    const collector = new AnalyticsCollector();
    collector.record(
      buildDmnFinishedEvent({
        matchedRules: ['Rule_express_domestic_light'],
      }),
    );
    collector.record(
      buildDmnFinishedEvent({
        matchedRules: ['Rule_express_domestic_light'],
      }),
    );
    collector.record(
      buildDmnFinishedEvent({
        matchedRules: ['Rule_economy_domestic_light'],
      }),
    );

    const stats = collector.getStatsForDecision('shipping-rates')!;
    expect(stats.ruleHitCounts.get('Rule_express_domestic_light')).toBe(2);
    expect(stats.ruleHitCounts.get('Rule_economy_domestic_light')).toBe(1);

    const report = ReportFormatter.format(collector.getStats());
    expect(report.decisions[0].topRules[0]).toEqual(['Rule_express_domestic_light', 2]);
  });

  it('reset clears all stats', () => {
    const collector = new AnalyticsCollector();
    collector.record(buildDmnFinishedEvent({}));
    collector.reset();
    expect(collector.getStats().size).toBe(0);
  });

  it('defaults unknown decision ref when decision_ref is missing', () => {
    const collector = new AnalyticsCollector();
    collector.record({
      flowNodeType: 'business_rule_task',
      payload: {
        typeProperties: {
          mode: 'dmn',
          duration_us: 42,
        },
      },
    });

    const stats = collector.getStatsForDecision('unknown');
    expect(stats).toBeDefined();
    expect(stats!.decisionRef).toBe('unknown');
    expect(stats!.evaluationCount).toBe(1);
  });
});
