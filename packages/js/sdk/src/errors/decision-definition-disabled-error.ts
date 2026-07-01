import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when an evaluation is attempted on a disabled decision definition. */
export class DecisionDefinitionDisabledError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'decision_definition_disabled', message, rawBody);
    this.name = 'DecisionDefinitionDisabledError';
  }
}
