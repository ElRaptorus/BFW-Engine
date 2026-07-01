import type { EventDefinitionType, FlowNodeInstanceState, FlowNodeType } from './enums.js';
import type { ErrorInfo } from './error-info.js';
import type { ProcessInstance } from './process-instance.js';

/**
 * A single execution of a BPMN flow node within a process instance.
 *
 * **Authorization behavior (S-1/S-2):** Read operations apply identity-scoped
 * filtering — unauthorized callers receive an empty result set rather than a 403.
 */
export interface FlowNodeInstance {
  /** Engine-assigned UUID. */
  id: string;
  /** UUID of the owning process instance. */
  processInstanceId: string;
  /** BPMN ID of the flow node definition. */
  flowNodeId: string;
  /** The BPMN element type. */
  flowNodeType: FlowNodeType;
  /** Event definition subtype, or `null` for non-event flow nodes and plain events. */
  eventType: EventDefinitionType | null;
  /** Name of the lane this flow node belongs to, or `null`. */
  laneName: string | null;
  /** Current lifecycle state. */
  state: FlowNodeInstanceState;
  /** ISO 8601 timestamp when execution started. */
  startedAt: string;
  /** ISO 8601 timestamp when execution finished, or `null` if still active. */
  finishedAt: string | null;
  /** UUIDs of FNIs whose outgoing sequence flows led to this FNI. */
  previousFlowNodeInstanceIds: string[];
  /** UUID of the FNI that triggered this one (e.g. a boundary event's host). */
  triggererFlowNodeInstanceId: string | null;
  /** The payload this FNI received as input. */
  inputToken: Record<string, unknown> | null;
  /** The payload this FNI produced as output. */
  outputToken: Record<string, unknown> | null;
  /** Type-specific properties (e.g. assignees for user tasks, implementation for service tasks). */
  typeProperties: Record<string, unknown> | null;
  /** Error details when the FNI is in a fatal state. See {@link ErrorInfo}. */
  errorInfo: ErrorInfo | null;
  /** Populated when loaded via GraphQL relationship. */
  processInstance?: ProcessInstance;
}
