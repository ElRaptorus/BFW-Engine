/** Context provided to a timer source handler for evaluation. */
export interface TimerContext {
  processInstanceId: string;
  flowNodeInstanceId: string;
  flowNodeId: string;
  now: string;
}

/**
 * Handler interface for timer source plugins.
 *
 * Not implemented in v1. `registerTimerSource` is accepted and unused at
 * runtime — custom timer dialects are reserved for a later release.
 */
export interface TimerSourceHandler {
  timerType(): string;
  evaluate(definition: string, context: TimerContext): Promise<unknown>;
}
