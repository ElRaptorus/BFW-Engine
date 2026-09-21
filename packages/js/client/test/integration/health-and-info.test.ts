import { describe, it, expect, beforeAll } from 'vitest';

import { UnauthorizedError } from '@elraptorus/bfw_engine_sdk';

import type { BfwEngineClient } from '../../src/bfw-engine-client.js';
import {
  createAdminClient,
  createExpiredTokenClient,
  createUnauthenticatedClient,
  ensureEngineReachable,
} from '../support/test-engine.js';

beforeAll(async () => {
  await ensureEngineReachable();
});

let adminClient: BfwEngineClient;

beforeAll(async () => {
  adminClient = await createAdminClient();
});

describe('Health & Info', () => {
  describe('happy paths', () => {
    it('health() resolves (204 No Content)', async () => {
      await expect(adminClient.engine.health()).resolves.toBeUndefined();
    });

    it('info() returns EngineInfoResponse with engineId, version, startedAt (all strings)', async () => {
      const engineInfoResponse = await adminClient.engine.info();
      expect(typeof engineInfoResponse.engineId).toBe('string');
      expect(typeof engineInfoResponse.version).toBe('string');
      expect(typeof engineInfoResponse.startedAt).toBe('string');
    });

    it('stats() returns StatsResponse (verify it is an object with properties)', async () => {
      const statsResponse = await adminClient.engine.stats();
      expect(typeof statsResponse).toBe('object');
      expect(statsResponse).not.toBeNull();
      expect(Object.keys(statsResponse).length).toBeGreaterThan(0);
    });

    it('metrics() returns a string or null', async () => {
      const metricsPayload = await adminClient.engine.metrics();
      expect(metricsPayload === null || typeof metricsPayload === 'string').toBe(true);
    });
  });

  describe('bad paths', () => {
    let unauthenticatedClient: BfwEngineClient;
    let expiredTokenClient: BfwEngineClient;

    beforeAll(async () => {
      unauthenticatedClient = await createUnauthenticatedClient();
      expiredTokenClient = await createExpiredTokenClient();
    });

    it('stats() without auth (unauthenticatedClient) throws UnauthorizedError', async () => {
      try {
        await unauthenticatedClient.engine.stats();
        expect.fail('Should have thrown');
      } catch (error: unknown) {
        expect(error).toBeInstanceOf(UnauthorizedError);
        if (error instanceof UnauthorizedError) {
          expect(error.statusCode).toBe(401);
        }
      }
    });

    it('stats() with expired token throws UnauthorizedError', async () => {
      try {
        await expiredTokenClient.engine.stats();
        expect.fail('Should have thrown');
      } catch (error: unknown) {
        expect(error).toBeInstanceOf(UnauthorizedError);
        if (error instanceof UnauthorizedError) {
          expect(error.statusCode).toBe(401);
        }
      }
    });

    it('health() works WITHOUT auth (skipAuth route)', async () => {
      await expect(unauthenticatedClient.engine.health()).resolves.toBeUndefined();
    });

    it('info() works WITHOUT auth (skipAuth route)', async () => {
      await expect(unauthenticatedClient.engine.info()).resolves.toMatchObject({
        engineId: expect.any(String),
        version: expect.any(String),
        startedAt: expect.any(String),
      });
    });

    it('metrics() works WITHOUT auth (skipAuth route)', async () => {
      const metricsPayload = await unauthenticatedClient.engine.metrics();
      expect(metricsPayload === null || typeof metricsPayload === 'string').toBe(true);
    });
  });
});
