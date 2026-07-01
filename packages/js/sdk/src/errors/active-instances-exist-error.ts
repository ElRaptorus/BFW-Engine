import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when trying to delete a process with active instances. */
export class ActiveInstancesExistError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(409, 'active_instances_exist', message, rawBody);
    this.name = 'ActiveInstancesExistError';
  }
}
