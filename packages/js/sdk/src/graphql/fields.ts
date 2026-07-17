/**
 * Queryable scalar fields on the `Process` GraphQL type.
 * The REST API calls this "ProcessModel"; in GraphQL it is simply "Process".
 */
export type ProcessModelField = 'id' | 'processModelId' | 'name' | 'enabled' | 'createdAt';

/**
 * Queryable scalar fields on the `ProcessInstance` GraphQL type.
 */
export type ProcessInstanceField =
  | 'id'
  | 'idText'
  | 'processVersionId'
  | 'parentProcessInstanceId'
  | 'businessKey'
  | 'triggererFlowNodeInstanceId'
  | 'state'
  | 'startedAt'
  | 'finishedAt'
  | 'startedBy'
  | 'startedWithContext'
  | 'finalTokens'
  | 'errorInfo';

/** Queryable scalar fields on `FlowNodeInstance`. */
export type FlowNodeInstanceField =
  | 'id'
  | 'processInstanceId'
  | 'flowNodeId'
  | 'flowNodeType'
  | 'eventType'
  | 'laneName'
  | 'state'
  | 'startedAt'
  | 'finishedAt'
  | 'previousFlowNodeInstanceIds'
  | 'triggererFlowNodeInstanceId'
  | 'inputToken'
  | 'outputToken'
  | 'typeProperties'
  | 'errorInfo'
  | 'multiInstanceId'
  | 'iterationIndex';

/** Queryable scalar fields on `DataObjectValue` and `DataObjectHistoryEntry`. */
export type DataObjectValueField =
  'id' | 'processInstanceId' | 'dataObjectId' | 'flowNodeInstanceId' | 'value' | 'createdAt';

/**
 * Queryable scalar fields on the `ProcessVersion` GraphQL type.
 */
export type ProcessVersionField =
  'id' | 'processId' | 'version' | 'definitionsId' | 'deployedAt' | 'bpmnXml' | 'deployer';

/**
 * Queryable scalar fields on the `DecisionDefinition` GraphQL type.
 */
export type DecisionDefinitionField = 'id' | 'decisionDefinitionId' | 'name' | 'enabled' | 'createdAt';

/**
 * Queryable scalar fields on the `DecisionVersion` GraphQL type.
 */
export type DecisionVersionField = 'id' | 'decisionDefinitionId' | 'version' | 'deployedAt' | 'dmnXml' | 'deployer';
