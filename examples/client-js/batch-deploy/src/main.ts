import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { BfwEngineClient } from '@elraptorus/bfw_engine_client';
import type { ProcessModel } from '@elraptorus/bfw_engine_sdk';

const __dirname = dirname(fileURLToPath(import.meta.url));

export async function main(): Promise<void> {
  const engineUrl = process.env['ENGINE_URL'] ?? 'http://localhost:4000';
  const token = process.env['ENGINE_TOKEN'] ?? 'dev-token';
  const client = new BfwEngineClient(engineUrl, token);

  const xmlProcessA = readFileSync(resolve(__dirname, '../bpmn/process_a.bpmn'), 'utf8');
  const xmlProcessB = readFileSync(resolve(__dirname, '../bpmn/process_b.bpmn'), 'utf8');
  const xmlProcessC = readFileSync(resolve(__dirname, '../bpmn/process_c.bpmn'), 'utf8');

  await client.processes.deploy([xmlProcessA, xmlProcessB, xmlProcessC]);
  console.log('Deployed three processes in one batch.');

  const allModels = await client.processes.getAll();
  console.log(
    'Deployed models (ids):',
    allModels.map((model: ProcessModel) => model.id),
  );

  const versionsBefore = await client.processes.getVersions('example-batch-process-a');
  console.log(
    'Versions for example-batch-process-a before v2:',
    versionsBefore.map((model: ProcessModel) => model.version),
  );

  const xmlProcessAV2 = readFileSync(resolve(__dirname, '../bpmn/process_a_v2.bpmn'), 'utf8');
  await client.processes.deploy(xmlProcessAV2);
  console.log('Deployed process_a at version 2.0.0.');

  const versionsAfter = await client.processes.getVersions('example-batch-process-a');
  console.log(
    'Versions for example-batch-process-a after v2:',
    versionsAfter.map((model: ProcessModel) => model.version),
  );

  await client.processes.disable('example-batch-process-a');
  console.log('Disabled process example-batch-process-a (no new instances).');
  await client.processes.enable('example-batch-process-a');
  console.log('Re-enabled process example-batch-process-a.');

  await client.processes.deleteVersion('example-batch-process-a', '1.0.0');
  console.log('Deleted historical version 1.0.0 for example-batch-process-a.');

  const versionsFinal = await client.processes.getVersions('example-batch-process-a');
  console.log(
    'Remaining versions for example-batch-process-a:',
    versionsFinal.map((model: ProcessModel) => model.version),
  );

  await client.processes.undeploy('example-batch-process-a');
  await client.processes.undeploy('example-batch-process-b');
  await client.processes.undeploy('example-batch-process-c');
  console.log('Undeployed all batch processes.');

  client.dispose();
}

main().catch(console.error);
