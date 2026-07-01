export interface FniFinishedEvent {
  flowNodeInstanceId: string;
  processInstanceId: string;
  flowNodeId: string;
  flowNodeType: string;
  terminalState: string;
  occurredAt: string;
  payload?: {
    typeProperties?: {
      mode?: string;
      decision_ref?: string;
      decision_version_id?: string;
      duration_us?: number;
      hit_policy?: string;
      matched_rules?: Array<{ rule_id: string; rule_index: number }>;
      trace?: DecisionTrace;
    };
  };
}

export interface DecisionTrace {
  decisions: Array<{
    decision_name: string;
    hit_policy: string;
    matched_rules: Array<{ rule_id: string; rule_index: number }>;
    result: Record<string, unknown>;
    duration_microseconds: number;
  }>;
}

export interface FniDetails {
  flowNodeInstanceId: string;
  decisionRef: string;
  durationUs: number;
  matchedRules: string[];
  trace: DecisionTrace | null;
}

export interface BoundaryTestResult {
  testCase: string;
  input: Record<string, unknown>;
  result: Record<string, unknown> | null;
  error: string | null;
}

export interface CoverageResult {
  totalRules: number;
  matchedRules: number;
  deadRules: string[];
  coveragePercent: number;
}

export interface AuditReport {
  generatedAt: string;
  collectionWindowMinutes: number;
  summary: {
    totalDecisionExecutions: number;
    uniqueDecisionModels: number;
    avgLatencyUs: number;
    p95LatencyUs: number;
    errorRate: number;
  };
  perModel: Array<{
    decisionRef: string;
    executionCount: number;
    avgLatencyUs: number;
    ruleCoverage: CoverageResult;
    boundaryTestResults: BoundaryTestResult[];
  }>;
  compliance: {
    allModelsEvaluated: boolean;
    noDeadRulesFound: boolean;
    latencyWithinSla: boolean;
  };
}

export interface SidecarPlugin {
  connect(): Promise<void>;
  register(): Promise<void>;
  onEvent(
    filter: { eventTypes: string[] },
    handler: (event: Record<string, unknown>) => void,
  ): void;
  evaluateDecision(
    modelId: string,
    input: Record<string, unknown>,
  ): Promise<{
    result: Record<string, unknown>;
    matchedRules: Array<{ rule_id: string }>;
  }>;
  getFlowNodeInstance(fniId: string): Promise<Record<string, unknown> | null>;
  disconnect(): Promise<void>;
}
