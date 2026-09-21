import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when BPMN XML parsing fails. */
export class ParseError extends BfwEngineError {
  constructor(
    message: string,
    public readonly failures: { file: string; details: string[] }[],
    rawBody?: Record<string, unknown>,
  ) {
    super(400, 'parse_error', message, rawBody);
    this.name = 'ParseError';
  }
}
