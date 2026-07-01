import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when a deploy creates a version conflict. */
export class VersionExistsError extends DaemonEngineError {
  constructor(
    message: string,
    public readonly conflicts: { processModelId: string; version: string }[],
    rawBody?: Record<string, unknown>,
  ) {
    super(409, 'version_exists', message, rawBody);
    this.name = 'VersionExistsError';
  }
}
