import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when retry with version migration targets an incompatible version. */
export class IncompatibleVersionMigrationError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'version_migration_incompatible', message, rawBody);
    this.name = 'IncompatibleVersionMigrationError';
  }
}
