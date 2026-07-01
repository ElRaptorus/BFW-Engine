import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when a process exists but has no active (enabled) version. */
export class NoActiveVersionError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(404, 'no_active_version', message, rawBody);
    this.name = 'NoActiveVersionError';
  }
}
