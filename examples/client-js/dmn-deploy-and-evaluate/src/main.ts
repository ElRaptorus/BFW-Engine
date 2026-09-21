import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { BfwEngineClient } from '@elraptorus/bfw_engine_client';

const sourceDirectoryPath = dirname(fileURLToPath(import.meta.url));

export async function main(): Promise<void> {
  const engineUrl = process.env['ENGINE_URL'] ?? 'http://localhost:4000';
  const token = process.env['ENGINE_TOKEN'] ?? 'dev-token';
  const client = new BfwEngineClient(engineUrl, token);

  try {
    const decisionModelFilePath = join(sourceDirectoryPath, '..', 'dmn', 'discount_rules.dmn');
    const dmnXml = readFileSync(decisionModelFilePath, 'utf8');

    console.log('Deploying DMN decision table...');
    const deployResult = await client.decisions.deploy(dmnXml);
    console.log('Deployed:', deployResult.deployed);

    const definitionId = deployResult.deployed[0]!.decisionDefinitionId;

    console.log('\nEvaluating with gold customer, high order...');
    const goldResult = await client.decisions.evaluate(definitionId, {
      customerType: 'gold',
      orderTotal: 150,
    });
    console.log('Result:', goldResult.result);
    console.log('Hit policy:', goldResult.hitPolicy);
    console.log('Matched rules:', goldResult.matchedRules);

    console.log('\nEvaluating with silver customer...');
    const silverResult = await client.decisions.evaluate(
      definitionId,
      { customerType: 'silver', orderTotal: 50 },
      { includeUnmatchedDetails: true },
    );
    console.log('Result:', silverResult.result);
    console.log('Trace decisions:', silverResult.trace.decisions.length);

    console.log('\nCleaning up...');
    await client.decisions.undeploy(definitionId);
    console.log('Done!');
  } finally {
    client.dispose();
  }
}

main().catch(console.error);
