import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when attempting to retry a process instance that has a Transaction subprocess ancestor in the process tree.
 * Retrying such nested PIs independently would violate transactional atomicity; retry from the transaction shell or
 * further upstream instead. */
export class RetryInsideTransactionScopeError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'retry_inside_transaction_scope', message, rawBody);
    this.name = 'RetryInsideTransactionScopeError';
  }
}
