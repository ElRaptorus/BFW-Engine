import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when trying to delete a process with active instances. */
export class ActiveInstancesExistError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(409, 'active_instances_exist', message, rawBody);
    this.name = 'ActiveInstancesExistError';
  }
}
