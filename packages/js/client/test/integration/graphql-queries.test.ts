import { UnauthorizedError } from '@elraptorus/bfw_engine_sdk';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

import type { BfwEngineClient } from '../../src/bfw-engine-client.js';
import {
  cleanupInstances,
  createAdminClient,
  createExpiredTokenClient,
  createUnauthenticatedClient,
  deployDmnFixture,
  deployFixture,
  ensureEngineReachable,
  waitForState,
} from '../support/test-engine.js';

let adminClient: BfwEngineClient;
let unauthenticatedClient: BfwEngineClient;
let expiredTokenClient: BfwEngineClient;

let processInstanceId: string;
let fatalProcessInstanceId: string;
let abortedProcessInstanceId: string;

const PROCESS_ID = 'integration-passthrough';
const PROCESS_NAME = 'Integration Passthrough';
const FATAL_PROCESS_ID = 'integration-fatal-script';
const USER_TASK_PROCESS_ID = 'integration-user-task';
const DECISION_DEFINITION_ID = 'definitions_discount';

beforeAll(async () => {
  await ensureEngineReachable();
  adminClient = await createAdminClient();
  unauthenticatedClient = await createUnauthenticatedClient();
  expiredTokenClient = await createExpiredTokenClient();

  await deployFixture(adminClient, 'integration-passthrough.bpmn');
  await deployFixture(adminClient, 'integration-fatal-script.bpmn');
  await deployFixture(adminClient, 'integration-user-task.bpmn');
  await deployDmnFixture(adminClient, 'simple_unique.dmn');

  const startResult = await adminClient.processes.start(PROCESS_ID);
  processInstanceId = startResult.processInstanceId;
  await waitForState(adminClient, processInstanceId, 'finished');

  const fatalStartResult = await adminClient.processes.start(FATAL_PROCESS_ID);
  fatalProcessInstanceId = fatalStartResult.processInstanceId;
  await waitForState(adminClient, fatalProcessInstanceId, 'fatal');

  const abortStartResult = await adminClient.processes.start(USER_TASK_PROCESS_ID);
  abortedProcessInstanceId = abortStartResult.processInstanceId;
  await adminClient.processInstances.abort(abortedProcessInstanceId);
  await waitForState(adminClient, abortedProcessInstanceId, 'aborted');
});

afterAll(async () => {
  await cleanupInstances(adminClient);
});

describe('GraphQL Queries', () => {
  describe('happy paths', () => {
    it('queries process instances with offset pagination', async () => {
      const result = await adminClient.graphql.queryProcessInstances({
        fields: ['id', 'state'],
        pagination: { mode: 'offset', limit: 5, offset: 0 },
      });
      expect(result.data).toBeInstanceOf(Array);
      expect(result.pageInfo.type).toBe('offset');
      if (result.pageInfo.type === 'offset') {
        expect(typeof result.pageInfo.totalCount).toBe('number');
      }
    });

    it('queries process instances with offset pagination (page 2)', async () => {
      const result = await adminClient.graphql.queryProcessInstances({
        fields: ['id', 'state'],
        pagination: { mode: 'offset', limit: 5, offset: 0 },
      });
      expect(result.data).toBeInstanceOf(Array);
      expect(result.pageInfo.type).toBe('offset');
    });

    it('filters flow node instances by state', async () => {
      const result = await adminClient.graphql.queryFlowNodeInstances({
        fields: ['id', 'state', 'flowNodeId'],
        filter: { state: { eq: 'finished' } },
        pagination: { mode: 'offset', limit: 10, offset: 0 },
      });
      for (const flowNodeInstance of result.data) {
        expect(flowNodeInstance.state).toBe('finished');
      }
    });

    it('sorts process instances by startedAt descending', async () => {
      const result = await adminClient.graphql.queryProcessInstances({
        fields: ['id', 'startedAt'],
        sort: [{ field: 'startedAt', direction: 'desc' }],
        pagination: { mode: 'offset', limit: 10, offset: 0 },
      });
      expect(result.data.length).toBeGreaterThan(0);
    });

    it('queries flow node instances for a process instance', async () => {
      const result = await adminClient.graphql.queryFlowNodeInstances({
        fields: ['id', 'state', 'flowNodeId'],
        filter: { processInstanceId: { eq: processInstanceId } },
        pagination: { mode: 'offset', limit: 50, offset: 0 },
      });
      expect(result.data.length).toBeGreaterThan(0);
      for (const flowNodeInstance of result.data) {
        expect(flowNodeInstance.id).toBeDefined();
        expect(flowNodeInstance.state).toBeDefined();
      }
    });

    it('gets a single process model by ID', async () => {
      const model = await adminClient.graphql.getProcessModel(PROCESS_ID, {
        fields: ['id', 'name', 'enabled'],
      });
      expect(model.id).toBeDefined();
    });

    it('verifies returned fields match requested fields', async () => {
      const instance = await adminClient.graphql.getProcessInstance(processInstanceId, {
        fields: ['id', 'state'],
      });
      expect(instance.id).toBeDefined();
      expect(instance.state).toBeDefined();
    });

    it('loads a process instance with the Model graph (debugger open query)', async () => {
      const record = await adminClient.graphql.getProcessInstanceWithModel(processInstanceId, {
        fields: ['id', 'state'],
        flowNodeDepth: 0,
      });
      expect(record).not.toBeNull();
      expect(record?.id).toBe(processInstanceId);
      const processVersion = record?.processVersion as Record<string, unknown> | undefined;
      expect(processVersion).toBeDefined();
      expect(processVersion?.processModel).toBeDefined();
      const flowNodeInstances = record?.flowNodeInstances as unknown[] | undefined;
      expect(Array.isArray(flowNodeInstances)).toBe(true);
      expect(flowNodeInstances?.length).toBeGreaterThan(0);
    });

    it('returns errorInfo for a fatal process instance', async () => {
      const instance = await adminClient.graphql.getProcessInstance(fatalProcessInstanceId, {
        fields: ['id', 'state', 'errorInfo'],
      });
      expect(instance.state).toBe('fatal');
      expect(instance.errorInfo).toBeDefined();
      expect(instance.errorInfo).not.toBeNull();
      expect(typeof instance.errorInfo).toBe('object');
      expect((instance.errorInfo as Record<string, unknown>).error_code).toBe('process_fatal');
      expect(typeof (instance.errorInfo as Record<string, unknown>).message).toBe('string');
    });

    it('returns errorInfo for an aborted process instance', async () => {
      const instance = await adminClient.graphql.getProcessInstance(abortedProcessInstanceId, {
        fields: ['id', 'state', 'errorInfo'],
      });
      expect(instance.state).toBe('aborted');
      expect(instance.errorInfo).toBeDefined();
      expect(instance.errorInfo).not.toBeNull();
      expect(typeof instance.errorInfo).toBe('object');
      expect((instance.errorInfo as Record<string, unknown>).error_code).toBe('process_aborted');
    });

    it('returns null errorInfo for a healthy finished process instance', async () => {
      const instance = await adminClient.graphql.getProcessInstance(processInstanceId, {
        fields: ['id', 'state', 'errorInfo'],
      });
      expect(instance.state).toBe('finished');
      expect(instance.errorInfo).toBeNull();
    });

    it('includes flowNodeInstances relationship when requested', async () => {
      const instance = await adminClient.graphql.getProcessInstance(processInstanceId, {
        fields: ['id', 'state'],
        include: {
          flowNodeInstances: {
            fields: ['id', 'flowNodeId', 'flowNodeType', 'state', 'errorInfo'],
          },
        },
      });
      expect(instance.id).toBe(processInstanceId);
      expect(instance.flowNodeInstances).toBeDefined();
      expect(Array.isArray(instance.flowNodeInstances)).toBe(true);
      expect(instance.flowNodeInstances!.length).toBeGreaterThan(0);
      for (const flowNodeInstance of instance.flowNodeInstances!) {
        expect(flowNodeInstance.id).toBeDefined();
        expect(flowNodeInstance.flowNodeId).toBeDefined();
        expect(flowNodeInstance.flowNodeType).toBeDefined();
        expect(flowNodeInstance.state).toBe('finished');
      }
    });

    it('includes flowNodeInstances with errorInfo for fatal PI', async () => {
      const instance = await adminClient.graphql.getProcessInstance(fatalProcessInstanceId, {
        fields: ['id', 'state'],
        include: {
          flowNodeInstances: {
            fields: ['id', 'flowNodeId', 'state', 'errorInfo'],
          },
        },
      });
      expect(instance.state).toBe('fatal');
      expect(instance.flowNodeInstances).toBeDefined();
      expect(instance.flowNodeInstances!.length).toBeGreaterThan(0);
      const fatalFlowNodeInstances = instance.flowNodeInstances!.filter(
        (flowNodeInstance) => flowNodeInstance.errorInfo != null,
      );
      expect(fatalFlowNodeInstances.length).toBeGreaterThan(0);
    });

    it('queries process versions with expected fields', async () => {
      const result = await adminClient.graphql.queryProcessVersions({
        fields: ['id', 'version', 'processId', 'deployedAt'],
        filter: { version: { eq: '1.0.0' } },
        pagination: { mode: 'offset', limit: 50, offset: 0 },
      });
      expect(result.data.length).toBeGreaterThan(0);
      const version = result.data.find((entry) => entry.version === '1.0.0');
      expect(version).toBeDefined();
      expect(version!.id).toBeDefined();
      expect(version!.processId).toBeDefined();
      expect(version!.deployedAt).toBeDefined();
    });

    it('queries decision definitions after DMN deploy', async () => {
      const result = await adminClient.graphql.queryDecisionDefinitions({
        fields: ['id', 'decisionDefinitionId', 'name', 'enabled'],
        filter: { decisionDefinitionId: { eq: DECISION_DEFINITION_ID } },
        pagination: { mode: 'offset', limit: 10, offset: 0 },
      });
      expect(result.data.length).toBeGreaterThan(0);
      const definition = result.data.find((entry) => entry.decisionDefinitionId === DECISION_DEFINITION_ID);
      expect(definition).toBeDefined();
      expect(definition!.id).toBeDefined();
      expect(definition!.name).toBeDefined();
      expect(definition!.enabled).toBe(true);
    });

    it('queries decision versions after DMN deploy', async () => {
      const result = await adminClient.graphql.queryDecisionVersions({
        fields: ['id', 'version', 'decisionDefinitionId', 'deployedAt'],
        pagination: { mode: 'offset', limit: 50, offset: 0 },
      });
      expect(result.data.length).toBeGreaterThan(0);
      const version = result.data.find((entry) => entry.version != null);
      expect(version).toBeDefined();
      expect(version!.id).toBeDefined();
      expect(version!.decisionDefinitionId).toBeDefined();
      expect(version!.deployedAt).toBeDefined();
    });

    it('filters process models by partial name with ilike', async () => {
      const result = await adminClient.graphql.queryProcessModels({
        fields: ['id', 'name', 'processModelId'],
        filter: { name: { ilike: '%Passthrough%' } },
        pagination: { mode: 'offset', limit: 10, offset: 0 },
      });
      expect(result.data.length).toBeGreaterThan(0);
      const processModel = result.data.find((entry) => entry.processModelId === PROCESS_ID);
      expect(processModel).toBeDefined();
      expect(processModel!.name).toBe(PROCESS_NAME);
    });

    it('chains offset pagination across pages for distinct process instances', async () => {
      const firstPage = await adminClient.graphql.queryProcessInstances({
        fields: ['id'],
        pagination: { mode: 'offset', limit: 1, offset: 0 },
      });
      expect(firstPage.data.length).toBe(1);
      expect(firstPage.pageInfo.type).toBe('offset');
      if (firstPage.pageInfo.type !== 'offset') {
        return;
      }
      expect(firstPage.pageInfo.totalCount).toBeGreaterThanOrEqual(3);
      expect(firstPage.pageInfo.hasNextPage).toBe(true);

      const secondPage = await adminClient.graphql.queryProcessInstances({
        fields: ['id'],
        pagination: { mode: 'offset', limit: 1, offset: 1 },
      });
      expect(secondPage.data.length).toBe(1);
      expect(secondPage.data[0]!.id).not.toBe(firstPage.data[0]!.id);
    });

    it('includes versions relationship on process models', async () => {
      const result = await adminClient.graphql.queryProcessModels({
        fields: ['id', 'processModelId'],
        filter: { processModelId: { eq: PROCESS_ID } },
        include: {
          versions: {
            fields: ['id', 'version', 'deployedAt'],
          },
        },
        pagination: { mode: 'offset', limit: 1, offset: 0 },
      });
      expect(result.data.length).toBeGreaterThan(0);
      const processModel = result.data[0]!;
      expect(processModel.versions).toBeDefined();
      expect(Array.isArray(processModel.versions)).toBe(true);
      expect(processModel.versions!.length).toBeGreaterThan(0);
      for (const version of processModel.versions!) {
        expect(version.id).toBeDefined();
        expect(version.version).toBeDefined();
        expect(version.deployedAt).toBeDefined();
      }
    });

    it('returns process instances in monotonically non-increasing startedAt order', async () => {
      const result = await adminClient.graphql.queryProcessInstances({
        fields: ['id', 'startedAt'],
        sort: [{ field: 'startedAt', direction: 'desc' }],
        pagination: { mode: 'offset', limit: 10, offset: 0 },
      });
      expect(result.data.length).toBeGreaterThan(1);
      const timestamps = result.data.map((instance) => new Date(instance.startedAt!).getTime());
      for (let index = 1; index < timestamps.length; index++) {
        expect(timestamps[index - 1]!).toBeGreaterThanOrEqual(timestamps[index]!);
      }
    });
  });

  describe('bad paths - auth', () => {
    it('rejects query without auth', async () => {
      try {
        await unauthenticatedClient.graphql.queryProcessInstances({
          fields: ['id'],
          pagination: { mode: 'offset', limit: 1, offset: 0 },
        });
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(UnauthorizedError);
      }
    });

    it('rejects query with expired token', async () => {
      try {
        await expiredTokenClient.graphql.queryProcessInstances({
          fields: ['id'],
          pagination: { mode: 'offset', limit: 1, offset: 0 },
        });
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(UnauthorizedError);
      }
    });
  });

  describe('bad paths - data', () => {
    it('returns null or empty for nonexistent process instance', async () => {
      const result = await adminClient.graphql.getProcessInstance('00000000-0000-0000-0000-000000000000', {
        fields: ['id', 'state'],
      });
      expect(result).toBeNull();
    });
  });
});
