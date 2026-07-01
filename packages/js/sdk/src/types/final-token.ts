/**
 * A token that reached an end event, capturing the end event identity and
 * the payload at that point.
 */
export interface FinalToken {
  /** BPMN ID of the end event that this token reached. */
  endEventId: string;
  /** Optional human-readable name of the end event. */
  endEventName?: string;
  /** The payload carried by the token when it reached the end event. */
  payload: Record<string, unknown>;
}
