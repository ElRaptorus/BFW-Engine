import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when introspection queries are blocked (EVIL_GRAPHQL_INTROSPECTION_DISABLED=true). */
export class GraphqlIntrospectionDisabledError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(200, 'graphql_introspection_disabled', message, rawBody);
    this.name = 'GraphqlIntrospectionDisabledError';
  }
}
