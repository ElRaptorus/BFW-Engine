import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when a GraphQL query exceeds the configured complexity limit (TDE_GRAPHQL_MAX_COMPLEXITY). */
export class GraphqlComplexityLimitError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(200, 'graphql_complexity_limit', message, rawBody);
    this.name = 'GraphqlComplexityLimitError';
  }
}
