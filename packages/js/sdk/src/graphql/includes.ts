import type {
  DataObjectValueField,
  DecisionVersionField,
  FlowNodeInstanceField,
  ProcessInstanceField,
  ProcessVersionField,
} from './fields.js';
import type {
  DataObjectValueFilter,
  DecisionVersionFilter,
  FlowNodeInstanceFilter,
  ProcessVersionFilter,
} from './filters.js';
import type { SortClause } from './filters.js';

/** Relationship includes for `ProcessModel` queries. */
export interface ProcessModelInclude {
  versions?: {
    fields: ProcessVersionField[];
    filter?: ProcessVersionFilter;
    sort?: SortClause<ProcessVersionField>[];
  };
}

/** Relationship includes for `ProcessInstance` queries. */
export interface ProcessInstanceInclude {
  processVersion?: {
    fields: ProcessVersionField[];
  };
  flowNodeInstances?: {
    fields: FlowNodeInstanceField[];
    filter?: FlowNodeInstanceFilter;
    sort?: SortClause<FlowNodeInstanceField>[];
  };
  dataObjectValues?: {
    fields: DataObjectValueField[];
    filter?: DataObjectValueFilter;
    sort?: SortClause<DataObjectValueField>[];
  };
  dataObjectHistory?: {
    fields: DataObjectValueField[];
    filter?: DataObjectValueFilter;
    sort?: SortClause<DataObjectValueField>[];
  };
}

/** Relationship includes for `FlowNodeInstance` queries. */
export interface FlowNodeInstanceInclude {
  processInstance?: {
    fields: ProcessInstanceField[];
  };
}

/** Relationship includes for `DataObjectValue` and `DataObjectHistoryEntry` queries. */
export interface DataObjectValueInclude {
  processInstance?: {
    fields: ProcessInstanceField[];
  };
}

/** Relationship includes for `DecisionDefinition` queries. */
export interface DecisionDefinitionInclude {
  versions?: {
    fields: DecisionVersionField[];
    filter?: DecisionVersionFilter;
    sort?: SortClause<DecisionVersionField>[];
  };
}
