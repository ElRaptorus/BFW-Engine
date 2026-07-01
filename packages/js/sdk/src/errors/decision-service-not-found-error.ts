import { DaemonEngineError } from './daemon-engine-error.js';

export class DecisionServiceNotFoundError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(404, 'service_not_found', message, rawBody);
    this.name = 'DecisionServiceNotFoundError';
  }
}
