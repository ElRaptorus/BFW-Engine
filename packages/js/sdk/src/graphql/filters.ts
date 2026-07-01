/** Filter operators for string and UUID fields. */
export interface StringFilter {
  /** Exact match. */
  eq?: string;
  /** Negated exact match. */
  notEq?: string;
  /** Value is one of the given strings. */
  in?: string[];
  /** Lexicographic less-than. */
  lessThan?: string;
  /** Lexicographic greater-than. */
  greaterThan?: string;
  /** Lexicographic less-than-or-equal. */
  lessThanOrEqual?: string;
  /** Lexicographic greater-than-or-equal. */
  greaterThanOrEqual?: string;
  /** True if the field is NULL (or not NULL when false). */
  isNil?: boolean;
  /** Case-insensitive pattern match with SQL wildcards (`%` = any chars, `_` = one char). */
  ilike?: string;
  /** Case-sensitive pattern match with SQL wildcards. */
  like?: string;
}

/** Filter operators for boolean fields. */
export interface BooleanFilter {
  eq?: boolean;
  isNil?: boolean;
}

/** Filter operators for datetime fields (ISO 8601 strings). */
export interface DateTimeFilter {
  /** Exact match. */
  eq?: string;
  /** Negated exact match. */
  notEq?: string;
  /** Strictly before this timestamp. */
  lessThan?: string;
  /** Strictly after this timestamp. */
  greaterThan?: string;
  lessThanOrEqual?: string;
  greaterThanOrEqual?: string;
  isNil?: boolean;
}

/** Filter operators for integer fields. */
export interface IntegerFilter {
  eq?: number;
  notEq?: number;
  in?: number[];
  lessThan?: number;
  greaterThan?: number;
  lessThanOrEqual?: number;
  greaterThanOrEqual?: number;
  isNil?: boolean;
}

/** Filter operators for JSON map fields (limited to nil checks). */
export interface MapFilter {
  isNil?: boolean;
}

/** Sort direction for list queries. */
export type SortDirection = 'asc' | 'desc';

/** A single sort criterion: which field to sort by and in which direction. */
export interface SortClause<F extends string> {
  field: F;
  direction: SortDirection;
}

/** Filter type for `Process` list queries (AshGraphql `ProcessFilterInput`). */
export interface ProcessModelFilter {
  id?: StringFilter;
  processModelId?: StringFilter;
  name?: StringFilter;
  enabled?: BooleanFilter;
  createdAt?: DateTimeFilter;
}

/** Filter type for `ProcessVersion` list queries (AshGraphql `ProcessVersionFilterInput`). */
export interface ProcessVersionFilter {
  id?: StringFilter;
  processId?: StringFilter;
  version?: StringFilter;
  definitionsId?: StringFilter;
  deployedAt?: DateTimeFilter;
}

/** Filter type for `ProcessInstance` list queries (AshGraphql `ProcessInstanceFilterInput`). */
export interface ProcessInstanceFilter {
  id?: StringFilter;
  /** UUID primary key cast to text — supports `ilike` for substring search. */
  idText?: StringFilter;
  processVersionId?: StringFilter;
  parentProcessInstanceId?: StringFilter;
  businessKey?: StringFilter;
  state?: StringFilter;
  startedAt?: DateTimeFilter;
  finishedAt?: DateTimeFilter;
  triggererFlowNodeInstanceId?: StringFilter;
}

/** Filter type for `FlowNodeInstance` list queries. */
export interface FlowNodeInstanceFilter {
  id?: StringFilter;
  processInstanceId?: StringFilter;
  flowNodeId?: StringFilter;
  flowNodeType?: StringFilter;
  eventType?: StringFilter;
  laneName?: StringFilter;
  state?: StringFilter;
  startedAt?: DateTimeFilter;
  finishedAt?: DateTimeFilter;
}

/** Filter type for `DataObjectValue` and `DataObjectHistoryEntry` list queries. */
export interface DataObjectValueFilter {
  id?: StringFilter;
  processInstanceId?: StringFilter;
  dataObjectId?: StringFilter;
  flowNodeInstanceId?: StringFilter;
  createdAt?: DateTimeFilter;
}

/** Filter type for `DecisionDefinition` list queries. */
export interface DecisionDefinitionFilter {
  id?: StringFilter;
  decisionDefinitionId?: StringFilter;
  name?: StringFilter;
  enabled?: BooleanFilter;
  createdAt?: DateTimeFilter;
}

/** Filter type for `DecisionVersion` list queries. */
export interface DecisionVersionFilter {
  id?: StringFilter;
  decisionDefinitionId?: StringFilter;
  version?: StringFilter;
  deployedAt?: DateTimeFilter;
}
