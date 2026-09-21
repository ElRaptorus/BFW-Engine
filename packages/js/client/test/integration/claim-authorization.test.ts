import { ForbiddenError, NotFoundError } from '@elraptorus/bfw_engine_sdk';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

import type { BfwEngineClient } from '../../src/bfw-engine-client.js';
import {
  cleanupInstances,
  createAdminBypassOnlyClient,
  createAdminClient,
  createAllPiClient,
  createDeleterClient,
  createDeployerClient,
  createLaneClient,
  createOwnPiClient,
  createReadOnlyClient,
  deployFixture,
  ensureEngineReachable,
  readFixture,
  waitForState,
  waitForUserTask,
} from '../support/test-engine.js';

let adminClient: BfwEngineClient;
let readOnlyClient: BfwEngineClient;
let deployerClient: BfwEngineClient;
let deleterClient: BfwEngineClient;
let ownProcessInstanceScopeClient: BfwEngineClient;
let allProcessInstancesClient: BfwEngineClient;
let laneManagersClient: BfwEngineClient;
let laneAccountingClient: BfwEngineClient;
let adminBypassClient: BfwEngineClient;

const PASSTHROUGH_PROCESS_MODEL_ID = 'integration-passthrough';
const LANE_START_PROCESS_MODEL_ID = 'integration-lane-start';
const USER_TASK_LANE_PROCESS_MODEL_ID = 'integration-user-task-lane';
const USER_TASK_PROCESS_MODEL_ID = 'integration-user-task';

beforeAll(async () => {
  await ensureEngineReachable();
  adminClient = await createAdminClient();
  readOnlyClient = await createReadOnlyClient();
  deployerClient = await createDeployerClient();
  deleterClient = await createDeleterClient();
  ownProcessInstanceScopeClient = await createOwnPiClient();
  allProcessInstancesClient = await createAllPiClient();
  laneManagersClient = await createLaneClient(['managers']);
  laneAccountingClient = await createLaneClient(['accounting']);
  adminBypassClient = await createAdminBypassOnlyClient();
  await adminClient.notifications.connect();
  await deployFixture(adminClient, 'integration-passthrough.bpmn');
  await deployFixture(adminClient, 'integration-lane-start.bpmn');
  await deployFixture(adminClient, 'integration-user-task-lane.bpmn');
  await deployFixture(adminClient, 'integration-user-task.bpmn');
});

afterAll(async () => {
  await cleanupInstances(adminClient);
  adminClient.notifications.disconnect();
});

describe('Claim Authorization', { concurrent: false }, () => {
  describe('deploy_bpmn claim', () => {
    it('client with deploy_bpmn can enable a process definition', async () => {
      await deployerClient.processes.enable(PASSTHROUGH_PROCESS_MODEL_ID);
    });

    it('client without deploy_bpmn cannot deploy', async () => {
      try {
        await readOnlyClient.processes.deploy(readFixture('integration-passthrough.bpmn'));
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ForbiddenError);
        if (error instanceof ForbiddenError) {
          expect(error.statusCode).toBe(403);
        }
      }
    });

    it('client with deploy_bpmn can enable and disable', async () => {
      await deployerClient.processes.disable(PASSTHROUGH_PROCESS_MODEL_ID);
      await deployerClient.processes.enable(PASSTHROUGH_PROCESS_MODEL_ID);
    });

    it('client without deploy_bpmn cannot enable', async () => {
      try {
        await readOnlyClient.processes.enable(PASSTHROUGH_PROCESS_MODEL_ID);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ForbiddenError);
      }
    });

    it('client without deploy_bpmn cannot disable', async () => {
      try {
        await readOnlyClient.processes.disable(PASSTHROUGH_PROCESS_MODEL_ID);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ForbiddenError);
      }
    });
  });

  describe('delete_bpmn claim', () => {
    it('client without delete_bpmn cannot delete version', async () => {
      try {
        await readOnlyClient.processes.deleteVersion(PASSTHROUGH_PROCESS_MODEL_ID, '1.0.0');
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ForbiddenError);
      }
    });

    it('client without delete_bpmn cannot undeploy', async () => {
      try {
        await readOnlyClient.processes.undeploy(PASSTHROUGH_PROCESS_MODEL_ID);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ForbiddenError);
      }
    });

    it('client with delete_bpmn can delete a version', async () => {
      const secondVersionBpmn = readFixture('integration-passthrough.bpmn').replace(
        '<bfw:version>1.0.0</bfw:version>',
        '<bfw:version>9.9.9</bfw:version>',
      );
      await deployerClient.processes.deploy(secondVersionBpmn);
      await deleterClient.processes.deleteVersion(PASSTHROUGH_PROCESS_MODEL_ID, '9.9.9');
    });

    it('client with delete_bpmn can undeploy', async () => {
      const disposableBpmn = readFixture('integration-passthrough.bpmn').replaceAll(
        'integration-passthrough',
        'integration-disposable-delete-test',
      );
      await deployerClient.processes.deploy(disposableBpmn);
      await deleterClient.processes.undeploy('integration-disposable-delete-test');
    });
  });

  describe('abort_process_instance claim', () => {
    it('client with abort scope all can abort any running process instance', async () => {
      const { processInstanceId } = await adminClient.processes.start(USER_TASK_LANE_PROCESS_MODEL_ID);
      await waitForUserTask(adminClient, processInstanceId);
      await allProcessInstancesClient.processInstances.abort(processInstanceId);
    });

    it('client with abort scope own can abort own running process instance', async () => {
      const { processInstanceId } = await ownProcessInstanceScopeClient.processes.start(USER_TASK_PROCESS_MODEL_ID);
      await waitForUserTask(adminClient, processInstanceId);
      await ownProcessInstanceScopeClient.processInstances.abort(processInstanceId);
    });

    it('client with abort scope own cannot abort another identity running process instance', async () => {
      const { processInstanceId } = await adminClient.processes.start(USER_TASK_PROCESS_MODEL_ID);
      await waitForUserTask(adminClient, processInstanceId);
      try {
        await ownProcessInstanceScopeClient.processInstances.abort(processInstanceId);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ForbiddenError);
      } finally {
        await adminClient.processInstances.abort(processInstanceId).catch(() => {});
      }
    });

    it('client without abort claim cannot abort', async () => {
      const { processInstanceId } = await adminClient.processes.start(USER_TASK_PROCESS_MODEL_ID);
      await waitForUserTask(adminClient, processInstanceId);
      try {
        await readOnlyClient.processInstances.abort(processInstanceId);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ForbiddenError);
      } finally {
        await adminClient.processInstances.abort(processInstanceId).catch(() => {});
      }
    });
  });

  describe('delete_process_instance claim', () => {
    it('client with delete scope all can delete any terminal process instance', async () => {
      const { processInstanceId } = await adminClient.processes.start(PASSTHROUGH_PROCESS_MODEL_ID);
      await waitForState(adminClient, processInstanceId, 'finished');
      await allProcessInstancesClient.processInstances.delete(processInstanceId);
    });

    it('client with delete scope own can delete own terminal process instance', async () => {
      const { processInstanceId } = await ownProcessInstanceScopeClient.processes.start(PASSTHROUGH_PROCESS_MODEL_ID);
      await waitForState(adminClient, processInstanceId, 'finished');
      await ownProcessInstanceScopeClient.processInstances.delete(processInstanceId);
    });

    it('client with delete scope own cannot delete another identity terminal process instance', async () => {
      const { processInstanceId } = await adminClient.processes.start(PASSTHROUGH_PROCESS_MODEL_ID);
      await waitForState(adminClient, processInstanceId, 'finished');
      try {
        await ownProcessInstanceScopeClient.processInstances.delete(processInstanceId);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ForbiddenError);
      } finally {
        await adminClient.processInstances.delete(processInstanceId).catch(() => {});
      }
    });

    it('client without delete claim cannot delete', async () => {
      const { processInstanceId } = await adminClient.processes.start(PASSTHROUGH_PROCESS_MODEL_ID);
      await waitForState(adminClient, processInstanceId, 'finished');
      try {
        await readOnlyClient.processInstances.delete(processInstanceId);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ForbiddenError);
      } finally {
        await adminClient.processInstances.delete(processInstanceId).catch(() => {});
      }
    });
  });

  describe('lane claims for start', () => {
    it('client with lane managers can start lane-gated process', async () => {
      const result = await laneManagersClient.processes.start(LANE_START_PROCESS_MODEL_ID);
      expect(result.processInstanceId).toBeDefined();
    });

    it('client without lane managers cannot start lane-gated process', async () => {
      try {
        await readOnlyClient.processes.start(LANE_START_PROCESS_MODEL_ID);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(NotFoundError);
      }
    });

    it('global bypass starts lane-gated process', async () => {
      const result = await adminBypassClient.processes.start(LANE_START_PROCESS_MODEL_ID);
      expect(result.processInstanceId).toBeDefined();
    });
  });

  describe('lane claims for user tasks', () => {
    it('client with lane accounting can finish lane-gated user task', async () => {
      const { processInstanceId } = await adminClient.processes.start(USER_TASK_LANE_PROCESS_MODEL_ID);
      const flowNodeInstanceId = await waitForUserTask(adminClient, processInstanceId);
      await laneAccountingClient.userTasks.finish(flowNodeInstanceId, { result: {} });
    });

    it('client without lane accounting gets not found for lane hiding', async () => {
      const { processInstanceId } = await adminClient.processes.start(USER_TASK_LANE_PROCESS_MODEL_ID);
      const flowNodeInstanceId = await waitForUserTask(adminClient, processInstanceId);
      try {
        await readOnlyClient.userTasks.finish(flowNodeInstanceId, { result: {} });
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(NotFoundError);
      } finally {
        await adminClient.userTasks.finish(flowNodeInstanceId, { result: {} }).catch(() => {});
      }
    });

    it('global bypass finishes lane-gated user task', async () => {
      const { processInstanceId } = await adminClient.processes.start(USER_TASK_LANE_PROCESS_MODEL_ID);
      const flowNodeInstanceId = await waitForUserTask(adminClient, processInstanceId);
      await adminBypassClient.userTasks.finish(flowNodeInstanceId, { result: {} });
    });
  });

  describe('zeeky_boogie_doog global bypass', () => {
    it('global bypass can enable', async () => {
      await adminBypassClient.processes.enable(PASSTHROUGH_PROCESS_MODEL_ID);
    });

    it('global bypass can start lane-gated process', async () => {
      const result = await adminBypassClient.processes.start(LANE_START_PROCESS_MODEL_ID);
      expect(result.processInstanceId).toBeDefined();
    });

    it('global bypass does not require individual deploy claims for enable and disable', async () => {
      await adminBypassClient.processes.disable(PASSTHROUGH_PROCESS_MODEL_ID);
      await adminBypassClient.processes.enable(PASSTHROUGH_PROCESS_MODEL_ID);
    });
  });
});
