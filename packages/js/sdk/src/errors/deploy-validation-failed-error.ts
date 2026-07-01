import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when BPMN deploy validation fails. Distinct from generic ValidationError. */
export class DeployValidationFailedError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'validation_failed', message, rawBody);
    this.name = 'DeployValidationFailedError';
  }
}
