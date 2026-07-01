import type { FniFinishedEvent } from './types.js';

export class EventTracker {
  private trackedFnis: Map<string, FniFinishedEvent> = new Map();

  handleEvent = (event: Record<string, unknown>): void => {
    if (event.flowNodeType !== 'business_rule_task') return;
    const payload = event.payload as Record<string, unknown> | undefined;
    const typeProperties = payload?.typeProperties as Record<string, unknown> | undefined;
    if (typeProperties?.mode !== 'dmn') return;

    const fniId = event.flowNodeInstanceId as string;
    this.trackedFnis.set(fniId, event as unknown as FniFinishedEvent);
  };

  getTrackedFnis(): string[] {
    return Array.from(this.trackedFnis.keys());
  }

  getCount(): number {
    return this.trackedFnis.size;
  }

  getEvents(): FniFinishedEvent[] {
    return Array.from(this.trackedFnis.values());
  }

  reset(): void {
    this.trackedFnis.clear();
  }
}
