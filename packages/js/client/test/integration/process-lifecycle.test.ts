import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { DaemonEngineClient } from '../../src/daemon-engine-client.js';
import {
  ensureEngineReachable,
  createAdminClient,
  createReadOnlyClient,
  deployFixture,
  cleanupInstances,
  readFixture,
} from '../support/test-engine.js';
import {
  ForbiddenError,
  NotFoundError,
  ParseError,
  ActiveInstancesExistError,
  VersionExistsError,
} from '@elraptorus/daemonengine_sdk';

let adminClient: DaemonEngineClient;
let readOnlyClient: DaemonEngineClient;

const passthroughProcessModelId = 'integration-passthrough';
const userTaskProcessModelId = 'integration-user-task';
const nonexistentProcessModelId = 'nonexistent-process-id-xyz';

beforeAll(async () => {
  await ensureEngineReachable();
  adminClient = await createAdminClient();
  readOnlyClient = await createReadOnlyClient();
  await deployFixture(adminClient, 'integration-passthrough.bpmn');
  await deployFixture(adminClient, 'integration-user-task.bpmn');
});

afterAll(async () => {
  await cleanupInstances(adminClient);
});

describe.sequential('Process Lifecycle', () => {
  describe('happy paths', () => {
    it('lists deployed processes', async () => {
      const processes = await adminClient.processes.getAll();
      const found = processes.find((process) => process.id === passthroughProcessModelId);
      expect(found).toBeDefined();
    });

    it('listing includes versionId on each process model', async () => {
      const processes = await adminClient.processes.getAll();
      const found = processes.find((process) => process.id === passthroughProcessModelId);
      expect(found).toBeDefined();
      expect(found!.versionId).toBeDefined();
      expect(typeof found!.versionId).toBe('string');
      expect(found!.versionId!.length).toBeGreaterThan(0);
    });

    it('gets a process by ID', async () => {
      const process = await adminClient.processes.get(passthroughProcessModelId);
      expect(process.id).toBe(passthroughProcessModelId);
    });

    it('detail response includes versionId', async () => {
      const process = await adminClient.processes.get(passthroughProcessModelId);
      expect(process.versionId).toBeDefined();
      expect(typeof process.versionId).toBe('string');
      expect(process.versionId!.length).toBeGreaterThan(0);
    });

    it('gets a process with XML', async () => {
      const process = await adminClient.processes.get(passthroughProcessModelId, {
        includeXml: true,
      });
      expect(process.bpmnXml).toBeDefined();
      expect(process.bpmnXml).toContain('integration-passthrough');
    });

    it('gets versions', async () => {
      const versions = await adminClient.processes.getVersions(passthroughProcessModelId);
      expect(versions.length).toBeGreaterThanOrEqual(1);
    });

    it('disables and enables a process', async () => {
      await adminClient.processes.disable(passthroughProcessModelId);
      await adminClient.processes.enable(passthroughProcessModelId);
    });
  });

  describe('bad paths - deploy', () => {
    it('rejects deploy without deploy_bpmn claim', async () => {
      try {
        await readOnlyClient.processes.deploy('<invalid/>');
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ForbiddenError);
        if (error instanceof ForbiddenError) {
          expect(error.statusCode).toBe(403);
          expect(error.errorCode).toBe('forbidden');
          expect(error.requiredClaim).toBe('deploy_bpmn');
        }
      }
    });

    it('rejects deploy of invalid XML', async () => {
      try {
        await adminClient.processes.deploy('this is not valid bpmn xml');
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ParseError);
        if (error instanceof ParseError) {
          expect(error.statusCode).toBe(400);
          expect(error.errorCode).toBe('parse_error');
        }
      }
    });

    it('rejects deploy of duplicate version with 409 VersionExistsError', async () => {
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

  describe('bad paths - get/list', () => {
    it('returns 404 for nonexistent process', async () => {
      try {
        await adminClient.processes.get(nonexistentProcessModelId);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(NotFoundError);
        if (error instanceof NotFoundError) {
          expect(error.statusCode).toBe(404);
          expect(error.errorCode).toBe('not_found');
        }
      }
    });

    it('returns 404 for versions of nonexistent process', async () => {
      try {
        await adminClient.processes.getVersions(nonexistentProcessModelId);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(NotFoundError);
        if (error instanceof NotFoundError) {
          expect(error.statusCode).toBe(404);
          expect(error.errorCode).toBe('not_found');
        }
      }
    });
  });

  describe('bad paths - enable/disable', () => {
    it('rejects enable without deploy_bpmn claim', async () => {
      try {
        await readOnlyClient.processes.enable(passthroughProcessModelId);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ForbiddenError);
        if (error instanceof ForbiddenError) {
          expect(error.statusCode).toBe(403);
          expect(error.errorCode).toBe('forbidden');
          expect(error.requiredClaim).toBe('deploy_bpmn');
        }
      }
    });

    it('rejects disable without deploy_bpmn claim', async () => {
      try {
        await readOnlyClient.processes.disable(passthroughProcessModelId);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ForbiddenError);
        if (error instanceof ForbiddenError) {
          expect(error.statusCode).toBe(403);
          expect(error.errorCode).toBe('forbidden');
          expect(error.requiredClaim).toBe('deploy_bpmn');
        }
      }
    });

    it('returns 404 for enable of nonexistent process', async () => {
      try {
        await adminClient.processes.enable(nonexistentProcessModelId);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(NotFoundError);
        if (error instanceof NotFoundError) {
          expect(error.statusCode).toBe(404);
          expect(error.errorCode).toBe('not_found');
        }
      }
    });
  });

  describe('bad paths - delete/undeploy', () => {
    it('rejects delete version without delete_bpmn claim', async () => {
      try {
        await readOnlyClient.processes.deleteVersion(passthroughProcessModelId, '1.0.0');
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ForbiddenError);
        if (error instanceof ForbiddenError) {
          expect(error.statusCode).toBe(403);
          expect(error.errorCode).toBe('forbidden');
          expect(error.requiredClaim).toBe('delete_bpmn');
        }
      }
    });

    it('rejects undeploy without delete_bpmn claim', async () => {
      try {
        await readOnlyClient.processes.undeploy(passthroughProcessModelId);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(ForbiddenError);
        if (error instanceof ForbiddenError) {
          expect(error.statusCode).toBe(403);
          expect(error.errorCode).toBe('forbidden');
          expect(error.requiredClaim).toBe('delete_bpmn');
        }
      }
    });

    it('rejects undeploy with active process instances', async () => {
      await adminClient.processes.start(userTaskProcessModelId);
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
        await cleanupInstances(adminClient);
      }
    });

    it('returns 404 for delete of nonexistent version', async () => {
      try {
        await adminClient.processes.deleteVersion(passthroughProcessModelId, '99.99.99');
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(NotFoundError);
        if (error instanceof NotFoundError) {
          expect(error.statusCode).toBe(404);
          expect(error.errorCode).toBe('not_found');
        }
      }
    });
  });
});
