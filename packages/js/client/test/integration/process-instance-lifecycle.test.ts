import {
  ForbiddenError,
  NotFoundError,
  ProcessDisabledError,
  ProcessInstanceNotTerminalError,
  ProcessNotFoundError,
} from '@elraptorus/bfw_engine_sdk';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

import type { BfwEngineClient } from '../../src/bfw-engine-client.js';
import {
  cleanupInstances,
  createAdminBypassOnlyClient,
  createAdminClient,
  createAllPiClient,
  createLaneClient,
  createOwnPiClient,
  createReadOnlyClient,
  deployFixture,
  ensureEngineReachable,
  waitForState,
} from '../support/test-engine.js';

let adminClient: BfwEngineClient;
let readOnlyClient: BfwEngineClient;
let ownPiClient: BfwEngineClient;
let allPiClient: BfwEngineClient;
let laneManagersClient: BfwEngineClient;
let adminBypassOnlyClient: BfwEngineClient;

const PASSTHROUGH_ID = 'integration-passthrough';
const LANE_START_ID = 'integration-lane-start';
const USER_TASK_ID = 'integration-user-task';

const ABSENT_PROCESS_MODEL_ID = 'integration-absent-process-model-xxxxxxxx';
const ABSENT_PROCESS_INSTANCE_ID = '00000000-0000-4000-8000-000000000099';

beforeAll(async () => {
  await ensureEngineReachable();
  adminClient = await createAdminClient();
  readOnlyClient = await createReadOnlyClient();
  ownPiClient = await createOwnPiClient();
  allPiClient = await createAllPiClient();
  laneManagersClient = await createLaneClient(['managers']);
  adminBypassOnlyClient = await createAdminBypassOnlyClient();
  await deployFixture(adminClient, 'integration-passthrough.bpmn');
  await deployFixture(adminClient, 'integration-lane-start.bpmn');
  await deployFixture(adminClient, 'integration-user-task.bpmn');
});

afterAll(async () => {
  await cleanupInstances(adminClient);
});

describe('Process Instance Lifecycle', () => {
  describe('happy paths', () => {
    it('start passthrough process returns StartResult, completes, queries over GraphQL, then deletes', async () => {
      const startResult = await adminClient.processes.start(PASSTHROUGH_ID);
      expect(typeof startResult.processInstanceId).toBe('string');
      expect(startResult.processModelId).toBe(PASSTHROUGH_ID);
      expect(typeof startResult.version).toBe('string');
      expect(startResult.state).toBe('running');

      await waitForState(adminClient, startResult.processInstanceId, 'finished');

      const processInstanceRecord = await adminClient.graphql.getProcessInstance(startResult.processInstanceId, {
        fields: ['id', 'state'],
      });
      expect(processInstanceRecord.id).toBe(startResult.processInstanceId);
      expect(processInstanceRecord.state).toBe('finished');

      await adminClient.processInstances.delete(startResult.processInstanceId);
    });
  });

  describe('bad paths -- start', () => {
    it('start absent process model throws ProcessNotFoundError', async () => {
      try {
        await adminClient.processes.start(ABSENT_PROCESS_MODEL_ID);
        expect.fail('Should have thrown ProcessNotFoundError');
      } catch (error: unknown) {
        expect(error).toBeInstanceOf(ProcessNotFoundError);
        if (error instanceof ProcessNotFoundError) {
          expect(error.statusCode).toBe(404);
        }
      }
    });

    it('start disabled process throws ProcessDisabledError, then enable restores starts', async () => {
      await adminClient.processes.disable(PASSTHROUGH_ID);
      try {
        try {
          await adminClient.processes.start(PASSTHROUGH_ID);
          expect.fail('Should have thrown ProcessDisabledError');
        } catch (error: unknown) {
          expect(error).toBeInstanceOf(ProcessDisabledError);
          if (error instanceof ProcessDisabledError) {
            expect(error.statusCode).toBe(422);
          }
        }
      } finally {
        await adminClient.processes.enable(PASSTHROUGH_ID);
      }
    });

    it('start lane-scoped process without lane claim throws NotFoundError', async () => {
      try {
        await readOnlyClient.processes.start(LANE_START_ID);
        expect.fail('Should have thrown NotFoundError');
      } catch (error: unknown) {
        expect(error).toBeInstanceOf(NotFoundError);
        if (error instanceof NotFoundError) {
          expect(error.statusCode).toBe(404);
        }
      }
    });

    it('start lane-scoped process with matching lane claim succeeds', async () => {
      const startResult = await laneManagersClient.processes.start(LANE_START_ID);
      expect(typeof startResult.processInstanceId).toBe('string');
      await waitForState(laneManagersClient, startResult.processInstanceId, 'finished');
      await adminClient.processInstances.delete(startResult.processInstanceId);
    });

    it('start lane-scoped process with administrator bypass claim succeeds', async () => {
      const startResult = await adminBypassOnlyClient.processes.start(LANE_START_ID);
      expect(typeof startResult.processInstanceId).toBe('string');
      await waitForState(adminBypassOnlyClient, startResult.processInstanceId, 'finished');
      await adminClient.processInstances.delete(startResult.processInstanceId);
    });
  });

  describe('bad paths -- abort', () => {
    it('abort finished process instance returns 404 (gen_statem terminates on completion)', async () => {
      const startResult = await adminClient.processes.start(PASSTHROUGH_ID);
      await waitForState(adminClient, startResult.processInstanceId, 'finished');
      try {
        await adminClient.processInstances.abort(startResult.processInstanceId);
        expect.fail('Should have thrown NotFoundError');
      } catch (error: unknown) {
        expect(error).toBeInstanceOf(NotFoundError);
        if (error instanceof NotFoundError) {
          expect(error.statusCode).toBe(404);
        }
      } finally {
        await adminClient.processInstances.delete(startResult.processInstanceId);
      }
    });

    it('abort absent process instance throws NotFoundError', async () => {
      try {
        await adminClient.processInstances.abort(ABSENT_PROCESS_INSTANCE_ID);
        expect.fail('Should have thrown NotFoundError');
      } catch (error: unknown) {
        expect(error).toBeInstanceOf(NotFoundError);
        if (error instanceof NotFoundError) {
          expect(error.statusCode).toBe(404);
        }
      }
    });

    it('read-only client abort throws ForbiddenError', async () => {
      const startResult = await adminClient.processes.start(USER_TASK_ID);
      try {
        try {
          await readOnlyClient.processInstances.abort(startResult.processInstanceId);
          expect.fail('Should have thrown ForbiddenError');
        } catch (error: unknown) {
          expect(error).toBeInstanceOf(ForbiddenError);
          if (error instanceof ForbiddenError) {
            expect(error.statusCode).toBe(403);
          }
        }
      } finally {
        await adminClient.processInstances.abort(startResult.processInstanceId);
        await adminClient.processInstances.delete(startResult.processInstanceId);
      }
    });

    it('own-scoped client cannot abort another user process instance; own and all-scoped behave correctly', async () => {
      const administratorUserTaskStartResult = await adminClient.processes.start(USER_TASK_ID);
      try {
        try {
          await ownPiClient.processInstances.abort(administratorUserTaskStartResult.processInstanceId);
          expect.fail('Should have thrown ForbiddenError');
        } catch (error: unknown) {
          expect(error).toBeInstanceOf(ForbiddenError);
          if (error instanceof ForbiddenError) {
            expect(error.statusCode).toBe(403);
          }
        }

        const ownUserTaskStartResult = await ownPiClient.processes.start(USER_TASK_ID);
        await ownPiClient.processInstances.abort(ownUserTaskStartResult.processInstanceId);
        await ownPiClient.processInstances.delete(ownUserTaskStartResult.processInstanceId);

        await allPiClient.processInstances.abort(administratorUserTaskStartResult.processInstanceId);
        await allPiClient.processInstances.delete(administratorUserTaskStartResult.processInstanceId);
      } catch (error: unknown) {
        try {
          await adminClient.processInstances.abort(administratorUserTaskStartResult.processInstanceId);
        } catch {
          // best-effort cleanup
        }
        try {
          await adminClient.processInstances.delete(administratorUserTaskStartResult.processInstanceId);
        } catch {
          // best-effort cleanup
        }
        throw error;
      }
    });
  });

  describe('bad paths -- delete', () => {
    it('delete running process instance throws ProcessInstanceNotTerminalError', async () => {
      const startResult = await adminClient.processes.start(USER_TASK_ID);
      try {
        try {
          await adminClient.processInstances.delete(startResult.processInstanceId);
          expect.fail('Should have thrown ProcessInstanceNotTerminalError');
        } catch (error: unknown) {
          expect(error).toBeInstanceOf(ProcessInstanceNotTerminalError);
          if (error instanceof ProcessInstanceNotTerminalError) {
            expect(error.statusCode).toBe(422);
          }
        }
      } finally {
        await adminClient.processInstances.abort(startResult.processInstanceId);
        await adminClient.processInstances.delete(startResult.processInstanceId);
      }
    });

    it('delete absent process instance throws NotFoundError', async () => {
      try {
        await adminClient.processInstances.delete(ABSENT_PROCESS_INSTANCE_ID);
        expect.fail('Should have thrown NotFoundError');
      } catch (error: unknown) {
        expect(error).toBeInstanceOf(NotFoundError);
        if (error instanceof NotFoundError) {
          expect(error.statusCode).toBe(404);
        }
      }
    });

    it('read-only client delete throws ForbiddenError', async () => {
      const startResult = await adminClient.processes.start(PASSTHROUGH_ID);
      await waitForState(adminClient, startResult.processInstanceId, 'finished');
      try {
        try {
          await readOnlyClient.processInstances.delete(startResult.processInstanceId);
          expect.fail('Should have thrown ForbiddenError');
        } catch (error: unknown) {
          expect(error).toBeInstanceOf(ForbiddenError);
          if (error instanceof ForbiddenError) {
            expect(error.statusCode).toBe(403);
          }
        }
      } finally {
        await adminClient.processInstances.delete(startResult.processInstanceId);
      }
    });

    it('own-scoped client cannot delete another user finished instance; own and all-scoped delete succeed', async () => {
      const administratorPassthroughStartResult = await adminClient.processes.start(PASSTHROUGH_ID);
      await waitForState(adminClient, administratorPassthroughStartResult.processInstanceId, 'finished');
      try {
        try {
          await ownPiClient.processInstances.delete(administratorPassthroughStartResult.processInstanceId);
          expect.fail('Should have thrown ForbiddenError');
        } catch (error: unknown) {
          expect(error).toBeInstanceOf(ForbiddenError);
          if (error instanceof ForbiddenError) {
            expect(error.statusCode).toBe(403);
          }
        }

        const ownPassthroughStartResult = await ownPiClient.processes.start(PASSTHROUGH_ID);
        await waitForState(ownPiClient, ownPassthroughStartResult.processInstanceId, 'finished');
        await ownPiClient.processInstances.delete(ownPassthroughStartResult.processInstanceId);

        await allPiClient.processInstances.delete(administratorPassthroughStartResult.processInstanceId);
      } catch (error: unknown) {
        try {
          await adminClient.processInstances.delete(administratorPassthroughStartResult.processInstanceId);
        } catch {
          // best-effort cleanup
        }
        throw error;
      }
    });
  });
});
