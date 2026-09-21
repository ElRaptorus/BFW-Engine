import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when introspection queries are blocked (BFE_GRAPHQL_INTROSPECTION_DISABLED=true). */
export class GraphqlIntrospectionDisabledError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(200, 'graphql_introspection_disabled', message, rawBody);
    this.name = 'GraphqlIntrospectionDisabledError';
  }
}
