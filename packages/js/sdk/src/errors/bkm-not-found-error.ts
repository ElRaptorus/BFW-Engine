import { BfwEngineError } from './bfw-engine-error.js';

export class BkmNotFoundError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(404, 'bkm_not_found', message, rawBody);
    this.name = 'BkmNotFoundError';
  }
}
