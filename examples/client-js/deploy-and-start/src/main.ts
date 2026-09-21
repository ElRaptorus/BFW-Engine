import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { BfwEngineClient } from '@elraptorus/bfw_engine_client';

const __dirname = dirname(fileURLToPath(import.meta.url));

export async function main(): Promise<void> {
  const engineUrl = process.env['ENGINE_URL'] ?? 'http://localhost:4000';
  const token = process.env['ENGINE_TOKEN'] ?? 'dev-token';
  const client = new BfwEngineClient(engineUrl, token);

  const bpmnPath = resolve(__dirname, '../bpmn/hello.bpmn');
  const bpmnXml = readFileSync(bpmnPath, 'utf8');

  const deployResponse = await client.processes.deploy(bpmnXml);
  console.log('Deployed:', deployResponse);

  const startResult = await client.processes.start('hello-process');
  console.log('Started process instance:', startResult.processInstanceId, 'state:', startResult.state);

  client.dispose();
}

main().catch(console.error);
