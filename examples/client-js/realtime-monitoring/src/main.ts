import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { DaemonEngineClient } from '@elraptorus/daemonengine_client';
import type { EngineEventEnvelope } from '@elraptorus/daemonengine_sdk';

const __dirname = dirname(fileURLToPath(import.meta.url));

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, milliseconds));
}

export async function main(): Promise<void> {
  const engineUrl = process.env['ENGINE_URL'] ?? 'http://localhost:4000';
  const token = process.env['ENGINE_TOKEN'] ?? 'dev-token';
  const client = new DaemonEngineClient(engineUrl, token);

  const bpmnPath = resolve(__dirname, '../bpmn/rt-demo.bpmn');
  const bpmnXml = readFileSync(bpmnPath, 'utf8');
  await client.processes.deploy(bpmnXml);

  await client.notifications.connect();
  const subscription = await client.notifications.onEngineEvent((event: EngineEventEnvelope) => {
    console.log('Engine event:', event.type, summarizeEventData(event));
  });

  const startResult = await client.processes.start('example-realtime-process');
  console.log('Started instance to generate events:', startResult.processInstanceId);

  await sleep(3_000);

  subscription.dispose();
  await client.processInstances.delete(startResult.processInstanceId).catch(() => undefined);
  await client.processes.undeploy('example-realtime-process');
  client.dispose();
}

function summarizeEventData(envelope: EngineEventEnvelope): Record<string, unknown> {
  const data = envelope.data as unknown as Record<string, unknown>;
  const summary: Record<string, unknown> = {};
  const keys = ['processInstanceId', 'flowNodeInstanceId', 'processModelId', 'oldState', 'newState', 'flowNodeId'];
  for (const key of keys) {
    if (key in data) {
      summary[key] = data[key]!;
    }
  }
  return summary;
}

main().catch(console.error);
