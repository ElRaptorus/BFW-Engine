import type { CoverageResult, FniDetails } from './types.js';

export class CoverageAnalyzer {
  analyze(fniDetails: FniDetails[], allRuleIds: string[]): CoverageResult {
    const matchedSet = new Set<string>();
    for (const fni of fniDetails) {
      for (const ruleId of fni.matchedRules) {
        matchedSet.add(ruleId);
      }
    }

    const allSet = new Set(allRuleIds);
    const deadRules = allRuleIds.filter((id) => !matchedSet.has(id));

    return {
      totalRules: allSet.size,
      matchedRules: matchedSet.size,
      deadRules,
      coveragePercent:
        allSet.size > 0 ? Math.round((matchedSet.size / allSet.size) * 10000) / 100 : 0,
    };
  }
}
