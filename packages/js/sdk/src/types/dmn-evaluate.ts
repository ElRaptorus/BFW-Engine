import type { DmnHitPolicy } from './enums.js';

/** Request body for `POST /decisions/{id}/evaluate`. */
export interface EvaluateDecisionRequest {
  input: Record<string, unknown>;
  decisionModelId?: string;
  includeUnmatchedDetails?: boolean;
}

/** Complete result of a DMN decision evaluation, including the execution trace. */
export interface EvaluationResult {
  decisionModelId: string;
  decisionName: string | null;
  hitPolicy: DmnHitPolicy;
  result: Record<string, unknown> | Record<string, unknown>[] | null;
  matchedRules: string[];
  trace: EvaluationTrace;
  evaluatedAt: string;
  durationMicroseconds: number;
  definitionsId: string | null;
  definitionsNamespace: string | null;
  decisionVersionId: string | null;
}

/** Ordered list of decision-level traces with optional input coercion detail. */
export interface EvaluationTrace {
  decisions: DecisionTrace[];
  inputCoercions: CoercionTrace[];
}

/** Trace for a single decision within an evaluation. */
export interface DecisionTrace {
  decisionModelId: string;
  decisionName: string | null;
  hitPolicy: DmnHitPolicy;
  inputs: InputTrace[];
  matchedRules: RuleTrace[];
  /**
   * Per-rule trace detail for unmatched rules. Only present when the
   * evaluation was requested with `includeUnmatchedDetails: true` (REST)
   * or `bfw:traceUnmatchedRules` (BRT). Each entry has `outputValues: {}`
   * since the rule did not fire.
   */
  unmatchedRules?: RuleTrace[];
  unmatchedRulesCount: number;
  result: Record<string, unknown> | Record<string, unknown>[] | null;
  durationMicroseconds: number;
  warnings: Record<string, unknown>[];
  bkmTraces: BkmTrace[];
  importTraces: ImportTrace[];
}

/** Trace of a single input expression resolution. */
export interface InputTrace {
  inputId: string;
  inputLabel: string | null;
  expression: string;
  resolvedValue: unknown;
}

/** Trace of a single matched rule with per-cell evaluations. */
export interface RuleTrace {
  ruleId: string;
  ruleIndex: number;
  description: string | null;
  inputEvaluations: InputEntryTrace[];
  outputValues: Record<string, unknown>;
}

/** Trace of a single input entry (unary test) evaluation within a rule. */
export interface InputEntryTrace {
  inputId: string;
  expression: string;
  testedValue: unknown;
  matched: boolean;
}

/** Trace of a single BKM invocation including nested BKM chains. */
export interface BkmTrace {
  bkmId: string;
  bkmName: string | null;
  formalParameters: { name: string; boundValue: unknown }[];
  result: unknown;
  durationMicroseconds: number;
  dependentBkmTraces: BkmTrace[];
}

/** Trace of a cross-model import wrapping the full sub-DRG evaluation. */
export interface ImportTrace {
  namespace: string;
  decisionId: string;
  sourceDefinitionsId: string;
  evaluationTrace: EvaluationTrace;
  result: unknown;
  durationMicroseconds: number;
}

/**
 * Type-specific properties emitted by BusinessRuleTask FNIs in DMN mode.
 *
 * When a Business Rule Task completes with `implementation="dmn"`, the
 * engine populates the FNI's `typeProperties` with this shape. The keys
 * are **snake_case** because `typeProperties` is an opaque payload field
 * (not recursively camelCased by the Wire layer).
 */
export interface DmnFlowNodeTypeProperties {
  mode: 'dmn';
  decision_ref: string;
  decision_element_id: string | null;
  decision_version_id: string;
  definitions_id: string | null;
  definitions_namespace: string | null;
  version: string;
  hit_policy: string;
  matched_rules: string[];
  trace: {
    decisions: Record<string, unknown>[];
    input_coercions: Record<string, unknown>[];
  };
  duration_us: number;
}

/**
 * Type-specific properties emitted by BusinessRuleTask FNIs in FEEL mode.
 *
 * When a Business Rule Task completes with `implementation="feel"`, the
 * engine populates the FNI's `typeProperties` with this minimal shape.
 */
export interface FeelFlowNodeTypeProperties {
  mode: 'feel';
}

/** Request body for `POST /decisions/{id}/services/{serviceId}/evaluate`. */
export interface EvaluateServiceRequest {
  input: Record<string, unknown>;
  includeUnmatchedDetails?: boolean;
}

/** Trace of a single input type coercion (or non-coercion). */
export interface CoercionTrace {
  inputName: string;
  originalValue: unknown;
  coercedValue: unknown;
  targetType: string;
  coerced: boolean;
}
