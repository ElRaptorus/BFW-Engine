import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { DaemonEngineClient } from '../../src/daemon-engine-client.js';
import {
  ensureEngineReachable,
  createAdminClient,
  createReadOnlyClient,
  createUnauthenticatedClient,
  deployFixture,
  cleanupInstances,
  readFixture,
  waitForState,
  waitForUserTask,
} from '../support/test-engine.js';
import {
  DaemonEngineError,
  ParseError,
  VersionExistsError,
  NotFoundError,
  ProcessNotFoundError,
  ProcessDisabledError,
  ActiveInstancesExistError,
  ProcessInstanceNotTerminalError,
  FniNotWaitingError,
  UnauthorizedError,
  ForbiddenError,
} from '@elraptorus/daemonengine_sdk';

let adminClient: DaemonEngineClient;
let readOnlyClient: DaemonEngineClient;
let unauthenticatedClient: DaemonEngineClient;

const passthroughProcessModelId = 'integration-passthrough';
const userTaskProcessModelId = 'integration-user-task';

beforeAll(async () => {
  await ensureEngineReachable();
  adminClient = await createAdminClient();
  readOnlyClient = await createReadOnlyClient();
  unauthenticatedClient = await createUnauthenticatedClient();
  await adminClient.notifications.connect();
  await deployFixture(adminClient, 'integration-passthrough.bpmn');
  await deployFixture(adminClient, 'integration-user-task.bpmn');
});

afterAll(async () => {
  await cleanupInstances(adminClient);
  adminClient.notifications.disconnect();
});

describe('Error Mapping', { concurrent: false }, () => {
  describe('ParseError from invalid XML', () => {
    it('maps parse_error with failures array', async () => {
      try {
        await adminClient.processes.deploy('this is not valid bpmn');
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ParseError);
        expect(error).toBeInstanceOf(DaemonEngineError);
        if (error instanceof ParseError) {
          expect(error.errorCode).toBe('parse_error');
          expect(error.rawBody).toBeDefined();
          expect(error.name).toBe('ParseError');
          expect(error.message).toBeTruthy();
        }
      }
    });
  });

  describe('VersionExistsError from duplicate deploy', () => {
    it('maps version_exists with 409', async () => {
      try {
        await adminClient.processes.deploy(readFixture('integration-passthrough.bpmn'));
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(VersionExistsError);
        if (error instanceof VersionExistsError) {
          expect(error.statusCode).toBe(409);
          expect(error.errorCode).toBe('version_exists');
        }
      }
    });
  });

  describe('NotFoundError from nonexistent process', () => {
    it('maps 404 for get', async () => {
      try {
        await adminClient.processes.get('nonexistent-id-xyz');
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(NotFoundError);
        if (error instanceof NotFoundError) {
          expect(error.statusCode).toBe(404);
        }
      }
    });
  });

  describe('ProcessNotFoundError from start nonexistent', () => {
    it('maps process_not_found with 404', async () => {
      try {
        await adminClient.processes.start('nonexistent-process-xyz');
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ProcessNotFoundError);
        if (error instanceof ProcessNotFoundError) {
          expect(error.statusCode).toBe(404);
          expect(error.errorCode).toBe('process_not_found');
        }
      }
    });
  });

  describe('ProcessDisabledError from start disabled process', () => {
    it('maps process_disabled with 422', async () => {
      await adminClient.processes.disable(passthroughProcessModelId);
      try {
        await adminClient.processes.start(passthroughProcessModelId);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ProcessDisabledError);
        if (error instanceof ProcessDisabledError) {
          expect(error.statusCode).toBe(422);
          expect(error.errorCode).toBe('process_disabled');
        }
      } finally {
        await adminClient.processes.enable(passthroughProcessModelId);
      }
    });
  });

  describe('ActiveInstancesExistError from undeploy with active PIs', () => {
    it('maps active_instances_exist with 409', async () => {
      const { processInstanceId } = await adminClient.processes.start(userTaskProcessModelId);
      try {
        await adminClient.processes.undeploy(userTaskProcessModelId);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ActiveInstancesExistError);
        if (error instanceof ActiveInstancesExistError) {
          expect(error.statusCode).toBe(409);
          expect(error.errorCode).toBe('active_instances_exist');
        }
      } finally {
        await adminClient.processInstances.abort(processInstanceId).catch(() => {});
      }
    });
  });

  describe('Abort finished PI returns NotFound (PI gen_statem terminates on completion)', () => {
    it('maps 404 because the PI process is no longer in the runtime registry', async () => {
      const { processInstanceId } = await adminClient.processes.start(passthroughProcessModelId);
      await waitForState(adminClient, processInstanceId, 'finished');
      try {
        await adminClient.processInstances.abort(processInstanceId);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(NotFoundError);
        if (error instanceof NotFoundError) {
          expect(error.statusCode).toBe(404);
        }
      }
    });
  });

  describe('ProcessInstanceNotTerminalError from delete running PI', () => {
    it('maps process_instance_not_terminal with 422', async () => {
      const { processInstanceId } = await adminClient.processes.start(userTaskProcessModelId);
      await waitForUserTask(adminClient, processInstanceId);
      try {
        await adminClient.processInstances.delete(processInstanceId);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ProcessInstanceNotTerminalError);
        if (error instanceof ProcessInstanceNotTerminalError) {
          expect(error.statusCode).toBe(422);
          expect(error.errorCode).toBe('process_instance_not_terminal');
        }
      } finally {
        await adminClient.processInstances.abort(processInstanceId).catch(() => {});
      }
    });
  });

  describe('FniNotWaitingError from finish completed user task', () => {
    it('maps fni terminal state error codes with 422', async () => {
      const { processInstanceId } = await adminClient.processes.start(userTaskProcessModelId);
      const flowNodeInstanceId = await waitForUserTask(adminClient, processInstanceId);
      await adminClient.userTasks.finish(flowNodeInstanceId, { result: {} });
      await waitForState(adminClient, processInstanceId, 'finished');

      try {
        await adminClient.userTasks.finish(flowNodeInstanceId, { result: {} });
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(FniNotWaitingError);
        if (error instanceof FniNotWaitingError) {
          expect(error.statusCode).toBe(422);
          expect(['fni_not_waiting', 'fni_already_finished', 'fni_already_aborted', 'fni_already_interrupted', 'fni_already_fatal']).toContain(error.errorCode);
        }
      }
    });
  });

  describe('NotFoundError from finish nonexistent FNI', () => {
    it('maps 404 for nonexistent user task', async () => {
      try {
        await adminClient.userTasks.finish('00000000-0000-0000-0000-000000000000', {
          result: {},
        });
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(NotFoundError);
        if (error instanceof NotFoundError) {
          expect(error.statusCode).toBe(404);
        }
      }
    });
  });

  describe('UnauthorizedError from missing token', () => {
    it('maps 401 for protected route', async () => {
      try {
        await unauthenticatedClient.engine.stats();
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(UnauthorizedError);
        if (error instanceof UnauthorizedError) {
          expect(error.statusCode).toBe(401);
        }
      }
    });
  });

  describe('ForbiddenError from wrong claim', () => {
    it('maps forbidden with 403 for deploy without deploy_bpmn', async () => {
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
  });

  describe('instanceof narrowing verification', () => {
    it('supports DaemonEngineError base instanceof', async () => {
      try {
        await adminClient.processes.start('nonexistent-xyz');
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(DaemonEngineError);
        expect(error).toBeInstanceOf(ProcessNotFoundError);
        expect(error).not.toBeInstanceOf(ParseError);
        if (error instanceof DaemonEngineError) {
          expect(error.name).toBe('ProcessNotFoundError');
          expect(typeof error.message).toBe('string');
          expect(error.message.length).toBeGreaterThan(0);
        }
      }
    });
  });

  describe('rawBody preservation', () => {
    it('preserves raw body from engine', async () => {
      try {
        await adminClient.processes.start('nonexistent-xyz');
        expect.fail('Should have thrown');
      } catch (error) {
        if (error instanceof DaemonEngineError) {
          expect(error.rawBody).toBeDefined();
          expect(error.rawBody?.error).toBe('process_not_found');
          expect(error.rawBody?.message).toBeDefined();
        }
      }
    });
  });
});
