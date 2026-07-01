export interface DecisionStats {
  decisionRef: string;
  evaluationCount: number;
  totalDurationUs: number;
  latencies: number[];
  ruleHitCounts: Map<string, number>;
  lastSeen: Date;
}

export class AnalyticsCollector {
  private stats: Map<string, DecisionStats> = new Map();

  record(event: Record<string, unknown>): void {
    const payload = event.payload as Record<string, unknown> | undefined;
    const typeProperties = payload?.typeProperties as Record<string, unknown> | undefined;

    const decisionRef = (typeProperties?.decision_ref as string) ?? 'unknown';
    const durationUs = (typeProperties?.duration_us as number) ?? 0;
    const rawMatchedRules = (typeProperties?.matched_rules as unknown[]) ?? [];
    const matchedRuleIds = rawMatchedRules.map((rule) => {
      if (typeof rule === 'string') return rule;
      if (typeof rule === 'object' && rule !== null) return (rule as Record<string, unknown>).rule_id as string;
      return String(rule);
    });

    const existing = this.stats.get(decisionRef);
    if (existing) {
      existing.evaluationCount++;
      existing.totalDurationUs += durationUs;
      existing.latencies.push(durationUs);
      for (const ruleId of matchedRuleIds) {
        existing.ruleHitCounts.set(ruleId, (existing.ruleHitCounts.get(ruleId) ?? 0) + 1);
      }
      existing.lastSeen = new Date();
    } else {
      const ruleHitCounts = new Map<string, number>();
      for (const ruleId of matchedRuleIds) {
        ruleHitCounts.set(ruleId, 1);
      }
      this.stats.set(decisionRef, {
        decisionRef,
        evaluationCount: 1,
        totalDurationUs: durationUs,
        latencies: [durationUs],
        ruleHitCounts,
        lastSeen: new Date(),
      });
    }
  }

  getStats(): Map<string, DecisionStats> {
    return this.stats;
  }

  getStatsForDecision(decisionRef: string): DecisionStats | undefined {
    return this.stats.get(decisionRef);
  }

  reset(): void {
    this.stats.clear();
  }
}
