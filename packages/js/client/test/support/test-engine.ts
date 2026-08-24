import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { SignJWT } from 'jose';
import type { EngineEventEnvelope, UserTaskCreated } from '@elraptorus/daemonengine_sdk';
import { DaemonEngineError } from '@elraptorus/daemonengine_sdk';

import { DaemonEngineClient } from '../../src/daemon-engine-client.js';

const THIS_DIR = dirname(fileURLToPath(import.meta.url));
const FIXTURES_DIR = resolve(THIS_DIR, '../integration/fixtures');
const DMN_FIXTURES_DIR = resolve(FIXTURES_DIR, 'dmn');

const DEFAULT_SECRET = 'BloodForTheBloodGod!_SkullsForTheSkullThrone!';

// ---------------------------------------------------------------------------
// Environment helpers
// ---------------------------------------------------------------------------

export function engineHttpUrl(): string {
  return process.env['ENGINE_HTTP_URL'] ?? 'http://localhost:4100';
}

export function engineWsUrl(): string {
  return process.env['ENGINE_WS_URL'] ?? 'ws://localhost:4100/socket';
}

// ---------------------------------------------------------------------------
// JWT minting
// ---------------------------------------------------------------------------

export async function mintTestToken(claims?: Record<string, unknown>): Promise<string> {
  const secret = process.env['ENGINE_JWT_SECRET'] ?? DEFAULT_SECRET;
  const secretKey = new TextEncoder().encode(secret);

  const builder = new SignJWT({
    sub: 'integration-test-user',
    roles: ['admin'],
    groups: [],
    deploy_bpmn: true,
    delete_bpmn: true,
    deploy_dmn: true,
    delete_dmn: true,
    abort_process_instance: 'all',
    delete_process_instance: 'all',
    trigger_signal: 'all',
    trigger_message: 'all',
    trigger_escalation: true,
    'lane:default': "write",
    zeeky_boogie_doog: true,
    ...claims,
  })
    .setProtectedHeader({ alg: 'HS256' })
    .setIssuedAt()
    .setExpirationTime('1h');

  return builder.sign(secretKey);
}

export async function mintExpiredToken(claims?: Record<string, unknown>): Promise<string> {
  const secret = process.env['ENGINE_JWT_SECRET'] ?? DEFAULT_SECRET;
  const secretKey = new TextEncoder().encode(secret);

  const issuedAt = Math.floor(Date.now() / 1000) - 7200; // 2 hours ago
  const expiration = issuedAt + 3600; // 1 hour after issue = still 1 hour ago

  const builder = new SignJWT({
    sub: 'expired-test-user',
    roles: [],
    groups: [],
    ...claims,
  })
    .setProtectedHeader({ alg: 'HS256' })
    .setIssuedAt(issuedAt)
    .setExpirationTime(expiration);

  return builder.sign(secretKey);
}

// ---------------------------------------------------------------------------
// Client factories (claim-scoped)
// ---------------------------------------------------------------------------

function clientFromFactory(tokenFactory: () => Promise<string>): DaemonEngineClient {
  return new DaemonEngineClient(engineHttpUrl(), tokenFactory, { wsUrl: engineWsUrl() });
}

export async function createAdminClient(): Promise<DaemonEngineClient> {
  return clientFromFactory(() => mintTestToken());
}

export async function createReadOnlyClient(): Promise<DaemonEngineClient> {
  return clientFromFactory(() =>
    mintTestToken({
      sub: 'readonly-user',
      deploy_bpmn: false,
      delete_bpmn: false,
      deploy_dmn: false,
      delete_dmn: false,
      abort_process_instance: 'none',
      delete_process_instance: 'none',
      trigger_signal: 'none',
      trigger_message: 'none',
      zeeky_boogie_doog: false,
    }),
  );
}

export async function createDeployerClient(): Promise<DaemonEngineClient> {
  return clientFromFactory(() =>
    mintTestToken({
      sub: 'deployer-user',
      deploy_bpmn: true,
      delete_bpmn: false,
      abort_process_instance: 'none',
      delete_process_instance: 'none',
      zeeky_boogie_doog: false,
    }),
  );
}

export async function createDeleterClient(): Promise<DaemonEngineClient> {
  return clientFromFactory(() =>
    mintTestToken({
      sub: 'deleter-user',
      deploy_bpmn: false,
      delete_bpmn: true,
      abort_process_instance: 'none',
      delete_process_instance: 'none',
      zeeky_boogie_doog: false,
    }),
  );
}

export async function createOwnPiClient(extraClaims?: Record<string, unknown>): Promise<DaemonEngineClient> {
  return clientFromFactory(() =>
    mintTestToken({
      sub: 'own-pi-user',
      deploy_bpmn: true,
      delete_bpmn: false,
      abort_process_instance: 'own',
      delete_process_instance: 'own',
      zeeky_boogie_doog: false,
      ...extraClaims,
    }),
  );
}

export async function createAllPiClient(): Promise<DaemonEngineClient> {
  return clientFromFactory(() =>
    mintTestToken({
      sub: 'all-pi-user',
      deploy_bpmn: true,
      delete_bpmn: false,
      abort_process_instance: 'all',
      delete_process_instance: 'all',
      zeeky_boogie_doog: false,
    }),
  );
}

export async function createLaneClient(laneNames: string[]): Promise<DaemonEngineClient> {
  const laneClaims: Record<string, string> = {};
  for (const lane of laneNames) {
    // Boolean `true` is rejected by the engine; `"write"` is the acting value.
    laneClaims[`lane:${lane}`] = 'write';
  }
  return clientFromFactory(() =>
    mintTestToken({
      sub: 'lane-user',
      deploy_bpmn: true,
      delete_bpmn: false,
      abort_process_instance: 'none',
      delete_process_instance: 'none',
      zeeky_boogie_doog: false,
      ...laneClaims,
    }),
  );
}

export async function createUnauthenticatedClient(): Promise<DaemonEngineClient> {
  return new DaemonEngineClient(engineHttpUrl(), 'garbage-not-a-jwt', { wsUrl: engineWsUrl() });
}

export async function createExpiredTokenClient(): Promise<DaemonEngineClient> {
  const token = await mintExpiredToken();
  return new DaemonEngineClient(engineHttpUrl(), token, { wsUrl: engineWsUrl() });
}

export async function createClientWithToken(token: string): Promise<DaemonEngineClient> {
  return new DaemonEngineClient(engineHttpUrl(), token, { wsUrl: engineWsUrl() });
}

export async function createAdminBypassOnlyClient(): Promise<DaemonEngineClient> {
  return clientFromFactory(() =>
    mintTestToken({
      sub: 'admin-bypass-only',
      deploy_bpmn: false,
      delete_bpmn: false,
      abort_process_instance: 'none',
      delete_process_instance: 'none',
      zeeky_boogie_doog: true,
    }),
  );
}

// ---------------------------------------------------------------------------
// Engine reachability
// ---------------------------------------------------------------------------

export async function ensureEngineReachable(): Promise<void> {
  const url = engineHttpUrl();
  const response = await fetch(`${url}/health`).catch(() => null);
  if (!response || !response.ok) {
    throw new Error(
      `Engine not reachable at ${url}/health. ` +
        `Start it with: docker compose -f docker-compose.dev.yml up -d`,
    );
  }
}

// ---------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------

export function readFixture(fixtureName: string): string {
  const filePath = resolve(FIXTURES_DIR, fixtureName);
  return readFileSync(filePath, 'utf-8');
}

export async function deployFixture(
  client: DaemonEngineClient,
  fixtureName: string | string[],
): Promise<void> {
  const names = Array.isArray(fixtureName) ? fixtureName : [fixtureName];
  for (const name of names) {
    const source = readFixture(name);
    try {
      await client.processes.deploy(source);
    } catch (error: unknown) {
      if (error instanceof DaemonEngineError && error.statusCode === 409) {
        continue;
      }
      throw error;
    }
  }
}

// ---------------------------------------------------------------------------
// Lifecycle helpers
// ---------------------------------------------------------------------------

export async function waitForState(
  client: DaemonEngineClient,
  processInstanceId: string,
  targetState: string,
  timeoutMs = 15_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const instance = await client.graphql.getProcessInstance(processInstanceId, {
      fields: ['state'],
    });
    if (instance.state === targetState) {
      return;
    }
    await sleep(200);
  }
  throw new Error(`Process instance ${processInstanceId} did not reach state '${targetState}' within ${timeoutMs}ms`);
}

export async function waitForUserTask(
  client: DaemonEngineClient,
  processInstanceId: string,
  timeoutMs = 15_000,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let resolved = false;

  const flowNodeInstanceId = await new Promise<string>((resolvePromise, reject) => {
    const timer = setTimeout(() => {
      subscription?.dispose();
      reject(new Error(`No UserTaskCreated event for PI ${processInstanceId} within ${timeoutMs}ms`));
    }, timeoutMs);

    let subscription: { dispose(): void } | undefined;

    const finish = (fniId: string) => {
      if (resolved) return;
      resolved = true;
      clearTimeout(timer);
      subscription?.dispose();
      resolvePromise(fniId);
    };

    client.notifications
      .subscribeProcessInstance(processInstanceId, (event: EngineEventEnvelope) => {
        if (event.type === 'UserTaskCreated') {
          const userTaskEvent = event.data as UserTaskCreated;
          finish(userTaskEvent.flowNodeInstanceId);
        }
      })
      .then((sub) => {
        subscription = sub;
      })
      .catch((error) => {
        clearTimeout(timer);
        reject(error);
      });

    (async () => {
      while (!resolved && Date.now() < deadline) {
        try {
          const result = await client.graphql.queryFlowNodeInstances({
            fields: ['id', 'state', 'flowNodeType'],
            filter: {
              processInstanceId: { eq: processInstanceId },
              flowNodeType: { eq: 'user_task' },
              state: { in: ['active', 'waiting'] },
            },
            pagination: { mode: 'offset', limit: 1, offset: 0 },
          });
          if (result.data.length > 0) {
            finish(result.data[0].id);
            return;
          }
        } catch {
          // GraphQL query may fail during startup; keep polling
        }
        await sleep(300);
      }
    })();
  });

  await pollUntilFniWaiting(client, flowNodeInstanceId);
  return flowNodeInstanceId;
}

async function pollUntilFniWaiting(
  client: DaemonEngineClient,
  flowNodeInstanceId: string,
  timeoutMs = 10_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const result = await client.graphql.queryFlowNodeInstances({
      fields: ['id', 'state'],
      filter: { id: { eq: flowNodeInstanceId } },
      pagination: { mode: 'offset', limit: 1, offset: 0 },
    });
    if (result.data.length > 0 && result.data[0].state === 'waiting') {
      return;
    }
    await sleep(100);
  }
  throw new Error(`FNI ${flowNodeInstanceId} did not reach 'waiting' state within ${timeoutMs}ms`);
}

export async function cleanupInstances(client: DaemonEngineClient): Promise<void> {
  try {
    const instances = await client.graphql.queryProcessInstances({
      fields: ['id', 'state'],
      pagination: { mode: 'offset', limit: 500, offset: 0 },
    });

    for (const instance of instances.data) {
      if (instance.state !== 'finished' && instance.state !== 'aborted' && instance.state !== 'fatal') {
        try {
          await client.processInstances.abort(instance.id);
        } catch {
          // swallow
        }
      }
      try {
        await client.processInstances.delete(instance.id);
      } catch {
        // swallow
      }
    }
  } catch {
    // best-effort cleanup
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ---------------------------------------------------------------------------
// DMN fixture helpers
// ---------------------------------------------------------------------------

export function readDmnFixture(fixtureName: string): string {
  const filePath = resolve(DMN_FIXTURES_DIR, fixtureName);
  return readFileSync(filePath, 'utf-8');
}

export async function deployDmnFixture(
  client: DaemonEngineClient,
  fixtureName: string | string[],
): Promise<void> {
  const names = Array.isArray(fixtureName) ? fixtureName : [fixtureName];
  for (const name of names) {
    const source = readDmnFixture(name);
    try {
      await client.decisions.deploy(source);
    } catch (error: unknown) {
      if (error instanceof DaemonEngineError && error.statusCode === 409) {
        continue;
      }
      throw error;
    }
  }
}
