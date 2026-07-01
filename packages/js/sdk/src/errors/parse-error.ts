import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when BPMN XML parsing fails. */
export class ParseError extends DaemonEngineError {
  constructor(
    message: string,
    public readonly failures: { file: string; details: string[] }[],
    rawBody?: Record<string, unknown>,
  ) {
    super(400, 'parse_error', message, rawBody);
    this.name = 'ParseError';
  }
}
