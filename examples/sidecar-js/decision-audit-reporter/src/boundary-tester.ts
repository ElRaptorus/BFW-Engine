import type { BoundaryTestResult, SidecarPlugin } from './types.js';

export interface DecisionModelBoundaryConfig {
  decisionRef: string;
  boundaryInputs: Array<{ testCase: string; input: Record<string, unknown> }>;
}

export class BoundaryTester {
  constructor(private plugin: SidecarPlugin) {}

  async testAll(
    decisionModels: DecisionModelBoundaryConfig[],
  ): Promise<Map<string, BoundaryTestResult[]>> {
    const results = new Map<string, BoundaryTestResult[]>();

    for (const model of decisionModels) {
      const modelResults: BoundaryTestResult[] = [];
      for (const { testCase, input } of model.boundaryInputs) {
        try {
          const evaluation = await this.plugin.evaluateDecision(model.decisionRef, input);
          modelResults.push({ testCase, input, result: evaluation.result, error: null });
        } catch (error) {
          modelResults.push({ testCase, input, result: null, error: String(error) });
        }
      }
      results.set(model.decisionRef, modelResults);
    }
    return results;
  }
}
