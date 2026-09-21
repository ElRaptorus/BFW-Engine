import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { BfwEngineClient } from '@elraptorus/bfw_engine_client';

const __dirname = dirname(fileURLToPath(import.meta.url));

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, milliseconds));
}

function isTerminalProcessState(state: string): boolean {
  return ['finished', 'aborted', 'fatal', 'error', 'escalated', 'compensated'].includes(state);
}

export async function main(): Promise<void> {
  const engineUrl = process.env['ENGINE_URL'] ?? 'http://localhost:4000';
  const token = process.env['ENGINE_TOKEN'] ?? 'dev-token';
  const client = new BfwEngineClient(engineUrl, token);

  const bpmnPath = resolve(__dirname, '../bpmn/lifecycle.bpmn');
  const bpmnXml = readFileSync(bpmnPath, 'utf8');
  await client.processes.deploy(bpmnXml);

  const firstStart = await client.processes.start('example-lifecycle-process');
  let previousState = '';
  console.log('Polling first instance:', firstStart.processInstanceId);

  while (true) {
    const instance = await client.graphql.getProcessInstance(firstStart.processInstanceId, {
      fields: ['id', 'state'],
    });
    if (instance && instance.state !== previousState) {
      console.log('Process instance state:', instance.state);
      previousState = instance.state;
    }
    if (instance && isTerminalProcessState(instance.state)) {
      console.log('First instance finished with terminal state:', instance.state);
      break;
    }
    await sleep(200);
  }

  await client.processInstances.delete(firstStart.processInstanceId);

  const secondStart = await client.processes.start('example-lifecycle-process');
  console.log('Started second instance for abort:', secondStart.processInstanceId);

  let runningSeen = false;
  while (!runningSeen) {
    const instance = await client.graphql.getProcessInstance(secondStart.processInstanceId, {
      fields: ['id', 'state'],
    });
    if (instance?.state === 'running') {
      runningSeen = true;
      console.log('Second instance is running before abort.');
    } else {
      await sleep(100);
    }
  }

  await client.processInstances.abort(secondStart.processInstanceId);

  while (true) {
    const instance = await client.graphql.getProcessInstance(secondStart.processInstanceId, {
      fields: ['id', 'state'],
    });
    if (instance?.state === 'aborted') {
      console.log('Verified aborted state for second instance.');
      break;
    }
    await sleep(200);
  }

  await client.processInstances.delete(secondStart.processInstanceId);
  console.log('Deleted aborted instance.');

  await client.processes.undeploy('example-lifecycle-process');

  client.dispose();
}

main().catch(console.error);
