import type { EvaluationTrace } from '../types/dmn-evaluate.js';
import type { DmnHitPolicy } from '../types/enums.js';

export interface DmnDefinitions {
  id: string | null;
  name: string | null;
  namespace: string | null;
  decisions: DmnDecision[];
  inputData: DmnInputData[];
  businessKnowledgeModels: DmnBusinessKnowledgeModel[];
  knowledgeSources: DmnKnowledgeSource[];
  itemDefinitions: DmnItemDefinition[];
  imports: DmnImport[];
  decisionServices: DmnDecisionService[];
  dmndi: DmnDI | null;
  rawXml: string;
}

export interface DmnDecision {
  id: string;
  name: string | null;
  outputLabel: string | null;
  expression: DmnExpressionBody | null;
  informationRequirements: DmnInformationRequirement[];
  knowledgeRequirements: DmnKnowledgeRequirement[];
  authorityRequirements: DmnAuthorityRequirement[];
  variable: DmnInformationItem | null;
}

export interface DmnLiteralExpression {
  id: string | null;
  text: string;
  typeRef: string | null;
  expressionLanguage: string | null;
}

export interface DmnDecisionTable {
  id: string | null;
  hitPolicy: DmnHitPolicy;
  aggregation: DmnAggregation | null;
  preferredOrientation: DmnOrientation;
  inputs: DmnInput[];
  outputs: DmnOutput[];
  rules: DmnRule[];
}

export interface DmnInput {
  id: string;
  label: string | null;
  inputExpression: string | null;
  inputValues: string | null;
  typeRef: string | null;
}

export interface DmnOutput {
  id: string;
  label: string | null;
  name: string | null;
  outputValues: string | null;
  typeRef: string | null;
  defaultOutputValue: string | null;
}

export interface DmnRule {
  id: string;
  description: string | null;
  inputEntries: DmnInputEntry[];
  outputEntries: DmnOutputEntry[];
  annotationEntries: string[];
}

export interface DmnInputEntry {
  id: string;
  text: string;
}

export interface DmnOutputEntry {
  id: string;
  text: string;
}

export interface DmnInputData {
  id: string;
  name: string;
  typeRef: string | null;
}

export interface DmnInformationRequirement {
  id: string | null;
  requiredDecisionId: string | null;
  requiredInputId: string | null;
}

export interface DmnBusinessKnowledgeModel {
  id: string;
  name: string | null;
  encapsulatedLogic: DmnFunctionDefinition | null;
  knowledgeRequirements: DmnKnowledgeRequirement[];
  authorityRequirements: DmnAuthorityRequirement[];
  variable: DmnInformationItem | null;
}

export interface DmnFunctionDefinition {
  id: string | null;
  kind: string;
  formalParameters: DmnInformationItem[];
  body: DmnExpressionBody | null;
}

export type DmnExpressionBody =
  | DmnDecisionTable
  | DmnLiteralExpression
  | DmnBoxedContext
  | DmnBoxedInvocation
  | DmnBoxedList
  | DmnRelation
  | DmnFunctionDefinition
  | DmnBoxedConditional
  | DmnBoxedFilter
  | DmnBoxedFor
  | DmnBoxedEvery
  | DmnBoxedSome;

export interface DmnContextEntry {
  variable: DmnInformationItem | null;
  expression: DmnExpressionBody | null;
}

export interface DmnBoxedContext {
  id: string | null;
  contextEntries: DmnContextEntry[];
}

export interface DmnBinding {
  parameter: DmnInformationItem | null;
  expression: DmnExpressionBody | null;
}

export interface DmnBoxedInvocation {
  id: string | null;
  calledFunction: string;
  bindings: DmnBinding[];
}

export interface DmnBoxedList {
  id: string | null;
  elements: DmnExpressionBody[];
}

export interface DmnRelation {
  id: string | null;
  columns: DmnInformationItem[];
  rows: DmnExpressionBody[][];
}

export interface DmnBoxedConditional {
  id: string | null;
  ifExpression: DmnExpressionBody | null;
  thenExpression: DmnExpressionBody | null;
  elseExpression: DmnExpressionBody | null;
}

export interface DmnBoxedFilter {
  id: string | null;
  inExpression: DmnExpressionBody | null;
  matchExpression: DmnExpressionBody | null;
}

export interface DmnBoxedFor {
  id: string | null;
  iteratorVariable: string;
  inExpression: DmnExpressionBody | null;
  returnExpression: DmnExpressionBody | null;
}

export interface DmnBoxedEvery {
  id: string | null;
  iteratorVariable: string;
  inExpression: DmnExpressionBody | null;
  satisfiesExpression: DmnExpressionBody | null;
}

export interface DmnBoxedSome {
  id: string | null;
  iteratorVariable: string;
  inExpression: DmnExpressionBody | null;
  satisfiesExpression: DmnExpressionBody | null;
}

export interface DmnDecisionService {
  id: string;
  name: string | null;
  outputDecisions: string[];
  encapsulatedDecisions: string[];
  inputDecisions: string[];
  inputData: string[];
}

export interface DmnBounds {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface DmnPoint {
  x: number;
  y: number;
}

export interface DmnShape {
  id: string | null;
  dmnElementRef: string;
  bounds: DmnBounds;
}

export interface DmnEdge {
  id: string | null;
  dmnElementRef: string;
  waypoints: DmnPoint[];
}

export interface DmnDiagram {
  id: string | null;
  name: string | null;
  shapes: DmnShape[];
  edges: DmnEdge[];
}

export interface DmnDI {
  diagrams: DmnDiagram[];
}

export interface DmnInformationItem {
  id: string | null;
  name: string;
  typeRef: string | null;
}

export interface DmnKnowledgeRequirement {
  id: string | null;
  requiredKnowledgeId: string;
}

export interface DmnKnowledgeSource {
  id: string;
  name: string | null;
  type: string | null;
  authorityRequirements: DmnAuthorityRequirement[];
}

export interface DmnAuthorityRequirement {
  id: string | null;
  requiredAuthorityId: string | null;
  requiredDecisionId: string | null;
  requiredInputId: string | null;
}

export interface DmnItemDefinition {
  id: string;
  name: string;
  typeRef: string | null;
  allowedValues: string | null;
  itemComponents: DmnItemDefinition[];
  isCollection: boolean;
}

export interface DmnImport {
  id: string | null;
  namespace: string;
  locationUri: string | null;
  importType: string;
}

export type DmnAggregation = 'SUM' | 'MIN' | 'MAX' | 'COUNT';
export type DmnOrientation = 'Rule-as-Row' | 'Rule-as-Column' | 'CrossTable';

/** Result of evaluating a Decision Service (mirrors engine `ServiceEvaluationResult.to_json_map/1`). */
export interface DmnServiceEvaluationResult {
  serviceId: string;
  serviceName: string | null;
  outputs: Record<string, unknown>;
  trace: EvaluationTrace;
  evaluatedAt: string;
  durationMicroseconds: number;
}
