import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when a GraphQL query exceeds the configured depth limit (BFE_GRAPHQL_MAX_DEPTH). */
export class GraphqlDepthLimitError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(200, 'graphql_depth_limit', message, rawBody);
    this.name = 'GraphqlDepthLimitError';
  }
}
