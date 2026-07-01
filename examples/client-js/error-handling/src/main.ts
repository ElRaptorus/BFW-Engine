import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  DaemonEngineClient,
  mapResponseError,
} from '@elraptorus/daemonengine_client';
import {
  DaemonEngineError,
  NotFoundError,
  PayloadTooLargeError,
  ProcessNotFoundError,
  UnauthorizedError,
  ValidationError,
  VersionExistsError,
} from '@elraptorus/daemonengine_sdk';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function demonstrateProcessNotFoundError(client: DaemonEngineClient): Promise<void> {
  try {
    await client.processes.start('nonexistent-process-model-for-examples');
  } catch (error) {
    if (error instanceof ProcessNotFoundError) {
      console.log('[ProcessNotFoundError]', {
        statusCode: error.statusCode,
        errorCode: error.errorCode,
        message: error.message,
      });
    } else {
      throw error;
    }
  }
}

async function demonstrateNotFoundError(client: DaemonEngineClient): Promise<void> {
  try {
    await client.processes.get('nonexistent-process-model-for-examples-404');
  } catch (error) {
    if (error instanceof NotFoundError) {
      console.log('[NotFoundError]', {
        statusCode: error.statusCode,
        errorCode: error.errorCode,
        message: error.message,
      });
    } else {
      throw error;
    }
  }
}

async function demonstrateUnauthorizedError(engineUrl: string): Promise<void> {
  const clientWithInvalidToken = new DaemonEngineClient(engineUrl, 'not.valid.jwt.structure');
  try {
    await clientWithInvalidToken.engine.stats();
  } catch (error) {
    if (error instanceof UnauthorizedError) {
      console.log('[UnauthorizedError]', {
        statusCode: error.statusCode,
        errorCode: error.errorCode,
        message: error.message,
      });
    } else {
      throw error;
    }
  } finally {
    clientWithInvalidToken.dispose();
  }
}

async function demonstratePayloadTooLargeError(
  client: DaemonEngineClient,
  deployableProcessModelId: string,
): Promise<void> {
  const hugePayload = { blob: 'x'.repeat(70_000) };
  try {
    await client.processes.start(deployableProcessModelId, { payload: hugePayload });
  } catch (error) {
    if (error instanceof PayloadTooLargeError) {
      console.log('[PayloadTooLargeError]', {
        statusCode: error.statusCode,
        errorCode: error.errorCode,
        message: error.message,
        field: error.field,
        size: error.size,
        limit: error.limit,
      });
    } else {
      throw error;
    }
  }
}

function demonstrateValidationErrorShape(): void {
  try {
    throw mapResponseError(422, {
      error: 'unmapped_engine_validation_code',
      message: 'Engine returned 422 without a dedicated SDK subclass',
      failures: [{ path: 'example', detail: 'illustrative' }],
    });
  } catch (error) {
    if (error instanceof ValidationError) {
      console.log('[ValidationError]', {
        statusCode: error.statusCode,
        errorCode: error.errorCode,
        message: error.message,
        failures: error.failures,
      });
    } else {
      throw error;
    }
  }
}

async function demonstrateVersionExistsError(client: DaemonEngineClient, bpmnXml: string): Promise<void> {
  try {
    await client.processes.deploy(bpmnXml);
  } catch (error) {
    if (error instanceof VersionExistsError) {
      console.log('[VersionExistsError]', {
        statusCode: error.statusCode,
        errorCode: error.errorCode,
        message: error.message,
      });
    } else {
      throw error;
    }
  }
}

async function demonstrateDaemonEngineErrorCatchAll(client: DaemonEngineClient, bpmnXml: string): Promise<void> {
  try {
    await client.processes.deploy([bpmnXml, bpmnXml]);
  } catch (error) {
    if (error instanceof DaemonEngineError) {
      console.log('[DaemonEngineError catch-all]', {
        statusCode: error.statusCode,
        errorCode: error.errorCode,
        message: error.message,
      });
    } else {
      throw error;
    }
  }
}

export async function main(): Promise<void> {
  const engineUrl = process.env['ENGINE_URL'] ?? 'http://localhost:4000';
  const token = process.env['ENGINE_TOKEN'] ?? 'dev-token';
  const client = new DaemonEngineClient(engineUrl, token);

  const bpmnPath = resolve(__dirname, '../bpmn/minimal-for-errors.bpmn');
  const bpmnXml = readFileSync(bpmnPath, 'utf8');
  await client.processes.deploy(bpmnXml);

  await demonstrateProcessNotFoundError(client);
  await demonstrateNotFoundError(client);
  await demonstrateUnauthorizedError(engineUrl);
  await demonstratePayloadTooLargeError(client, 'example-error-handling-process');
  demonstrateValidationErrorShape();
  await demonstrateVersionExistsError(client, bpmnXml);
  await demonstrateDaemonEngineErrorCatchAll(client, bpmnXml);

  await client.processes.undeploy('example-error-handling-process');
  client.dispose();
}

main().catch(console.error);
