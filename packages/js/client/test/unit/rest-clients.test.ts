import { describe, it, expect, vi, beforeEach } from 'vitest';
import { HttpTransport } from '../../src/http/transport.js';
import { ProcessClient } from '../../src/rest/process-client.js';
import { ProcessInstanceClient } from '../../src/rest/process-instance-client.js';
import { UserTaskClient } from '../../src/rest/user-task-client.js';
import { EngineClient } from '../../src/rest/engine-client.js';
import { EventClient } from '../../src/rest/event-client.js';
import { DecisionClient } from '../../src/rest/decision-client.js';
import { TimerScheduleClient } from '../../src/rest/timer-schedule-client.js';

function createMockTransport(): HttpTransport {
  return {
    get: vi.fn().mockResolvedValue({}),
    getText: vi.fn().mockResolvedValue(''),
    post: vi.fn().mockResolvedValue({}),
    put: vi.fn().mockResolvedValue(undefined),
    delete: vi.fn().mockResolvedValue(undefined),
    head: vi.fn().mockResolvedValue(undefined),
  } as unknown as HttpTransport;
}

describe('ProcessClient', () => {
  let transport: ReturnType<typeof createMockTransport>;
  let client: ProcessClient;

  beforeEach(() => {
    transport = createMockTransport();
    client = new ProcessClient(transport);
  });

  it('getAll sends GET /processes', async () => {
    await client.getAll();
    expect(transport.get).toHaveBeenCalledWith('/processes');
  });

  it('get sends GET /processes/{id}', async () => {
    await client.get('order-process');
    expect(transport.get).toHaveBeenCalledWith('/processes/order-process');
  });

  it('get includes XML query parameter when requested', async () => {
    await client.get('order-process', { includeXml: true });
    expect(transport.get).toHaveBeenCalledWith('/processes/order-process?includeXml=true');
  });

  it('get encodes special characters in process ID', async () => {
    await client.get('my process/v1');
    expect(transport.get).toHaveBeenCalledWith('/processes/my%20process%2Fv1');
  });

  it('getVersions sends GET /processes/{id}/versions', async () => {
    await client.getVersions('order-process');
    expect(transport.get).toHaveBeenCalledWith('/processes/order-process/versions');
  });

  it('getVersions includes XML query parameter', async () => {
    await client.getVersions('order-process', { includeXml: true });
    expect(transport.get).toHaveBeenCalledWith('/processes/order-process/versions?includeXml=true');
  });

  it('deploy sends POST /processes with sources array', async () => {
    await client.deploy('<bpmn:definitions/>');
    expect(transport.post).toHaveBeenCalledWith('/processes', { sources: ['<bpmn:definitions/>'] });
  });

  it('deploy accepts an array of sources', async () => {
    await client.deploy(['<xml1/>', '<xml2/>']);
    expect(transport.post).toHaveBeenCalledWith('/processes', { sources: ['<xml1/>', '<xml2/>'] });
  });

  it('start sends POST /processes/{id}/start with options', async () => {
    const options = { initialToken: { orderId: '123' } };
    await client.start('order-process', options);
    expect(transport.post).toHaveBeenCalledWith('/processes/order-process/start', options);
  });

  it('enable sends PUT /processes/{id}/enable', async () => {
    await client.enable('order-process');
    expect(transport.put).toHaveBeenCalledWith('/processes/order-process/enable');
  });

  it('disable sends PUT /processes/{id}/disable', async () => {
    await client.disable('order-process');
    expect(transport.put).toHaveBeenCalledWith('/processes/order-process/disable');
  });

  it('undeploy sends DELETE /processes/{id}', async () => {
    await client.undeploy('order-process');
    expect(transport.delete).toHaveBeenCalledWith('/processes/order-process');
  });

  it('deleteVersion sends DELETE /processes/{id}/versions/{version}', async () => {
    await client.deleteVersion('order-process', '1.0.0');
    expect(transport.delete).toHaveBeenCalledWith('/processes/order-process/versions/1.0.0');
  });
});

describe('ProcessInstanceClient', () => {
  let transport: ReturnType<typeof createMockTransport>;
  let client: ProcessInstanceClient;

  beforeEach(() => {
    transport = createMockTransport();
    client = new ProcessInstanceClient(transport);
  });

  it('abort sends PUT /process-instances/{id}/abort', async () => {
    await client.abort('pi-uuid-1');
    expect(transport.put).toHaveBeenCalledWith('/process-instances/pi-uuid-1/abort', undefined);
  });

  it('abort passes options body', async () => {
    const options = { reason: 'test' };
    await client.abort('pi-uuid-1', options);
    expect(transport.put).toHaveBeenCalledWith('/process-instances/pi-uuid-1/abort', options);
  });

  it('delete sends DELETE /process-instances/{id}', async () => {
    await client.delete('pi-uuid-1');
    expect(transport.delete).toHaveBeenCalledWith('/process-instances/pi-uuid-1');
  });

  it('retry sends PUT /process-instances/{id}/retry', async () => {
    await client.retry('pi-uuid-1', { version: '2.0.0' });
    expect(transport.put).toHaveBeenCalledWith('/process-instances/pi-uuid-1/retry', { version: '2.0.0' });
  });
});

describe('UserTaskClient', () => {
  let transport: ReturnType<typeof createMockTransport>;
  let client: UserTaskClient;

  beforeEach(() => {
    transport = createMockTransport();
    client = new UserTaskClient(transport);
  });

  it('finish sends PUT /user-tasks/{fniId}/finish', async () => {
    await client.finish('fni-uuid-1', { result: { approved: true } });
    expect(transport.put).toHaveBeenCalledWith('/user-tasks/fni-uuid-1/finish', { result: { approved: true } });
  });

  it('cancel sends PUT /user-tasks/{fniId}/cancel', async () => {
    await client.cancel('fni-uuid-1');
    expect(transport.put).toHaveBeenCalledWith('/user-tasks/fni-uuid-1/cancel', undefined);
  });
});

describe('EngineClient', () => {
  let transport: ReturnType<typeof createMockTransport>;
  let client: EngineClient;

  beforeEach(() => {
    transport = createMockTransport();
    client = new EngineClient(transport);
  });

  it('health sends HEAD /health without auth, expecting 204', async () => {
    await client.health();
    expect(transport.head).toHaveBeenCalledWith('/health', { skipAuth: true, expect: 204 });
  });

  it('info sends GET /info without auth', async () => {
    await client.info();
    expect(transport.get).toHaveBeenCalledWith('/info', { skipAuth: true });
  });

  it('stats sends GET /stats with auth', async () => {
    await client.stats();
    expect(transport.get).toHaveBeenCalledWith('/stats');
  });

  it('metrics sends getText /metrics without auth', async () => {
    await client.metrics();
    expect(transport.getText).toHaveBeenCalledWith('/metrics', { skipAuth: true });
  });
});

describe('EventClient', () => {
  let transport: ReturnType<typeof createMockTransport>;
  let client: EventClient;

  beforeEach(() => {
    transport = createMockTransport();
    client = new EventClient(transport);
  });

  it('triggerMessage sends POST /messages/{messageName}/trigger with payload', async () => {
    await client.triggerMessage('payment-received', { orderId: '123' });
    expect(transport.post).toHaveBeenCalledWith('/messages/payment-received/trigger', {
      payload: { orderId: '123' },
      correlation: undefined,
    });
  });

  it('triggerMessage includes options in body', async () => {
    await client.triggerMessage('payment-received', { orderId: '123' }, { correlation: 'order-123' });
    expect(transport.post).toHaveBeenCalledWith('/messages/payment-received/trigger', {
      payload: { orderId: '123' },
      correlation: 'order-123',
    });
  });

  it('triggerSignal sends POST /signals/{signalName}/trigger with empty body', async () => {
    await client.triggerSignal('order-cancelled');
    expect(transport.post).toHaveBeenCalledWith('/signals/order-cancelled/trigger', {});
  });

  it('triggerSignal sends POST /signals/{signalName}/trigger', async () => {
    await client.triggerSignal('system-shutdown');
    expect(transport.post).toHaveBeenCalledWith('/signals/system-shutdown/trigger', {});
  });

  it('triggerTimer sends POST /timer-events/{fniId}/trigger with empty body', async () => {
    await client.triggerTimer('fni-uuid-123');
    expect(transport.post).toHaveBeenCalledWith('/timer-events/fni-uuid-123/trigger', {});
  });

  it('triggerEscalation sends POST /escalations/{code}/trigger with empty body', async () => {
    await client.triggerEscalation('ESC_REVIEW');
    expect(transport.post).toHaveBeenCalledWith('/escalations/ESC_REVIEW/trigger', {});
  });
});

describe('DecisionClient', () => {
  let transport: ReturnType<typeof createMockTransport>;
  let client: DecisionClient;

  beforeEach(() => {
    transport = createMockTransport();
    client = new DecisionClient(transport);
  });

  it('getAll sends GET /decisions', async () => {
    await client.getAll();
    expect(transport.get).toHaveBeenCalledWith('/decisions');
  });

  it('get sends GET /decisions/{id}', async () => {
    await client.get('discount-rules');
    expect(transport.get).toHaveBeenCalledWith('/decisions/discount-rules');
  });

  it('get includes XML query parameter when requested', async () => {
    await client.get('discount-rules', { includeXml: true });
    expect(transport.get).toHaveBeenCalledWith('/decisions/discount-rules?includeXml=true');
  });

  it('get encodes the decision definition id when includeXml is true', async () => {
    const decisionDefinitionId = 'rules v2/alpha';
    await client.get(decisionDefinitionId, { includeXml: true });
    const encodedId = encodeURIComponent(decisionDefinitionId);
    expect(transport.get).toHaveBeenCalledWith(`/decisions/${encodedId}?includeXml=true`);
  });

  it('getVersions sends GET /decisions/{id}/versions', async () => {
    await client.getVersions('discount-rules');
    expect(transport.get).toHaveBeenCalledWith('/decisions/discount-rules/versions');
  });

  it('getVersions includes XML query parameter when requested', async () => {
    await client.getVersions('discount-rules', { includeXml: true });
    expect(transport.get).toHaveBeenCalledWith('/decisions/discount-rules/versions?includeXml=true');
  });

  it('getVersions encodes the decision definition id when includeXml is true', async () => {
    const decisionDefinitionId = 'rules v2/alpha';
    await client.getVersions(decisionDefinitionId, { includeXml: true });
    const encodedId = encodeURIComponent(decisionDefinitionId);
    expect(transport.get).toHaveBeenCalledWith(`/decisions/${encodedId}/versions?includeXml=true`);
  });

  it('deploy sends POST /decisions with sources array', async () => {
    const sources = ['<dmn:definitions/>', '<dmn:definitions id="two"/>'];
    await client.deploy(sources);
    expect(transport.post).toHaveBeenCalledWith('/decisions', { sources });
  });

  it('deploy wraps a single string source in an array', async () => {
    await client.deploy('<dmn:definitions/>');
    expect(transport.post).toHaveBeenCalledWith('/decisions', { sources: ['<dmn:definitions/>'] });
  });

  it('enable sends PUT /decisions/{id}/enable', async () => {
    await client.enable('discount-rules');
    expect(transport.put).toHaveBeenCalledWith('/decisions/discount-rules/enable');
  });

  it('disable sends PUT /decisions/{id}/disable', async () => {
    await client.disable('discount-rules');
    expect(transport.put).toHaveBeenCalledWith('/decisions/discount-rules/disable');
  });

  it('undeploy sends DELETE /decisions/{id}', async () => {
    await client.undeploy('discount-rules');
    expect(transport.delete).toHaveBeenCalledWith('/decisions/discount-rules');
  });

  it('deleteVersion sends DELETE /decisions/{id}/versions/{version}', async () => {
    await client.deleteVersion('discount-rules', '1.0.0');
    expect(transport.delete).toHaveBeenCalledWith('/decisions/discount-rules/versions/1.0.0');
  });

  it('evaluate sends POST /decisions/{id}/evaluate with input body', async () => {
    const input = { age: 30, risk: 'low' };
    await client.evaluate('discount-rules', input);
    expect(transport.post).toHaveBeenCalledWith('/decisions/discount-rules/evaluate', { input });
  });

  it('evaluate sends decisionModelId and includeUnmatchedDetails when provided', async () => {
    const input = { amount: 150 };
    await client.evaluate('discount-rules', input, {
      decisionModelId: 'Decision_discount',
      includeUnmatchedDetails: true,
    });
    expect(transport.post).toHaveBeenCalledWith('/decisions/discount-rules/evaluate', {
      input,
      decisionModelId: 'Decision_discount',
      includeUnmatchedDetails: true,
    });
  });

  it('evaluateService sends POST to /decisions/{id}/services/{serviceId}/evaluate with encoded IDs', async () => {
    const decisionDefinitionId = 'my rules/v2';
    const serviceId = 'DS order/fulfillment';
    const input = { orderId: '123' };
    await client.evaluateService(decisionDefinitionId, serviceId, input);
    const encodedId = encodeURIComponent(decisionDefinitionId);
    const encodedServiceId = encodeURIComponent(serviceId);
    expect(transport.post).toHaveBeenCalledWith(
      `/decisions/${encodedId}/services/${encodedServiceId}/evaluate`,
      { input },
    );
  });

  it('evaluateService passes input in body', async () => {
    const input = { customerTier: 'gold', amount: 500 };
    await client.evaluateService('discount-rules', 'DS_discount', input);
    expect(transport.post).toHaveBeenCalledWith('/decisions/discount-rules/services/DS_discount/evaluate', {
      input,
    });
  });

  it('evaluateService includes includeUnmatchedDetails when provided', async () => {
    const input = { amount: 150 };
    await client.evaluateService('discount-rules', 'DS_discount', input, {
      includeUnmatchedDetails: true,
    });
    expect(transport.post).toHaveBeenCalledWith('/decisions/discount-rules/services/DS_discount/evaluate', {
      input,
      includeUnmatchedDetails: true,
    });
  });

  it('evaluateByVersion sends POST to /decisions/{id}/versions/{version}/evaluate', async () => {
    const input = { age: 30 };
    await client.evaluateByVersion('discount-rules', 'abc123', input);
    expect(transport.post).toHaveBeenCalledWith('/decisions/discount-rules/versions/abc123/evaluate', {
      input,
    });
  });

  it('evaluateByVersion sends decisionModelId and includeUnmatchedDetails when provided', async () => {
    const input = { amount: 150 };
    await client.evaluateByVersion('discount-rules', 'abc123', input, {
      decisionModelId: 'Decision_discount',
      includeUnmatchedDetails: true,
    });
    expect(transport.post).toHaveBeenCalledWith('/decisions/discount-rules/versions/abc123/evaluate', {
      input,
      decisionModelId: 'Decision_discount',
      includeUnmatchedDetails: true,
    });
  });

  it('evaluateByVersion encodes special characters in id and version', async () => {
    const decisionDefinitionId = 'my rules/v2';
    const version = '1.0.0+build';
    const input = { x: 1 };
    await client.evaluateByVersion(decisionDefinitionId, version, input);
    const encodedId = encodeURIComponent(decisionDefinitionId);
    const encodedVersion = encodeURIComponent(version);
    expect(transport.post).toHaveBeenCalledWith(
      `/decisions/${encodedId}/versions/${encodedVersion}/evaluate`,
      { input },
    );
  });

  it('encodes special characters in decision definition id and version', async () => {
    const decisionDefinitionId = 'my rules/v2';
    const versionString = '1.0.0+build';
    await client.get(decisionDefinitionId);
    await client.getVersions(decisionDefinitionId);
    await client.enable(decisionDefinitionId);
    await client.disable(decisionDefinitionId);
    await client.undeploy(decisionDefinitionId);
    await client.deleteVersion(decisionDefinitionId, versionString);
    await client.evaluate(decisionDefinitionId, { x: 1 });
    const encodedId = encodeURIComponent(decisionDefinitionId);
    const encodedVersion = encodeURIComponent(versionString);
    expect(transport.get).toHaveBeenCalledWith(`/decisions/${encodedId}`);
    expect(transport.get).toHaveBeenCalledWith(`/decisions/${encodedId}/versions`);
    expect(transport.put).toHaveBeenCalledWith(`/decisions/${encodedId}/enable`);
    expect(transport.put).toHaveBeenCalledWith(`/decisions/${encodedId}/disable`);
    expect(transport.delete).toHaveBeenCalledWith(`/decisions/${encodedId}`);
    expect(transport.delete).toHaveBeenCalledWith(`/decisions/${encodedId}/versions/${encodedVersion}`);
    expect(transport.post).toHaveBeenCalledWith(`/decisions/${encodedId}/evaluate`, { input: { x: 1 } });
  });
});

describe('TimerScheduleClient', () => {
  let transport: ReturnType<typeof createMockTransport>;
  let client: TimerScheduleClient;

  beforeEach(() => {
    transport = createMockTransport();
    client = new TimerScheduleClient(transport);
  });

  it('list sends GET /timer-schedules and unwraps data', async () => {
    const schedules = [
      {
        id: 'sched-1',
        processModelId: 'cycle-start',
        processVersionId: 'ver-1',
        flowNodeId: 'Start_timer',
        kind: 'cycle',
        isoSpec: 'R/PT1H',
        enabled: true,
        nextFireAt: '2026-08-24T12:00:00Z',
        lastTriggeredAt: null,
        cycleTotal: null,
        cycleRemaining: null,
      },
    ];
    vi.mocked(transport.get).mockResolvedValueOnce({ data: schedules });
    const result = await client.list();
    expect(transport.get).toHaveBeenCalledWith('/timer-schedules');
    expect(result).toEqual(schedules);
  });

  it('list appends processVersionId and enabled query parameters', async () => {
    vi.mocked(transport.get).mockResolvedValueOnce({ data: [] });
    await client.list({ processVersionId: 'ver-1', enabled: false });
    expect(transport.get).toHaveBeenCalledWith('/timer-schedules?processVersionId=ver-1&enabled=false');
  });

  it('get sends GET /timer-schedules/{id} and unwraps data', async () => {
    const schedule = {
      id: 'sched-1',
      processModelId: 'cycle-start',
      processVersionId: 'ver-1',
      flowNodeId: 'Start_timer',
      kind: 'cycle',
      isoSpec: 'R/PT1H',
      enabled: true,
      nextFireAt: null,
      lastTriggeredAt: null,
      cycleTotal: null,
      cycleRemaining: null,
    };
    vi.mocked(transport.get).mockResolvedValueOnce({ data: schedule });
    const result = await client.get('sched-1');
    expect(transport.get).toHaveBeenCalledWith('/timer-schedules/sched-1');
    expect(result).toEqual(schedule);
  });

  it('enable sends PUT /timer-schedules/{id}/enable', async () => {
    await client.enable('sched-1');
    expect(transport.put).toHaveBeenCalledWith('/timer-schedules/sched-1/enable');
  });

  it('disable sends PUT /timer-schedules/{id}/disable', async () => {
    await client.disable('sched-1');
    expect(transport.put).toHaveBeenCalledWith('/timer-schedules/sched-1/disable');
  });

  it('encodes special characters in schedule id', async () => {
    const scheduleId = 'sched/one';
    vi.mocked(transport.get).mockResolvedValueOnce({ data: { id: scheduleId } });
    await client.get(scheduleId);
    await client.enable(scheduleId);
    await client.disable(scheduleId);
    const encodedId = encodeURIComponent(scheduleId);
    expect(transport.get).toHaveBeenCalledWith(`/timer-schedules/${encodedId}`);
    expect(transport.put).toHaveBeenCalledWith(`/timer-schedules/${encodedId}/enable`);
    expect(transport.put).toHaveBeenCalledWith(`/timer-schedules/${encodedId}/disable`);
  });
});
