import type { DecisionTrace, FniDetails, SidecarPlugin } from './types.js';

export class FniInspector {
  constructor(private plugin: SidecarPlugin) {}

  async fetchAll(fniIds: string[]): Promise<FniDetails[]> {
    const results: FniDetails[] = [];
    for (const fniId of fniIds) {
      try {
        const fni = await this.plugin.getFlowNodeInstance(fniId);
        if (fni) {
          const typeProperties = (fni.typeProperties ?? {}) as Record<string, unknown>;
          results.push({
            flowNodeInstanceId: fniId,
            decisionRef: (typeProperties.decision_ref as string) ?? 'unknown',
            durationUs: (typeProperties.duration_us as number) ?? 0,
            matchedRules: ((typeProperties.matched_rules as unknown[]) ?? []).map(
              (rule) => {
                if (typeof rule === 'string') return rule;
                if (typeof rule === 'object' && rule !== null)
                  return (rule as Record<string, unknown>).rule_id as string;
                return String(rule);
              },
            ),
            trace: (typeProperties.trace as DecisionTrace) ?? null,
          });
        }
      } catch {
        // Skip FNIs that cannot be fetched
      }
    }
    return results;
  }
}
