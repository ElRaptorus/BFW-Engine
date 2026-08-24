/** Optional parameters for message triggering. */
export interface TriggerOptions {
  /** Correlation value to match against waiting intermediate catch events. */
  correlation?: string;
}

/** Concrete result of a message trigger. */
export interface MessageTriggerResult {
  messageId: string;
  messageName: string;
  correlationValue: string | null;
  deliveries: { processInstanceId: string; flowNodeInstanceId: string }[];
  startedProcessInstanceIds: string[];
  pending: boolean;
}

/** Concrete result of a signal trigger. */
export interface SignalTriggerResult {
  signalId: string;
  signalName: string;
  deliveries: { processInstanceId: string; flowNodeInstanceId: string }[];
  startedProcessInstanceIds: string[];
  pending: boolean;
}

/** Result of a timer event manual trigger. */
export interface TimerTriggerResult {
  triggered: boolean;
}

/** Concrete result of an escalation inject. */
export interface EscalationTriggerResult {
  escalationCode: string;
  deliveries: { processInstanceId: string; flowNodeInstanceId: string }[];
  pending: false;
}

/** Union of all trigger result types. */
export type TriggerResult =
  | MessageTriggerResult
  | SignalTriggerResult
  | TimerTriggerResult
  | EscalationTriggerResult;
