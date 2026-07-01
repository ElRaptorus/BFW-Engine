import type { ProcessInstance } from './process-instance.js';

/**
 * A single Data Object value — used for both the current-value snapshot
 * and the full audit-trail history. Both the `dataObjectValues` and
 * `dataObjectHistory` collections on a ProcessInstance use this type.
 */
export interface DataObjectValue {
  /** Unique identifier for this DO value record. */
  id: string;
  /** The process instance this value belongs to. */
  processInstanceId: string;
  /** The BPMN Data Object ID. */
  dataObjectId: string;
  /** The flow node instance that wrote this value. */
  flowNodeInstanceId: string;
  /** The value itself. `null` if the data object was explicitly cleared. */
  value: unknown | null;
  /** ISO 8601 timestamp when this value was written. */
  createdAt: string;
  /** Populated when loaded via GraphQL relationship. */
  processInstance?: ProcessInstance;
}
