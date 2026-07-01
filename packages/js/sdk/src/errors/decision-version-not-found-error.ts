import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when the requested decision version does not exist. */
export class DecisionVersionNotFoundError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(404, 'decision_version_not_found', message, rawBody);
    this.name = 'DecisionVersionNotFoundError';
  }
}
