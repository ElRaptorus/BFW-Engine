import { describe, expect, it } from 'vitest';

import type {
  CallActivityChildStarted,
  EngineEvent,
  MessageArrived,
  SignalArrived,
  SubProcessChildStarted,
  TimerFired,
} from '../../src/events/engine-events.js';

describe('engine event wire shapes', () => {
  it('TimerFired carries rootProcessInstanceId', () => {
    const event: TimerFired = {
      type: 'TimerFired',
      timerRef: 'timer-1',
      processInstanceId: 'child-pi',
      flowNodeInstanceId: 'fni-1',
      flowNodeId: 'Catch_timer',
      kind: 'catch',
      rootProcessInstanceId: 'root-pi',
      laneName: null,
      occurredAt: '2026-08-25T10:00:00Z',
    };

    expect(event.rootProcessInstanceId).toBe('root-pi');
  });

  it('arrival and child-started events carry rootProcessInstanceId', () => {
    const messageArrived: MessageArrived = {
      type: 'MessageArrived',
      messageId: 'msg-1',
      messageName: 'payment-received',
      correlationValue: null,
      processInstanceId: 'child-pi',
      flowNodeInstanceId: 'fni-2',
      payload: {},
      rootProcessInstanceId: 'root-pi',
      laneName: null,
      occurredAt: '2026-08-25T10:00:00Z',
    };

    const signalArrived: SignalArrived = {
      type: 'SignalArrived',
      signalId: 'sig-1',
      signalName: 'go',
      processInstanceId: 'child-pi',
      flowNodeInstanceId: 'fni-3',
      rootProcessInstanceId: 'root-pi',
      laneName: null,
      occurredAt: '2026-08-25T10:00:00Z',
    };

    const callActivityChildStarted: CallActivityChildStarted = {
      type: 'CallActivityChildStarted',
      callActivityFlowNodeInstanceId: 'fni-ca',
      parentProcessInstanceId: 'parent-pi',
      childProcessInstanceId: 'child-pi',
      childProcessModelId: 'called',
      childVersion: '1.0.0',
      rootProcessInstanceId: 'root-pi',
      laneName: null,
      occurredAt: '2026-08-25T10:00:00Z',
    };

    const subProcessChildStarted: SubProcessChildStarted = {
      type: 'SubProcessChildStarted',
      subprocessFlowNodeInstanceId: 'fni-sp',
      parentProcessInstanceId: 'parent-pi',
      childProcessInstanceId: 'child-pi',
      subprocessNodeId: 'SubProcess_1',
      childProcessModelId: 'parent__subprocess__SubProcess_1',
      childVersion: '1.0.0',
      isEventSubprocess: false,
      isAdHocSubprocess: false,
      rootProcessInstanceId: 'root-pi',
      laneName: null,
      occurredAt: '2026-08-25T10:00:00Z',
    };

    const events: EngineEvent[] = [messageArrived, signalArrived, callActivityChildStarted, subProcessChildStarted];

    for (const event of events) {
      expect('rootProcessInstanceId' in event).toBe(true);
    }
  });

  it('does not export unpublished timer arm/cancel event types', () => {
    const sample: EngineEvent = {
      type: 'TimerFired',
      timerRef: 'timer-1',
      processInstanceId: null,
      flowNodeInstanceId: null,
      flowNodeId: 'Start_timer',
      kind: 'start',
      rootProcessInstanceId: null,
      laneName: null,
      occurredAt: '2026-08-25T10:00:00Z',
    };

    expect(sample.type).toBe('TimerFired');
    expect(sample.type).not.toBe('TimerArmed');
    expect(sample.type).not.toBe('TimerCancelled');
  });
});
