/** Context provided to a timer source handler for evaluation. */
export interface TimerContext {
  processInstanceId: string;
  flowNodeInstanceId: string;
  flowNodeId: string;
  now: string;
}

/** Handler interface for timer source plugins. */
export interface TimerSourceHandler {
  timerType(): string;
  evaluate(definition: string, context: TimerContext): Promise<unknown>;
}
