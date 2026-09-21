import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown on HTTP 400 malformed requests. */
export class BadRequestError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(400, 'bad_request', message, rawBody);
    this.name = 'BadRequestError';
  }
}
