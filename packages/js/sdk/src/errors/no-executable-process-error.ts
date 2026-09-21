import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when the BPMN has no executable process. */
export class NoExecutableProcessError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'no_executable_process', message, rawBody);
    this.name = 'NoExecutableProcessError';
  }
}
