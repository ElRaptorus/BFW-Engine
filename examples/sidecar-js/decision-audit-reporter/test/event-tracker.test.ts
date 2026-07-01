import { describe, expect, it } from 'vitest';

import { EventTracker } from '../src/event-tracker.js';

function buildDmnFinishedEvent(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    flowNodeInstanceId: 'fni-1',
    processInstanceId: 'pi-1',
    flowNodeId: 'BRT_1',
    flowNodeType: 'business_rule_task',
    terminalState: 'completed',
    occurredAt: '2026-05-20T12:00:00Z',
    payload: {
      typeProperties: {
        mode: 'dmn',
        decision_ref: 'employee-benefits',
        duration_us: 1500,
        matched_rules: ['rule_1'],
      },
    },
    ...overrides,
  };
}

describe('EventTracker', () => {
  it('records FNI finished events for BRT+DMN only', () => {
    const tracker = new EventTracker();
    tracker.handleEvent(buildDmnFinishedEvent());

    expect(tracker.getCount()).toBe(1);
    expect(tracker.getTrackedFnis()).toEqual(['fni-1']);
    expect(tracker.getEvents()[0].flowNodeInstanceId).toBe('fni-1');
  });

  it('ignores non-BRT and non-DMN events', () => {
    const tracker = new EventTracker();

    tracker.handleEvent({
      ...buildDmnFinishedEvent(),
      flowNodeType: 'service_task',
    });

    tracker.handleEvent({
      ...buildDmnFinishedEvent(),
      payload: { typeProperties: { mode: 'feel' } },
    });

    tracker.handleEvent({
      flowNodeType: 'business_rule_task',
      flowNodeInstanceId: 'fni-2',
      payload: { typeProperties: { mode: 'dmn' } },
    });

    expect(tracker.getCount()).toBe(1);
    expect(tracker.getTrackedFnis()).toEqual(['fni-2']);
  });

  it('getCount and getTrackedFnis work correctly', () => {
    const tracker = new EventTracker();
    tracker.handleEvent(buildDmnFinishedEvent({ flowNodeInstanceId: 'fni-a' }));
    tracker.handleEvent(buildDmnFinishedEvent({ flowNodeInstanceId: 'fni-b' }));

    expect(tracker.getCount()).toBe(2);
    expect(tracker.getTrackedFnis()).toEqual(['fni-a', 'fni-b']);
  });

  it('reset clears state', () => {
    const tracker = new EventTracker();
    tracker.handleEvent(buildDmnFinishedEvent());
    tracker.reset();

    expect(tracker.getCount()).toBe(0);
    expect(tracker.getTrackedFnis()).toEqual([]);
    expect(tracker.getEvents()).toEqual([]);
  });
});
