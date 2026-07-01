import type { DataObjectValue } from './data-object-value.js';
import type { ProcessInstanceState } from './enums.js';
import type { ErrorInfo } from './error-info.js';
import type { FinalToken } from './final-token.js';
import type { FlowNodeInstance } from './flow-node-instance.js';
import type { ProcessVersion } from './process-version.js';

/**
 * A running or completed process instance.
 *
 * **Authorization behavior (S-1/S-2):** Read operations on process instances
 * apply identity-scoped filtering — unauthorized callers receive an empty
 * result set rather than a 403. Write operations (abort, delete, retry) return
 * a hard 403 when the caller lacks the required claim.
 */
export interface ProcessInstance {
  /** Engine-assigned UUID. */
  id: string;
  /** UUID primary key cast to text — available for `ilike` substring search in GraphQL. */
  idText?: string;
  /** BPMN process ID (resolved from version FK). REST-only. */
  processModelId?: string;
  /** Version string (resolved from version FK). REST-only. */
  version?: string;
  /** Internal UUID of the process version. GraphQL-only. */
  processVersionId?: string;
  /** UUID of the parent process instance, if this was started by a CallActivity. */
  parentProcessInstanceId: string | null;
  /**
   * Optional user-defined business key for grouping related process instances
   * into a shared business context (e.g. an order ID from an external system).
   *
   * Never auto-generated — set explicitly via `StartRequest.businessKey` when
   * starting a process instance. Child instances created through Call Activities
   * and instances triggered by Messages or Signals inherit this value from the
   * originating instance.
   */
  businessKey: string | null;
  /** UUID of the FNI that triggered this instance (e.g. a CallActivity FNI). */
  triggererFlowNodeInstanceId: string | null;
  /** Current lifecycle state. */
  state: ProcessInstanceState;
  /** ISO 8601 timestamp when the instance was started. */
  startedAt: string;
  /** ISO 8601 timestamp when the instance reached a terminal state, or `null` if still running. */
  finishedAt: string | null;
  /** Identity snapshot of the caller who started this instance. */
  startedBy: Record<string, unknown> | null;
  /** Initial context/payload passed at start time. */
  startedWithContext: Record<string, unknown> | null;
  /** Tokens that reached end events. `null` until the instance finishes. */
  finalTokens: FinalToken[] | null;
  /** Error details when the PI is in a fatal or aborted state. See {@link ErrorInfo}. */
  errorInfo?: ErrorInfo | null;
  /** Populated when loaded via GraphQL relationship (belongs_to). */
  processVersion?: ProcessVersion;
  /** Populated when loaded via GraphQL relationship. */
  flowNodeInstances?: FlowNodeInstance[];
  /** Latest value per data object. Populated when loaded via GraphQL relationship. */
  dataObjectValues?: DataObjectValue[];
  /** Full audit trail of all DO writes. Populated when loaded via GraphQL relationship. */
  dataObjectHistory?: DataObjectValue[];
}
