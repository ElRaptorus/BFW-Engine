import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when a retry checkpoint targets a parallel or inclusive join gateway FNI. */
export class RetryCheckpointIsJoinGatewayError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'retry_checkpoint_is_join_gateway', message, rawBody);
    this.name = 'RetryCheckpointIsJoinGatewayError';
  }
}
