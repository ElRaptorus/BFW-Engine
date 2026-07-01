import { DaemonEngineClient } from '@elraptorus/daemonengine_client';

function formatRecord(label: string, value: unknown): void {
  console.log(label, JSON.stringify(value, null, 2));
}

export async function main(): Promise<void> {
  const engineUrl = process.env['ENGINE_URL'] ?? 'http://localhost:4000';
  const token = process.env['ENGINE_TOKEN'] ?? 'dev-token';
  const client = new DaemonEngineClient(engineUrl, token);

  const processModelsPage = await client.graphql.queryProcessModels({
    fields: ['id', 'processModelId', 'name', 'enabled'],
    sort: [{ field: 'name', direction: 'asc' }],
    pagination: { mode: 'offset', limit: 5, offset: 0 },
  });
  formatRecord('Process models (first page, selected fields, sorted by name):', {
    data: processModelsPage.data,
    pageInfo: processModelsPage.pageInfo,
  });

  if (processModelsPage.data.length > 0) {
    const firstRow = processModelsPage.data[0]!;
    const firstModelId = firstRow.processModelId ?? firstRow.id;
    const singleModel = await client.graphql.getProcessModel(firstModelId, {
      fields: ['id', 'processModelId', 'name', 'enabled'],
    });
    formatRecord(`Single process model get (${firstModelId}):`, singleModel);
  }

  const runningInstances = await client.graphql.queryProcessInstances({
    fields: ['id', 'state', 'startedAt', 'businessKey'],
    filter: { state: { eq: 'running' } },
    sort: [{ field: 'startedAt', direction: 'desc' }],
    pagination: { mode: 'offset', limit: 5, offset: 0 },
  });
  formatRecord('Process instances filtered to running state:', {
    data: runningInstances.data,
    pageInfo: runningInstances.pageInfo,
  });

  const cursorPage = await client.graphql.queryProcessInstances({
    fields: ['id', 'state'],
    pagination: { mode: 'cursor', first: 3 },
  });
  formatRecord('Process instances (cursor pagination, first: 3):', {
    data: cursorPage.data,
    pageInfo: cursorPage.pageInfo,
  });

  console.log('\n--- 5. Includes (nested flow node instances) ---');
  const withIncludes = await client.graphql.queryProcessInstances({
    fields: ['id', 'state', 'businessKey'],
    include: {
      flowNodeInstances: {
        fields: ['id', 'flowNodeId', 'state', 'flowNodeType'],
      },
    },
    pagination: { mode: 'offset', limit: 2, offset: 0 },
  });
  formatRecord('Process instances with nested flowNodeInstances:', {
    data: withIncludes.data,
    pageInfo: withIncludes.pageInfo,
  });

  const finishedFlowNodes = await client.graphql.queryFlowNodeInstances({
    fields: ['id', 'flowNodeId', 'state', 'flowNodeType'],
    filter: { state: { eq: 'finished' } },
    pagination: { mode: 'offset', limit: 5, offset: 0 },
  });
  formatRecord('Flow node instances filtered to finished:', {
    data: finishedFlowNodes.data,
    pageInfo: finishedFlowNodes.pageInfo,
  });

  let offset = 0;
  const pageLimit = 2;
  let totalPages = 0;
  while (totalPages < 3) {
    const page = await client.graphql.queryProcessModels({
      fields: ['id', 'name'],
      pagination: { mode: 'offset', limit: pageLimit, offset },
    });
    console.log(`Process models offset page ${totalPages + 1}:`, page.data.length, 'rows');
    if (page.pageInfo.type !== 'offset' || !page.pageInfo.hasNextPage) {
      break;
    }
    offset += pageLimit;
    totalPages += 1;
  }

  client.dispose();
}

main().catch(console.error);
