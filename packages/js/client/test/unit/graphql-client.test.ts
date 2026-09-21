import { GraphqlDepthLimitError } from '@elraptorus/bfw_engine_sdk';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { GraphqlClient } from '../../src/graphql/graphql-client.js';
import { HttpTransport } from '../../src/http/transport.js';

function createMockTransport(responseData: unknown = {}): HttpTransport {
  return {
    post: vi.fn().mockResolvedValue(responseData),
  } as unknown as HttpTransport;
}

describe('GraphqlClient', () => {
  describe('queryProcessModels', () => {
    it('sends a GraphQL query with field selection using "processes" resource name', async () => {
      const transport = createMockTransport({
        data: {
          processes: {
            results: [{ id: 'uuid-1', name: 'Order', process_model_id: 'order-process' }],
            count: 1,
          },
        },
      });
      const client = new GraphqlClient(transport);

      const result = await client.queryProcessModels({
        fields: ['id', 'name', 'processModelId'],
      });

      expect(transport.post).toHaveBeenCalledWith(
        '/api/v1/graphql',
        expect.objectContaining({
          query: expect.stringContaining('processes'),
          variables: expect.any(Object),
        }),
      );
      expect(result.data).toHaveLength(1);
      expect(result.data[0]).toEqual({ id: 'uuid-1', name: 'Order', processModelId: 'order-process' });
    });

    it('camelizes snake_case keys in response data', async () => {
      const transport = createMockTransport({
        data: {
          processes: {
            results: [{ id: 'p1', process_model_id: 'order', created_at: '2026-01-01' }],
            count: 1,
          },
        },
      });
      const client = new GraphqlClient(transport);

      const result = await client.queryProcessModels({
        fields: ['id', 'processModelId', 'createdAt'],
      });

      expect(result.data[0]).toEqual({
        id: 'p1',
        processModelId: 'order',
        createdAt: '2026-01-01',
      });
    });

    it('sends limit and offset variables for offset pagination', async () => {
      const transport = createMockTransport({
        data: {
          processes: {
            results: [{ id: 'p1' }, { id: 'p2' }],
            count: 5,
            hasNextPage: true,
            hasPreviousPage: true,
            pageNumber: 2,
            lastPage: 3,
            limit: 2,
          },
        },
      });
      const client = new GraphqlClient(transport);

      const result = await client.queryProcessModels({
        fields: ['id'],
        pagination: { mode: 'offset', limit: 2, offset: 2 },
      });

      expect(transport.post).toHaveBeenCalledWith(
        '/api/v1/graphql',
        expect.objectContaining({
          variables: expect.objectContaining({ limit: 2, offset: 2 }),
        }),
      );
      expect(result.pageInfo).toEqual({
        type: 'offset',
        totalCount: 5,
        offset: 2,
        limit: 2,
        hasNextPage: true,
        hasPreviousPage: true,
        pageNumber: 2,
        lastPage: 3,
      });
    });

    it('returns empty data with cursor page info when no pagination specified', async () => {
      const transport = createMockTransport({ data: {} });
      const client = new GraphqlClient(transport);

      const result = await client.queryProcessModels({ fields: ['id'] });

      expect(result.data).toEqual([]);
      expect(result.pageInfo.type).toBe('cursor');
    });

    it('returns empty data with offset page info when offset pagination specified', async () => {
      const transport = createMockTransport({ data: {} });
      const client = new GraphqlClient(transport);

      const result = await client.queryProcessModels({
        fields: ['id'],
        pagination: { mode: 'offset', limit: 10, offset: 0 },
      });

      expect(result.data).toEqual([]);
      expect(result.pageInfo.type).toBe('offset');
      if (result.pageInfo.type === 'offset') {
        expect(result.pageInfo.totalCount).toBe(0);
        expect(result.pageInfo.pageNumber).toBe(1);
        expect(result.pageInfo.lastPage).toBe(1);
      }
    });
  });

  describe('getProcessModel', () => {
    it('uses a filtered list query with processModelId filter', async () => {
      const transport = createMockTransport({
        data: {
          processes: {
            results: [{ id: 'uuid-1', name: 'Order' }],
            count: 1,
          },
        },
      });
      const client = new GraphqlClient(transport);

      const result = await client.getProcessModel('order-process', {
        fields: ['id', 'name'],
      });

      expect(transport.post).toHaveBeenCalledWith(
        '/api/v1/graphql',
        expect.objectContaining({
          variables: expect.objectContaining({
            filter: { process_model_id: { eq: 'order-process' } },
            limit: 1,
          }),
        }),
      );
      expect(result).toEqual({ id: 'uuid-1', name: 'Order' });
    });
  });

  describe('queryProcessInstances', () => {
    it('sends a list query for process instances', async () => {
      const transport = createMockTransport({
        data: {
          processInstances: {
            results: [{ id: 'pi-1', state: 'running' }],
            count: 1,
          },
        },
      });
      const client = new GraphqlClient(transport);

      const result = await client.queryProcessInstances({
        fields: ['id', 'state'],
        filter: { state: { eq: 'running' } },
      });

      expect(result.data).toHaveLength(1);
      expect(result.data[0]).toEqual({ id: 'pi-1', state: 'running' });
    });

    it('maps count to totalCount and computes hasNextPage in cursor page info', async () => {
      const transport = createMockTransport({
        data: {
          processInstances: {
            results: [{ id: '1', state: 'running' }],
            count: 42,
            startKeyset: 'ks1',
            endKeyset: 'ks2',
          },
        },
      });
      const client = new GraphqlClient(transport);

      const result = await client.queryProcessInstances({
        fields: ['id', 'state'],
        pagination: { mode: 'cursor', first: 1 },
      });

      expect(result.pageInfo.type).toBe('cursor');
      if (result.pageInfo.type === 'cursor') {
        expect(result.pageInfo.totalCount).toBe(42);
        expect(result.pageInfo.startCursor).toBe('ks1');
        expect(result.pageInfo.endCursor).toBe('ks2');
        expect(result.pageInfo.hasNextPage).toBe(true);
      }
    });
  });

  describe('queryProcessVersions', () => {
    it('calls queryProcessVersions with correct resource name', async () => {
      const transport = createMockTransport({
        data: { processVersions: { results: [], count: 0 } },
      });
      const client = new GraphqlClient(transport);

      const result = await client.queryProcessVersions({
        fields: ['id', 'version', 'deployedAt'],
        pagination: { mode: 'cursor', first: 10 },
      });

      expect(transport.post).toHaveBeenCalledWith(
        '/api/v1/graphql',
        expect.objectContaining({
          query: expect.stringContaining('processVersions'),
        }),
      );
      expect(result.data).toEqual([]);
      expect(result.pageInfo.totalCount).toBe(0);
    });
  });

  describe('queryDecisionVersions', () => {
    it('calls queryDecisionVersions with correct resource name', async () => {
      const transport = createMockTransport({
        data: { decisionVersions: { results: [], count: 0 } },
      });
      const client = new GraphqlClient(transport);

      const result = await client.queryDecisionVersions({
        fields: ['id', 'version', 'deployedAt'],
        pagination: { mode: 'cursor', first: 10 },
      });

      expect(transport.post).toHaveBeenCalledWith(
        '/api/v1/graphql',
        expect.objectContaining({
          query: expect.stringContaining('decisionVersions'),
        }),
      );
      expect(result.data).toEqual([]);
      expect(result.pageInfo.totalCount).toBe(0);
    });
  });

  describe('queryDecisionDefinitions', () => {
    it('calls queryDecisionDefinitions with correct resource name', async () => {
      const transport = createMockTransport({
        data: { decisionDefinitions: { results: [], count: 0 } },
      });
      const client = new GraphqlClient(transport);

      const result = await client.queryDecisionDefinitions({
        fields: ['id', 'decisionDefinitionId', 'name'],
        pagination: { mode: 'cursor', first: 10 },
      });

      expect(transport.post).toHaveBeenCalledWith(
        '/api/v1/graphql',
        expect.objectContaining({
          query: expect.stringContaining('decisionDefinitions'),
        }),
      );
      expect(result.data).toEqual([]);
      expect(result.pageInfo.totalCount).toBe(0);
    });
  });

  describe('raw', () => {
    it('sends an arbitrary GraphQL query', async () => {
      const transport = createMockTransport({
        data: { customQuery: { result: 42 } },
      });
      const client = new GraphqlClient(transport);

      const result = await client.raw<{ customQuery: { result: number } }>('query { customQuery { result } }');

      expect(result).toEqual({ customQuery: { result: 42 } });
    });

    it('forwards custom headers to the transport', async () => {
      const transport = createMockTransport({
        data: { customQuery: { result: 1 } },
      });
      const client = new GraphqlClient(transport);

      await client.raw('query { customQuery { result } }', undefined, {
        headers: { 'X-Trace-Id': 'abc-123' },
      });

      expect(transport.post).toHaveBeenCalledWith('/api/v1/graphql', expect.any(Object), {
        headers: { 'X-Trace-Id': 'abc-123' },
      });
    });

    it('sends no request options when no headers are provided', async () => {
      const transport = createMockTransport({
        data: { customQuery: { result: 1 } },
      });
      const client = new GraphqlClient(transport);

      await client.raw('query { x }');

      expect(transport.post).toHaveBeenCalledWith('/api/v1/graphql', expect.any(Object), undefined);
    });
  });

  describe('JSON scalar parsing', () => {
    it('parses JSON object strings returned by AshGraphql :map attributes', async () => {
      const transport = createMockTransport({
        data: {
          processInstances: {
            results: [
              {
                id: 'pi-1',
                state: 'fatal',
                error_info: '{"reason":"process_fatal","message":"something broke"}',
              },
            ],
            count: 1,
          },
        },
      });
      const client = new GraphqlClient(transport);

      const result = await client.queryProcessInstances({
        fields: ['id', 'state', 'errorInfo'],
      });

      expect(typeof result.data[0]!.errorInfo).toBe('object');
      expect((result.data[0]!.errorInfo as Record<string, unknown>).reason).toBe('process_fatal');
    });

    it('parses JSON array strings', async () => {
      const transport = createMockTransport({
        data: {
          processInstances: {
            results: [
              {
                id: 'pi-1',
                state: 'running',
                started_by: '[{"id":"user-1"}]',
              },
            ],
            count: 1,
          },
        },
      });
      const client = new GraphqlClient(transport);

      const result = await client.queryProcessInstances({
        fields: ['id', 'state', 'startedBy'],
      });

      expect(Array.isArray(result.data[0]!.startedBy)).toBe(true);
    });

    it('leaves non-JSON strings unchanged', async () => {
      const transport = createMockTransport({
        data: {
          processInstances: {
            results: [
              {
                id: 'pi-1',
                state: 'running',
              },
            ],
            count: 1,
          },
        },
      });
      const client = new GraphqlClient(transport);

      const result = await client.queryProcessInstances({
        fields: ['id', 'state'],
      });

      expect(result.data[0]!.state).toBe('running');
    });

    it('leaves null errorInfo as null', async () => {
      const transport = createMockTransport({
        data: {
          getProcessInstance: {
            id: 'pi-1',
            state: 'finished',
            error_info: null,
          },
        },
      });
      const client = new GraphqlClient(transport);

      const result = await client.getProcessInstance('pi-1', {
        fields: ['id', 'state', 'errorInfo'],
      });

      expect(result.errorInfo).toBeNull();
    });
  });

  describe('getProcessInstanceWithModel', () => {
    it('selects processVersion.processModel and flowNodeInstances.flowNode', async () => {
      const transport = createMockTransport({
        data: {
          getProcessInstance: {
            id: 'pi-1',
            process_version: { id: 'pv-1', process_model: { id: 'order-process' } },
            flow_node_instances: [{ id: 'fni-1', flow_node: { id: 'Start_1', type: 'START_EVENT' } }],
          },
        },
      });
      const client = new GraphqlClient(transport);

      const result = await client.getProcessInstanceWithModel('pi-1', {
        fields: ['id'],
        flowNodeDepth: 0,
      });

      expect(transport.post).toHaveBeenCalledWith(
        '/api/v1/graphql',
        expect.objectContaining({
          query: expect.stringMatching(
            /process_version[\s\S]*process_model[\s\S]*flow_node_instances\s*\{[\s\S]*flow_node/,
          ),
        }),
      );
      const [, body] = vi.mocked(transport.post).mock.calls[0] as [string, { query: string }];
      expect(body.query).not.toMatch(/flow_node_instances\s*\{\s*results/);
      expect(body.query).toMatch(/SendTaskNode/);
      expect(body.query).toMatch(/out_mappings/);
      expect(body.query).not.toMatch(/\.\.\. on \w+ \{\s*\}/);
      expect(body.query).not.toContain('... on TaskNode');
      expect(body.query).not.toContain('... on ParallelGatewayNode');
      expect(body.query).not.toContain('... on EventBasedGatewayNode');
      expect(result).not.toBeNull();
      expect(result?.id).toBe('pi-1');
    });
  });

  describe('error handling', () => {
    it('throws a typed error when GraphQL response contains errors with a code', async () => {
      const transport = createMockTransport({
        errors: [
          {
            message: 'Query too deep',
            extensions: { code: 'graphql_depth_limit' },
          },
        ],
      });
      const client = new GraphqlClient(transport);

      await expect(client.queryProcessModels({ fields: ['id'] })).rejects.toThrow(GraphqlDepthLimitError);
    });

    it('throws a generic Error when GraphQL error has no code', async () => {
      const transport = createMockTransport({
        errors: [{ message: 'Something went wrong' }],
      });
      const client = new GraphqlClient(transport);

      await expect(client.queryProcessModels({ fields: ['id'] })).rejects.toThrow(
        'GraphQL error: Something went wrong',
      );
    });
  });
});
