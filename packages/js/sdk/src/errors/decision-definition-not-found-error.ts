import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when the requested decision definition does not exist. */
export class DecisionDefinitionNotFoundError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(404, 'decision_definition_not_found', message, rawBody);
    this.name = 'DecisionDefinitionNotFoundError';
  }
}
