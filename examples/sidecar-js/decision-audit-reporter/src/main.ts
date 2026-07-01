import { AuditReportBuilder } from './audit-report-builder.js';
import { BoundaryTester } from './boundary-tester.js';
import { EventTracker } from './event-tracker.js';
import { FniInspector } from './fni-inspector.js';
import type { FniDetails, SidecarPlugin } from './types.js';

// Forward-looking: requires the gRPC sidecar bridge from BPMN Phase 5.
// This entry point demonstrates the intended orchestration against a mocked plugin.
// Unit tests exercise each module in isolation with the same mocked contract.

const COLLECTION_WINDOW_MS = parseInt(process.env.COLLECTION_WINDOW_MS ?? '60000', 10);
const COLLECTION_WINDOW_MINUTES = COLLECTION_WINDOW_MS / 60_000;

/** All rule IDs from dmn/employee_benefits.dmn (rules 10–12 are intentionally hard to hit). */
export const EMPLOYEE_BENEFITS_RULE_IDS = [
  'rule_1',
  'rule_2',
  'rule_3',
  'rule_4',
  'rule_5',
  'rule_6',
  'rule_7',
  'rule_8',
  'rule_9',
  'rule_10',
  'rule_11',
  'rule_12',
];

export const EMPLOYEE_BENEFITS_BOUNDARY_INPUTS: Array<{
  testCase: string;
  input: Record<string, unknown>;
}> = [
  {
    testCase: 'platinum_outstanding_25y',
    input: {
      yearsOfService: 25,
      department: 'engineering',
      performanceRating: 'outstanding',
      employeeType: 'full_time',
    },
  },
  {
    testCase: 'gold_outstanding_12y',
    input: {
      yearsOfService: 12,
      department: 'sales',
      performanceRating: 'outstanding',
      employeeType: 'full_time',
    },
  },
  {
    testCase: 'gold_exceeds_15y',
    input: {
      yearsOfService: 15,
      department: 'marketing',
      performanceRating: 'exceeds',
      employeeType: 'full_time',
    },
  },
  {
    testCase: 'silver_meets_7y',
    input: {
      yearsOfService: 7,
      department: 'support',
      performanceRating: 'meets',
      employeeType: 'full_time',
    },
  },
  {
    testCase: 'executive_department',
    input: {
      yearsOfService: 0,
      department: 'executive',
      performanceRating: 'meets',
      employeeType: 'full_time',
    },
  },
  {
    testCase: 'part_time',
    input: {
      yearsOfService: 3,
      department: 'support',
      performanceRating: 'meets',
      employeeType: 'part_time',
    },
  },
  {
    testCase: 'contractor',
    input: {
      yearsOfService: 1,
      department: 'engineering',
      performanceRating: 'meets',
      employeeType: 'contractor',
    },
  },
];

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

export function extractUniqueDecisionModels(
  fniDetails: FniDetails[],
): Array<{ decisionRef: string; boundaryInputs: typeof EMPLOYEE_BENEFITS_BOUNDARY_INPUTS }> {
  const refs = new Set(fniDetails.map((fni) => fni.decisionRef));
  return [...refs].map((decisionRef) => ({
    decisionRef,
    boundaryInputs:
      decisionRef === 'employee-benefits'
        ? EMPLOYEE_BENEFITS_BOUNDARY_INPUTS
        : [],
  }));
}

export async function runAudit(plugin: SidecarPlugin): Promise<ReturnType<typeof AuditReportBuilder.build>> {
  const tracker = new EventTracker();
  plugin.onEvent({ eventTypes: ['fni.finished'] }, tracker.handleEvent);

  await sleep(COLLECTION_WINDOW_MS);

  const inspector = new FniInspector(plugin);
  const fniDetails = await inspector.fetchAll(tracker.getTrackedFnis());

  const decisionModels = extractUniqueDecisionModels(fniDetails);

  const tester = new BoundaryTester(plugin);
  const boundaryResults = await tester.testAll(decisionModels);

  const allRuleIdsByModel = new Map<string, string[]>();
  for (const model of decisionModels) {
    if (model.decisionRef === 'employee-benefits') {
      allRuleIdsByModel.set(model.decisionRef, EMPLOYEE_BENEFITS_RULE_IDS);
    }
  }

  return AuditReportBuilder.build({
    collectionWindowMinutes: COLLECTION_WINDOW_MINUTES,
    fniDetails,
    boundaryResults,
    allRuleIdsByModel,
  });
}

async function main(): Promise<void> {
  const plugin: SidecarPlugin = {
    connect: async () => {},
    register: async () => {},
    onEvent: (_filter, _handler) => {},
    evaluateDecision: async (_modelId, input) => ({
      result: { tier: 'bronze' },
      matchedRules: [{ rule_id: 'rule_6' }],
    }),
    getFlowNodeInstance: async () => null,
    disconnect: async () => {},
  };

  await plugin.connect();
  await plugin.register();

  const report = await runAudit(plugin);
  console.log(JSON.stringify(report, null, 2));

  await plugin.disconnect();
}

main().catch(console.error);
