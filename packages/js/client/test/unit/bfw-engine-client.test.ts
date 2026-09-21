import { describe, it, expect, vi } from 'vitest';
import { BfwEngineClient } from '../../src/bfw-engine-client.js';
import { ProcessClient } from '../../src/rest/process-client.js';
import { ProcessInstanceClient } from '../../src/rest/process-instance-client.js';
import { UserTaskClient } from '../../src/rest/user-task-client.js';
import { EngineClient } from '../../src/rest/engine-client.js';
import { EventClient } from '../../src/rest/event-client.js';
import { DecisionClient } from '../../src/rest/decision-client.js';
import { GraphqlClient } from '../../src/graphql/graphql-client.js';
import { NotificationClient } from '../../src/ws/notification-client.js';
import { AdHocSubprocessClient } from '../../src/rest/adhoc-subprocess-client.js';
import { TimerScheduleClient } from '../../src/rest/timer-schedule-client.js';

vi.mock('phoenix', () => ({
  Socket: vi.fn().mockImplementation(() => ({
    connect: vi.fn(),
    disconnect: vi.fn(),
    channel: vi.fn().mockReturnValue({
      join: vi.fn(),
      on: vi.fn(),
      off: vi.fn(),
      leave: vi.fn(),
    }),
  })),
}));

describe('BfwEngineClient', () => {
  it('wires all sub-clients on construction', () => {
    const client = new BfwEngineClient('http://localhost:4000', 'my-jwt');

    expect(client.processes).toBeInstanceOf(ProcessClient);
    expect(client.processInstances).toBeInstanceOf(ProcessInstanceClient);
    expect(client.userTasks).toBeInstanceOf(UserTaskClient);
    expect(client.engine).toBeInstanceOf(EngineClient);
    expect(client.events).toBeInstanceOf(EventClient);
    expect(client.decisions).toBeInstanceOf(DecisionClient);
    expect(client.graphql).toBeInstanceOf(GraphqlClient);
    expect(client.notifications).toBeInstanceOf(NotificationClient);
    expect(client.adHocSubprocesses).toBeInstanceOf(AdHocSubprocessClient);
    expect(client.timerSchedules).toBeInstanceOf(TimerScheduleClient);
  });

  it('derives the WebSocket URL from the HTTP URL', () => {
    const client = new BfwEngineClient('http://localhost:4000', 'jwt');
    expect(client.notifications).toBeInstanceOf(NotificationClient);
  });

  it('derives wss:// from https://', () => {
    const client = new BfwEngineClient('https://engine.example.com', 'jwt');
    expect(client.notifications).toBeInstanceOf(NotificationClient);
  });

  it('dispose disconnects the notification client', () => {
    const client = new BfwEngineClient('http://localhost:4000', 'jwt');
    const disconnectSpy = vi.spyOn(client.notifications, 'disconnect');

    client.dispose();
    expect(disconnectSpy).toHaveBeenCalledOnce();
  });

  it('accepts a factory function as JWT', () => {
    const factory = vi.fn().mockReturnValue('dynamic-jwt');
    const client = new BfwEngineClient('http://localhost:4000', factory);
    expect(client.processes).toBeInstanceOf(ProcessClient);
  });
});
