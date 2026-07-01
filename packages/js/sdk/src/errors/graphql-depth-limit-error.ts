import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when a GraphQL query exceeds the configured depth limit (EVIL_GRAPHQL_MAX_DEPTH). */
export class GraphqlDepthLimitError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(200, 'graphql_depth_limit', message, rawBody);
    this.name = 'GraphqlDepthLimitError';
  }
}
