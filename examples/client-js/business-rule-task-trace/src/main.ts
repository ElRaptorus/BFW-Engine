import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { DaemonEngineClient } from '@elraptorus/daemonengine_client';

const sourceDirectoryPath = dirname(fileURLToPath(import.meta.url));

export async function main(): Promise<void> {
  const engineUrl = process.env['ENGINE_URL'] ?? 'http://localhost:4000';
  const token = process.env['ENGINE_TOKEN'] ?? 'dev-token';
  const client = new DaemonEngineClient(engineUrl, token);

  try {
    const decisionModelFilePath = join(sourceDirectoryPath, '..', 'dmn', 'discount_rules.dmn');
    const dmnXml = readFileSync(decisionModelFilePath, 'utf8');

    const processModelFilePath = join(sourceDirectoryPath, '..', 'bpmn', 'business_rule_task_dmn.bpmn');
    const bpmnXml = readFileSync(processModelFilePath, 'utf8');

    console.log('Deploying DMN decision table...');
    await client.decisions.deploy(dmnXml);

    console.log('Deploying BPMN process with Business Rule Task...');
    await client.processes.deploy(bpmnXml);

    console.log('Starting process instance...');
    const startResult = await client.processes.start('brt-dmn-process', {
      payload: { customerType: 'gold', orderTotal: 200 },
    });
    console.log('Process instance:', startResult.processInstanceId);

    console.log('\nQuerying BRT flow node instances via GraphQL...');
    const flowNodeInstances = await client.graphql.queryFlowNodeInstances({
      fields: ['id', 'flowNodeId', 'flowNodeType', 'state', 'typeProperties'],
      filter: {
        processInstanceId: { eq: startResult.processInstanceId },
        flowNodeType: { eq: 'business_rule_task' },
      },
    });

    for (const flowNodeInstance of flowNodeInstances.data) {
      console.log(`\nFlow node instance ${flowNodeInstance.id} (${flowNodeInstance.flowNodeId}):`);
      console.log('  State:', flowNodeInstance.state);
      console.log('  Type Properties:', JSON.stringify(flowNodeInstance.typeProperties, null, 2));
    }
  } finally {
    client.dispose();
  }
}

main().catch(console.error);
