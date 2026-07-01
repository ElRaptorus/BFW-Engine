import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when retry with version migration targets an incompatible version. */
export class IncompatibleVersionMigrationError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'incompatible_version_migration', message, rawBody);
    this.name = 'IncompatibleVersionMigrationError';
  }
}
