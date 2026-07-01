// Main client
export { DaemonEngineClient } from './daemon-engine-client.js';
export type { DaemonEngineClientOptions } from './daemon-engine-client.js';

// Sub-clients
export { DecisionClient } from './rest/decision-client.js';
export { ProcessClient } from './rest/process-client.js';
export { ProcessInstanceClient } from './rest/process-instance-client.js';
export { UserTaskClient } from './rest/user-task-client.js';
export { EngineClient } from './rest/engine-client.js';
export { EventClient } from './rest/event-client.js';
export { GraphqlClient } from './graphql/graphql-client.js';
export { NotificationClient } from './ws/notification-client.js';

// HTTP transport
export { HttpTransport } from './http/transport.js';
export type { RequestOptions } from './http/transport.js';

// Identity
export type { JwtFactory } from './identity/types.js';
export { resolveToken } from './identity/resolve-token.js';

// Error mapping
export { mapResponseError } from './errors/error-mapper.js';

// WebSocket types
export type {
  Subscription,
  SocketOpenCallback,
  SocketCloseCallback,
  SocketErrorCallback,
} from './ws/notification-client.js';
