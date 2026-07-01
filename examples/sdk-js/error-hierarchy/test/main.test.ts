import { describe, expect, it } from 'vitest';

import {
  ActiveInstancesExistError,
  AmbiguousStartEventError,
  ContractViolationError,
  DaemonEngineError,
  DeployValidationFailedError,
  EngineAtCapacityError,
  FniNotWaitingError,
  ForbiddenError,
  GraphqlComplexityLimitError,
  GraphqlDepthLimitError,
  GraphqlIntrospectionDisabledError,
  IncompatibleVersionMigrationError,
  InternalEngineError,
  LinterGateFailedError,
  NoActiveVersionError,
  NoExecutableProcessError,
  NoStartEventError,
  NotFoundError,
  ParseError,
  PayloadTooLargeError,
  ProcessDisabledError,
  ProcessInstanceAlreadyTerminalError,
  ProcessInstanceNotRetriableError,
  ProcessInstanceNotTerminalError,
  ProcessNotFoundError,
  RateLimitedError,
  StartEventNotFoundError,
  UnauthorizedError,
  ValidationError,
  VersionExistsError,
} from '@elraptorus/daemonengine_sdk';
import { FlowNodeInstanceState, ProcessInstanceState } from '@elraptorus/daemonengine_sdk';

import { mapDaemonEngineError } from '../src/map-daemon-engine-error.js';

describe('error hierarchy', () => {
  const allErrors: DaemonEngineError[] = [
    new PayloadTooLargeError('payload', 10, 5),
    new RateLimitedError(1, 'wait'),
    new EngineAtCapacityError(1, 1, 1, 'full'),
    new NotFoundError('x'),
    new ProcessNotFoundError('x'),
    new NoActiveVersionError('x'),
    new UnauthorizedError('x'),
    new ForbiddenError('c', 'v', 'process', 'x'),
    new ValidationError('x', []),
    new DeployValidationFailedError('x'),
    new LinterGateFailedError('x'),
    new ContractViolationError('x', []),
    new ProcessDisabledError('x'),
    new AmbiguousStartEventError('x'),
    new StartEventNotFoundError('x'),
    new NoStartEventError('x'),
    new NoExecutableProcessError('x'),
    new ActiveInstancesExistError('x'),
    new ProcessInstanceAlreadyTerminalError('x', ProcessInstanceState.Finished),
    new ProcessInstanceNotTerminalError('x', ProcessInstanceState.Running),
    new FniNotWaitingError('x', FlowNodeInstanceState.Active),
    new ParseError('x', []),
    new VersionExistsError('x', []),
    new InternalEngineError('x'),
    new ProcessInstanceNotRetriableError('x'),
    new IncompatibleVersionMigrationError('x'),
    new GraphqlDepthLimitError('x'),
    new GraphqlComplexityLimitError('x'),
    new GraphqlIntrospectionDisabledError('x'),
  ];

  it('treats every SDK error class as DaemonEngineError', () => {
    for (const error of allErrors) {
      expect(error).toBeInstanceOf(DaemonEngineError);
      expect(error).toBeInstanceOf(Error);
    }
  });

  it('assigns the expected HTTP status codes', () => {
    expect(new PayloadTooLargeError('payload', 1, 1).statusCode).toBe(413);
    expect(new RateLimitedError(1, 'm').statusCode).toBe(429);
    expect(new EngineAtCapacityError(1, 1, 1, 'm').statusCode).toBe(503);
    expect(new NotFoundError('m').statusCode).toBe(404);
    expect(new ProcessNotFoundError('m').statusCode).toBe(404);
    expect(new NoActiveVersionError('m').statusCode).toBe(404);
    expect(new UnauthorizedError('m').statusCode).toBe(401);
    expect(new ForbiddenError('a', 'b', 'process', 'm').statusCode).toBe(403);
    expect(new ValidationError('m', []).statusCode).toBe(422);
    expect(new DeployValidationFailedError('m').statusCode).toBe(422);
    expect(new LinterGateFailedError('m').statusCode).toBe(422);
    expect(new ContractViolationError('m', []).statusCode).toBe(422);
    expect(new ParseError('m', []).statusCode).toBe(400);
    expect(new VersionExistsError('m', []).statusCode).toBe(409);
    expect(new ActiveInstancesExistError('m').statusCode).toBe(409);
    expect(new InternalEngineError('m').statusCode).toBe(500);
    expect(new GraphqlDepthLimitError('m').statusCode).toBe(200);
    expect(new GraphqlComplexityLimitError('m').statusCode).toBe(200);
    expect(new GraphqlIntrospectionDisabledError('m').statusCode).toBe(200);
  });

  it('does not make ProcessNotFoundError a subclass of NotFoundError (narrow with statusCode or separate checks)', () => {
    const processNotFoundError = new ProcessNotFoundError('missing');
    expect(processNotFoundError).not.toBeInstanceOf(NotFoundError);
    expect(processNotFoundError).toBeInstanceOf(DaemonEngineError);
  });

  it('formats throws via mapDaemonEngineError', () => {
    const text = mapDaemonEngineError(new UnauthorizedError('nope'));
    expect(text).toContain('401');
    expect(text).toContain('unauthorized');
  });
});
