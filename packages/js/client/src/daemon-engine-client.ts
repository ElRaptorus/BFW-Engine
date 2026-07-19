import { GraphqlClient } from './graphql/graphql-client.js';
import { HttpTransport } from './http/transport.js';
import type { JwtFactory } from './identity/types.js';
import { AdHocSubprocessClient } from './rest/adhoc-subprocess-client.js';
import { DecisionClient } from './rest/decision-client.js';
import { EngineClient } from './rest/engine-client.js';
import { EventClient } from './rest/event-client.js';
import { ProcessClient } from './rest/process-client.js';
import { ProcessInstanceClient } from './rest/process-instance-client.js';
import { UserTaskClient } from './rest/user-task-client.js';
import { NotificationClient } from './ws/notification-client.js';

export interface DaemonEngineClientOptions {
  /**
   * Override the WebSocket URL. When omitted the WS URL is derived from
   * the HTTP URL by replacing `http` with `ws` and appending `/socket`.
   * Set this explicitly when the engine exposes HTTP and WebSocket on
   * different ports (e.g. 4100 for HTTP, 4101 for WS).
   */
  wsUrl?: string;
}

/**
 * Main entry point for the Engine client. Wires all sub-clients
 * with a shared HTTP transport and JWT factory.
 *
 * ```ts
 * const client = new DaemonEngineClient('http://localhost:4000', 'my-jwt');
 * const models = await client.processes.getAll();
 * client.dispose();
 * ```
 */
export class DaemonEngineClient {
  public readonly processes: ProcessClient;
  public readonly processInstances: ProcessInstanceClient;
  public readonly userTasks: UserTaskClient;
  public readonly engine: EngineClient;
  public readonly events: EventClient;
  public readonly decisions: DecisionClient;
  public readonly graphql: GraphqlClient;
  public readonly notifications: NotificationClient;
  public readonly adHocSubprocesses: AdHocSubprocessClient;

  private readonly transport: HttpTransport;

  constructor(url: string, jwtFactory: JwtFactory, options?: DaemonEngineClientOptions) {
    this.transport = new HttpTransport(url, jwtFactory);

    this.processes = new ProcessClient(this.transport);
    this.processInstances = new ProcessInstanceClient(this.transport);
    this.userTasks = new UserTaskClient(this.transport);
    this.engine = new EngineClient(this.transport);
    this.events = new EventClient(this.transport);
    this.decisions = new DecisionClient(this.transport);
    this.graphql = new GraphqlClient(this.transport);
    this.adHocSubprocesses = new AdHocSubprocessClient(this.transport);

    const wsUrl = options?.wsUrl ?? url.replace(/^http/, 'ws') + '/socket';
    this.notifications = new NotificationClient(wsUrl, jwtFactory);
  }

  /** Clean up all connections (WebSocket channels, etc.). */
  dispose(): void {
    this.notifications.disconnect();
  }
}
