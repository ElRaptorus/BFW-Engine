import { describe, it, expect } from 'vitest';
import { buildListQuery, buildGetQuery } from '../../src/graphql/query-builder.js';

describe('buildListQuery', () => {
  it('builds a basic list query with field selection', () => {
    const { query, variables } = buildListQuery({
      resourceName: 'processModels',
      ashTypeName: 'Process',
      fields: ['id', 'name', 'version'],
    });

    expect(query).toContain('processModels');
    expect(query).toContain('results');
    expect(query).toContain('id');
    expect(query).toContain('name');
    expect(query).toContain('version');
    expect(query).toContain('count');
    expect(variables).toEqual({});
  });

  it('converts camelCase fields to snake_case in the query', () => {
    const { query } = buildListQuery({
      resourceName: 'processInstances',
      ashTypeName: 'ProcessInstance',
      fields: ['id', 'processModelId', 'startedAt'],
    });

    expect(query).toContain('process_model_id');
    expect(query).toContain('started_at');
  });

  it('includes filter variables when provided', () => {
    const { query, variables } = buildListQuery({
      resourceName: 'processInstances',
      ashTypeName: 'ProcessInstance',
      fields: ['id'],
      filter: { state: { eq: 'running' } },
    });

    expect(query).toContain('$filter');
    expect(query).toContain('filter: $filter');
    expect(variables).toHaveProperty('filter');
  });

  it('converts filter field and operator names to snake_case', () => {
    const { variables } = buildListQuery({
      resourceName: 'processInstances',
      ashTypeName: 'ProcessInstance',
      fields: ['id'],
      filter: { processModelId: { eq: 'order' }, startedAt: { greaterThan: '2026-01-01' } },
    });

    const filter = variables['filter'] as Record<string, unknown>;
    expect(filter).toHaveProperty('process_model_id');
    expect(filter).toHaveProperty('started_at');

    const startedAt = filter['started_at'] as Record<string, unknown>;
    expect(startedAt).toHaveProperty('greater_than', '2026-01-01');
  });

  it('includes sort variables with SCREAMING_SNAKE_CASE field and order key', () => {
    const { query, variables } = buildListQuery({
      resourceName: 'processModels',
      ashTypeName: 'Process',
      fields: ['id'],
      sort: [{ field: 'createdAt', direction: 'desc' }],
    });

    expect(query).toContain('$sort');
    expect(variables['sort']).toEqual([{ field: 'CREATED_AT', order: 'DESC' }]);
  });

  it('includes cursor pagination variables', () => {
    const { query, variables } = buildListQuery({
      resourceName: 'processModels',
      ashTypeName: 'Process',
      fields: ['id'],
      pagination: { mode: 'cursor', first: 10, after: 'cursor-abc' },
    });

    expect(query).toContain('$first');
    expect(query).toContain('$after');
    expect(variables['first']).toBe(10);
    expect(variables['after']).toBe('cursor-abc');
  });

  it('includes limit and offset variables for offset pagination', () => {
    const { query, variables } = buildListQuery({
      resourceName: 'processModels',
      ashTypeName: 'Process',
      fields: ['id'],
      pagination: { mode: 'offset', limit: 25, offset: 50 },
    });

    expect(query).toContain('$limit');
    expect(query).toContain('$offset');
    expect(variables['limit']).toBe(25);
    expect(variables['offset']).toBe(50);
  });

  it('omits offset variable when offset is 0', () => {
    const { query, variables } = buildListQuery({
      resourceName: 'processModels',
      ashTypeName: 'Process',
      fields: ['id'],
      pagination: { mode: 'offset', limit: 25, offset: 0 },
    });

    expect(query).toContain('$limit');
    expect(query).not.toContain('$offset');
    expect(variables['limit']).toBe(25);
    expect(variables['offset']).toBeUndefined();
  });

  it('includes offset page metadata fields for offset pagination', () => {
    const { query } = buildListQuery({
      resourceName: 'processModels',
      ashTypeName: 'Process',
      fields: ['id'],
      pagination: { mode: 'offset', limit: 10, offset: 0 },
    });

    expect(query).toContain('count');
    expect(query).toContain('hasNextPage');
    expect(query).toContain('hasPreviousPage');
    expect(query).toContain('pageNumber');
    expect(query).toContain('lastPage');
  });

  it('includes nested relationship fields', () => {
    const { query } = buildListQuery({
      resourceName: 'processInstances',
      ashTypeName: 'ProcessInstance',
      fields: ['id', 'state'],
      include: {
        flowNodeInstances: { fields: ['id', 'flowNodeId', 'state'] },
      },
    });

    expect(query).toContain('flow_node_instances');
    expect(query).toContain('flow_node_id');
  });

  it('passes ilike filter through to snake_case filter input', () => {
    const { variables } = buildListQuery({
      resourceName: 'processes',
      ashTypeName: 'Process',
      fields: ['id', 'name'],
      filter: { name: { ilike: '%order%' } },
    });
    const filter = variables['filter'] as Record<string, unknown>;
    expect(filter).toHaveProperty('name');
    const nameFilter = filter['name'] as Record<string, unknown>;
    expect(nameFilter).toHaveProperty('ilike', '%order%');
  });

  it('passes like filter through to filter input', () => {
    const { variables } = buildListQuery({
      resourceName: 'processes',
      ashTypeName: 'Process',
      fields: ['id'],
      filter: { processModelId: { like: 'order-%' } },
    });
    const filter = variables['filter'] as Record<string, unknown>;
    const processModelId = filter['process_model_id'] as Record<string, unknown>;
    expect(processModelId).toHaveProperty('like', 'order-%');
  });

  it('includes keyset fields in query for cursor pagination', () => {
    const { query } = buildListQuery({
      resourceName: 'processInstances',
      ashTypeName: 'ProcessInstance',
      fields: ['id'],
      pagination: { mode: 'cursor', first: 10 },
    });
    expect(query).toContain('startKeyset');
    expect(query).toContain('endKeyset');
    expect(query).toContain('count');
  });

  it('does not include keyset fields for offset pagination', () => {
    const { query } = buildListQuery({
      resourceName: 'processInstances',
      ashTypeName: 'ProcessInstance',
      fields: ['id'],
      pagination: { mode: 'offset', limit: 10, offset: 0 },
    });
    expect(query).not.toContain('startKeyset');
    expect(query).not.toContain('endKeyset');
    expect(query).toContain('count');
  });

  it('passes after cursor as variable for cursor pagination', () => {
    const { variables } = buildListQuery({
      resourceName: 'processInstances',
      ashTypeName: 'ProcessInstance',
      fields: ['id'],
      pagination: { mode: 'cursor', first: 10, after: 'cursor123' },
    });
    expect(variables).toHaveProperty('after', 'cursor123');
  });

  it('renders nested include arguments with filter and sort', () => {
    const { query } = buildListQuery({
      resourceName: 'processes',
      ashTypeName: 'Process',
      fields: ['id', 'name'],
      include: {
        versions: {
          fields: ['id', 'version', 'deployedAt'],
          filter: { version: { ilike: '%1.0%' } },
          sort: [{ field: 'deployedAt', direction: 'desc' }],
        },
      },
    });
    expect(query).toContain('versions');
    expect(query).toContain('filter:');
    expect(query).toContain('ilike');
    expect(query).toContain('DEPLOYED_AT');
    expect(query).toContain('DESC');
  });

  it('converts sort field to SCREAMING_SNAKE_CASE in variables', () => {
    const { variables } = buildListQuery({
      resourceName: 'processInstances',
      ashTypeName: 'ProcessInstance',
      fields: ['id'],
      sort: [{ field: 'startedAt', direction: 'desc' }],
    });
    const sort = variables['sort'] as Array<{ field: string; order: string }>;
    expect(sort[0]!.field).toBe('STARTED_AT');
    expect(sort[0]!.order).toBe('DESC');
  });
});

describe('buildGetQuery', () => {
  it('builds a get query with getResourceName format', () => {
    const { query, variables, getFieldName } = buildGetQuery('order-process', {
      resourceName: 'processModel',
      fields: ['id', 'name', 'version'],
    });

    expect(query).toContain('$id: ID!');
    expect(query).toContain('getProcessModel(id: $id)');
    expect(getFieldName).toBe('getProcessModel');
    expect(variables).toEqual({ id: 'order-process' });
  });

  it('includes nested include fields', () => {
    const { query } = buildGetQuery('pi-1', {
      resourceName: 'processInstance',
      fields: ['id'],
      include: {
        flowNodeInstances: { fields: ['id', 'state'] },
      },
    });

    expect(query).toContain('flow_node_instances');
  });
});

describe('SelectionField support (Phase 6.1, WP-6 — polymorphic Model graph)', () => {
  it('renders a plain nested object field with a sub-selection', () => {
    const { query } = buildGetQuery('pv-1', {
      resourceName: 'processVersion',
      fields: ['id', { name: 'processModel', fields: ['id', 'name'] }],
    });

    expect(query).toContain('process_model {');
    expect(query).toContain('id');
    expect(query).toContain('name');
  });

  it('renders inline fragments for interface/union fields via `on`', () => {
    const { query } = buildGetQuery('fni-1', {
      resourceName: 'flowNodeInstance',
      fields: [
        'id',
        {
          name: 'flowNode',
          fields: ['id', 'type'],
          on: {
            ServiceTaskNode: ['implementation', 'httpUrl'],
            UserTaskNode: ['assigneesExpression'],
          },
        },
      ],
    });

    expect(query).toContain('flow_node {');
    expect(query).toContain('... on ServiceTaskNode {');
    expect(query).toContain('implementation');
    expect(query).toContain('http_url');
    expect(query).toContain('... on UserTaskNode {');
    expect(query).toContain('assignees_expression');
  });

  it('renders recursively nested selections (nested object inside a fragment)', () => {
    const { query } = buildGetQuery('fni-1', {
      resourceName: 'flowNodeInstance',
      fields: [
        {
          name: 'flowNode',
          fields: ['id'],
          on: {
            StartEventNode: [{ name: 'eventDefinition', on: { MessageEventDefinition: ['messageRef'] } }],
          },
        },
      ],
    });

    expect(query).toContain('... on StartEventNode {');
    expect(query).toContain('event_definition {');
    expect(query).toContain('... on MessageEventDefinition {');
    expect(query).toContain('message_ref');
  });

  it('falls back to __typename for a nested field with no sub-selection', () => {
    const { query } = buildGetQuery('pv-1', {
      resourceName: 'processVersion',
      fields: [{ name: 'processModel' }],
    });

    expect(query).toContain('process_model {');
    expect(query).toContain('__typename');
  });

  it('still accepts a flat string[] fields array (backward compatible)', () => {
    const { query } = buildListQuery({
      resourceName: 'processModels',
      ashTypeName: 'Process',
      fields: ['id', 'name'],
    });

    expect(query).toContain('id');
    expect(query).toContain('name');
    expect(query).not.toContain('__typename');
  });
});
