import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when DMN XML parsing fails. */
export class DmnParseError extends DaemonEngineError {
  constructor(
    message: string,
    public readonly failures: { file: string; details: string[] }[],
    rawBody?: Record<string, unknown>,
  ) {
    super(400, 'dmn_parse_error', message, rawBody);
    this.name = 'DmnParseError';
  }
}
