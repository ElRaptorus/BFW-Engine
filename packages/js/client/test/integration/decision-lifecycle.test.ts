/**
 * Integration tests for DMN decision definition lifecycle.
 * Requires a running engine with DMN support.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { DaemonEngineClient } from '../../src/daemon-engine-client.js';
import {
  ensureEngineReachable,
  createAdminClient,
  createReadOnlyClient,
  deployDmnFixture,
  readDmnFixture,
} from '../support/test-engine.js';
import {
  DecisionDefinitionNotFoundError,
  DecisionVersionExistsError,
  DmnParseError,
  ForbiddenError,
} from '@elraptorus/daemonengine_sdk';

const definitionsId = 'definitions_discount';
let adminClient: DaemonEngineClient;
let readOnlyClient: DaemonEngineClient;

beforeAll(async () => {
  await ensureEngineReachable();
  adminClient = await createAdminClient();
  readOnlyClient = await createReadOnlyClient();
});

afterAll(() => {
  adminClient?.dispose();
  readOnlyClient?.dispose();
});

describe.sequential('Decision lifecycle (integration)', () => {
  it('deploys a DMN fixture', async () => {
    const source = readDmnFixture('simple_unique.dmn');
    const response = await adminClient.decisions.deploy(source);
    expect(response.deployed).toBeDefined();
    expect(response.deployed.length).toBeGreaterThanOrEqual(1);
    expect(response.deployed[0].decisionDefinitionId).toBe(definitionsId);
  });

  it('lists all decision definitions', async () => {
    const definitions = await adminClient.decisions.getAll();
    const found = definitions.find((definition) => definition.id === definitionsId);
    expect(found).toBeDefined();
  });

  it('gets decision definition by id', async () => {
    const definition = await adminClient.decisions.get(definitionsId);
    expect(definition.id).toBe(definitionsId);
  });

  it('gets decision versions', async () => {
    const versions = await adminClient.decisions.getVersions(definitionsId);
    expect(versions.length).toBeGreaterThanOrEqual(1);
  });

  it('enable/disable cycle', async () => {
    await adminClient.decisions.disable(definitionsId);
    await adminClient.decisions.enable(definitionsId);
  });

  it('delete version (soft-delete)', async () => {
    const versions = await adminClient.decisions.getVersions(definitionsId);
    const latestVersion = versions[versions.length - 1];
    await adminClient.decisions.deleteVersion(definitionsId, latestVersion.version);
  });

  it('undeploy', async () => {
    await deployDmnFixture(adminClient, 'simple_unique.dmn');
    await adminClient.decisions.undeploy(definitionsId);
    await expect(adminClient.decisions.get(definitionsId)).rejects.toThrow(
      DecisionDefinitionNotFoundError,
    );
  });

  it('deploy forbidden (wrong claims)', async () => {
    const source = readDmnFixture('simple_unique.dmn');
    await expect(readOnlyClient.decisions.deploy(source)).rejects.toThrow(ForbiddenError);
  });

  it('deploy bad XML → DmnParseError', async () => {
    await expect(adminClient.decisions.deploy('not valid xml')).rejects.toThrow(DmnParseError);
  });

  it('deploy duplicate → DecisionVersionExistsError', async () => {
    await deployDmnFixture(adminClient, 'simple_unique.dmn');
    const source = readDmnFixture('simple_unique.dmn');
    await expect(adminClient.decisions.deploy(source)).rejects.toThrow(DecisionVersionExistsError);
    await adminClient.decisions.undeploy(definitionsId);
  });
});
