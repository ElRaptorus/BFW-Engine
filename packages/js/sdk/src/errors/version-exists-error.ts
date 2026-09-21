import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when a deploy creates a version conflict. */
export class VersionExistsError extends BfwEngineError {
  constructor(
    message: string,
    public readonly conflicts: { processModelId: string; version: string }[],
    rawBody?: Record<string, unknown>,
  ) {
    super(409, 'version_exists', message, rawBody);
    this.name = 'VersionExistsError';
  }
}
