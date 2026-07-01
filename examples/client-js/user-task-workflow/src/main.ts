import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { DaemonEngineClient } from '@elraptorus/daemonengine_client';

const __dirname = dirname(fileURLToPath(import.meta.url));

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, milliseconds));
}

export async function main(): Promise<void> {
  const engineUrl = process.env['ENGINE_URL'] ?? 'http://localhost:4000';
  const token = process.env['ENGINE_TOKEN'] ?? 'dev-token';
  const client = new DaemonEngineClient(engineUrl, token);

  const bpmnPath = resolve(__dirname, '../bpmn/approval.bpmn');
  const bpmnXml = readFileSync(bpmnPath, 'utf8');
  await client.processes.deploy(bpmnXml);

  const startResult = await client.processes.start('example-approval-process', {
    payload: { orderId: 42 },
  });
  console.log('Started:', startResult.processInstanceId);

  let userTaskFlowNodeInstanceId: string | undefined;
  while (userTaskFlowNodeInstanceId === undefined) {
    const waitingTasks = await client.graphql.queryFlowNodeInstances({
      fields: ['id', 'state', 'flowNodeId', 'flowNodeType', 'processInstanceId'],
      filter: {
        processInstanceId: { eq: startResult.processInstanceId },
        flowNodeType: { eq: 'user_task' },
        state: { eq: 'waiting' },
      },
      pagination: { mode: 'offset', limit: 10, offset: 0 },
    });
    console.log('Waiting user-task FNIs:', waitingTasks.data.length);
    if (waitingTasks.data.length > 0) {
      userTaskFlowNodeInstanceId = waitingTasks.data[0]!.id;
    } else {
      await sleep(200);
    }
  }

  console.log('Finishing user task FNI:', userTaskFlowNodeInstanceId);
  await client.userTasks.finish(userTaskFlowNodeInstanceId, {
    result: { approved: true },
  });

  while (true) {
    const instance = await client.graphql.getProcessInstance(startResult.processInstanceId, {
      fields: ['id', 'state'],
    });
    console.log('Process instance state:', instance?.state);
    if (instance?.state === 'finished') {
      console.log('Process completed after user task.');
      break;
    }
    await sleep(200);
  }

  await client.processInstances.delete(startResult.processInstanceId);
  await client.processes.undeploy('example-approval-process');
  client.dispose();
}

main().catch(console.error);
