import type { SidecarPlugin } from '@elraptorus/daemonengine_sdk';

import { AnalyticsCollector } from './analytics-collector.js';
import { ReportFormatter } from './report-formatter.js';

// Forward-looking: requires the gRPC sidecar bridge from BPMN Phase 5.
// This code demonstrates the intended API shape. Use the mocked SDK in tests.

async function main(): Promise<void> {
  const plugin: SidecarPlugin = {
    name: 'decision-analytics-sidecar',
    connect: async () => {},
    register: async () => {},
    onEvent: (_filter, _handler) => {},
    disconnect: async () => {},
  };

  await plugin.connect();
  await plugin.register();

  const collector = new AnalyticsCollector();

  plugin.onEvent({ eventTypes: ['fni.finished'] }, (event) => {
    const payload = event.payload as Record<string, unknown> | undefined;
    const typeProperties = payload?.typeProperties as Record<string, unknown> | undefined;

    if (
      event.flowNodeType === 'business_rule_task' &&
      typeProperties?.mode === 'dmn'
    ) {
      collector.record(event);
    }
  });

  const reportIntervalMs = parseInt(process.env.REPORT_INTERVAL_MS ?? '60000', 10);

  setInterval(() => {
    const report = ReportFormatter.format(collector.getStats());
    console.log(JSON.stringify(report, null, 2));
  }, reportIntervalMs);
}

main().catch(console.error);
