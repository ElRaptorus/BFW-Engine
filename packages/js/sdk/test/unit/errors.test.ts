import { describe, expect, it } from 'vitest';

import {
  ActiveInstancesExistError,
  AmbiguousStartEventError,
  ContractViolationError,
  DaemonEngineError,
  DeployValidationFailedError,
  EngineAtCapacityError,
  FlowNodeInstanceState,
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
  ProcessInstanceState,
  ProcessNotFoundError,
  RateLimitedError,
  StartEventNotFoundError,
  UnauthorizedError,
  ValidationError,
  VersionExistsError,
  RetryCheckpointInsideAdhocSubprocessError,
  RetryInsideAdhocSubprocessError,
  RetryCheckpointIsNonRetryableError,
  NotATimerEventError,
  DispatchFailedError,
  ConflictError,
  BadRequestError,
  NoMatchingConditionError,
  NoDecisionsError,
  ServiceUnavailableError,
} from '../../src/index.js';

describe('DaemonEngineError base class', () => {
  it('preserves statusCode, errorCode, message, and rawBody', () => {
    const rawBody = { error: 'test', extra: 42 };
    const error = new DaemonEngineError(418, 'test', 'teapot', rawBody);

    expect(error).toBeInstanceOf(Error);
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(418);
    expect(error.errorCode).toBe('test');
    expect(error.message).toBe('teapot');
    expect(error.rawBody).toBe(rawBody);
    expect(error.name).toBe('DaemonEngineError');
  });

  it('rawBody is optional', () => {
    const error = new DaemonEngineError(500, 'internal', 'boom');
    expect(error.rawBody).toBeUndefined();
  });
});

describe('PayloadTooLargeError', () => {
  it('is instanceof DaemonEngineError and Error', () => {
    const error = new PayloadTooLargeError('payload', 2048, 1024);
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error).toBeInstanceOf(Error);
  });

  it('preserves field, size, and limit', () => {
    const error = new PayloadTooLargeError('result', 5000, 4096, { error: 'payload_too_large' });
    expect(error.field).toBe('result');
    expect(error.size).toBe(5000);
    expect(error.limit).toBe(4096);
    expect(error.statusCode).toBe(413);
    expect(error.errorCode).toBe('payload_too_large');
    expect(error.name).toBe('PayloadTooLargeError');
    expect(error.message).toContain('result');
  });
});

describe('RateLimitedError', () => {
  it('preserves retryAfterSeconds', () => {
    const error = new RateLimitedError(30, 'slow down');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.retryAfterSeconds).toBe(30);
    expect(error.statusCode).toBe(429);
    expect(error.name).toBe('RateLimitedError');
  });
});

describe('EngineAtCapacityError', () => {
  it('preserves active, limit, and retryAfterSeconds', () => {
    const error = new EngineAtCapacityError(1000, 1000, 60, 'at capacity');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.active).toBe(1000);
    expect(error.limit).toBe(1000);
    expect(error.retryAfterSeconds).toBe(60);
    expect(error.statusCode).toBe(503);
    expect(error.name).toBe('EngineAtCapacityError');
  });

  it('allows null limit', () => {
    const error = new EngineAtCapacityError(500, null, 30, 'overloaded');
    expect(error.limit).toBeNull();
  });
});

describe('NotFoundError', () => {
  it('has correct statusCode and errorCode', () => {
    const error = new NotFoundError('resource not found');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(404);
    expect(error.errorCode).toBe('not_found');
    expect(error.name).toBe('NotFoundError');
  });
});

describe('UnauthorizedError', () => {
  it('defaults message to "unauthorized" when omitted', () => {
    const error = new UnauthorizedError();
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.message).toBe('unauthorized');
    expect(error.statusCode).toBe(401);
    expect(error.name).toBe('UnauthorizedError');
  });

  it('uses provided message', () => {
    const error = new UnauthorizedError('missing header');
    expect(error.message).toBe('missing header');
  });
});

describe('ForbiddenError', () => {
  it('preserves claim, value, and resource', () => {
    const error = new ForbiddenError('deploy_bpmn', 'true', 'process', 'not allowed');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.requiredClaim).toBe('deploy_bpmn');
    expect(error.requiredValue).toBe('true');
    expect(error.resource).toBe('process');
    expect(error.statusCode).toBe(403);
    expect(error.name).toBe('ForbiddenError');
  });
});

describe('ValidationError', () => {
  it('preserves failures array', () => {
    const failures = [{ field: 'name', message: 'required' }];
    const error = new ValidationError('invalid', failures);
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.failures).toBe(failures);
    expect(error.statusCode).toBe(422);
    expect(error.name).toBe('ValidationError');
  });
});

describe('domain-specific errors', () => {
  it('ProcessNotFoundError', () => {
    const error = new ProcessNotFoundError('not found');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(404);
    expect(error.errorCode).toBe('process_not_found');
    expect(error.name).toBe('ProcessNotFoundError');
  });

  it('NoActiveVersionError', () => {
    const error = new NoActiveVersionError('no active version');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(404);
    expect(error.errorCode).toBe('no_active_version');
    expect(error.name).toBe('NoActiveVersionError');
  });

  it('ProcessDisabledError', () => {
    const error = new ProcessDisabledError('disabled');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('process_disabled');
    expect(error.name).toBe('ProcessDisabledError');
  });

  it('AmbiguousStartEventError', () => {
    const error = new AmbiguousStartEventError('ambiguous');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('ambiguous_start_event');
    expect(error.name).toBe('AmbiguousStartEventError');
  });

  it('StartEventNotFoundError', () => {
    const error = new StartEventNotFoundError('not found');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('start_event_not_found');
    expect(error.name).toBe('StartEventNotFoundError');
  });

  it('NoStartEventError', () => {
    const error = new NoStartEventError('no start event');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('no_start_event');
    expect(error.name).toBe('NoStartEventError');
  });

  it('NoExecutableProcessError', () => {
    const error = new NoExecutableProcessError('no executable');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('no_executable_process');
    expect(error.name).toBe('NoExecutableProcessError');
  });

  it('ContractViolationError preserves violations', () => {
    const violations = [{ message: 'required field', path: ['payload', 'orderId'] }];
    const error = new ContractViolationError('contract violated', violations);
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.violations).toBe(violations);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('contract_violation');
    expect(error.name).toBe('ContractViolationError');
  });

  it('ActiveInstancesExistError', () => {
    const error = new ActiveInstancesExistError('active instances');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(409);
    expect(error.errorCode).toBe('active_instances_exist');
    expect(error.name).toBe('ActiveInstancesExistError');
  });

  it('ProcessInstanceAlreadyTerminalError preserves currentState', () => {
    const error = new ProcessInstanceAlreadyTerminalError('already terminal', ProcessInstanceState.Finished);
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.currentState).toBe(ProcessInstanceState.Finished);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('process_already_terminal');
    expect(error.name).toBe('ProcessInstanceAlreadyTerminalError');
  });

  it('ProcessInstanceNotTerminalError preserves currentState', () => {
    const error = new ProcessInstanceNotTerminalError('not terminal', ProcessInstanceState.Running);
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.currentState).toBe(ProcessInstanceState.Running);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('process_instance_not_terminal');
    expect(error.name).toBe('ProcessInstanceNotTerminalError');
  });

  it('FniNotWaitingError preserves currentState', () => {
    const error = new FniNotWaitingError('not waiting', FlowNodeInstanceState.Active);
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.currentState).toBe(FlowNodeInstanceState.Active);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('fni_not_waiting');
    expect(error.name).toBe('FniNotWaitingError');
  });

  it('ParseError preserves failures', () => {
    const failures = [{ file: 'process.bpmn', details: ['missing id'] }];
    const error = new ParseError('parse failed', failures);
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.failures).toBe(failures);
    expect(error.statusCode).toBe(400);
    expect(error.errorCode).toBe('parse_error');
    expect(error.name).toBe('ParseError');
  });

  it('DeployValidationFailedError', () => {
    const error = new DeployValidationFailedError('validation failed');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('validation_failed');
    expect(error.name).toBe('DeployValidationFailedError');
  });

  it('LinterGateFailedError', () => {
    const error = new LinterGateFailedError('linter gate failed');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('linter_gate_failed');
    expect(error.name).toBe('LinterGateFailedError');
  });

  it('VersionExistsError preserves conflicts', () => {
    const conflicts = [{ processModelId: 'order-process', version: '1.0.0' }];
    const error = new VersionExistsError('version exists', conflicts);
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.conflicts).toBe(conflicts);
    expect(error.statusCode).toBe(409);
    expect(error.errorCode).toBe('version_exists');
    expect(error.name).toBe('VersionExistsError');
  });

  it('InternalEngineError', () => {
    const error = new InternalEngineError('internal error');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(500);
    expect(error.errorCode).toBe('internal_error');
    expect(error.name).toBe('InternalEngineError');
  });

  it('ProcessInstanceNotRetriableError', () => {
    const error = new ProcessInstanceNotRetriableError('not retriable');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('process_instance_not_retriable');
    expect(error.name).toBe('ProcessInstanceNotRetriableError');
  });

  it('IncompatibleVersionMigrationError', () => {
    const error = new IncompatibleVersionMigrationError('incompatible');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('version_migration_incompatible');
    expect(error.name).toBe('IncompatibleVersionMigrationError');
  });

  it('RetryCheckpointIsNonRetryableError', () => {
    const error = new RetryCheckpointIsNonRetryableError('not retryable');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('retry_checkpoint_is_non_retryable');
    expect(error.name).toBe('RetryCheckpointIsNonRetryableError');
  });
});

describe('GraphQL-specific errors', () => {
  it('GraphqlDepthLimitError', () => {
    const error = new GraphqlDepthLimitError('too deep');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(200);
    expect(error.errorCode).toBe('graphql_depth_limit');
    expect(error.name).toBe('GraphqlDepthLimitError');
  });

  it('GraphqlComplexityLimitError', () => {
    const error = new GraphqlComplexityLimitError('too complex');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(200);
    expect(error.errorCode).toBe('graphql_complexity_limit');
    expect(error.name).toBe('GraphqlComplexityLimitError');
  });

  it('GraphqlIntrospectionDisabledError', () => {
    const error = new GraphqlIntrospectionDisabledError('introspection disabled');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(200);
    expect(error.errorCode).toBe('graphql_introspection_disabled');
    expect(error.name).toBe('GraphqlIntrospectionDisabledError');
  });
});

describe('post-review remediation error classes', () => {
  it('RetryCheckpointInsideAdhocSubprocessError', () => {
    const error = new RetryCheckpointInsideAdhocSubprocessError('checkpoint inside ad-hoc');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('retry_checkpoint_inside_adhoc_subprocess');
    expect(error.name).toBe('RetryCheckpointInsideAdhocSubprocessError');
  });

  it('RetryInsideAdhocSubprocessError', () => {
    const error = new RetryInsideAdhocSubprocessError('retry inside ad-hoc');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('retry_inside_adhoc_subprocess');
    expect(error.name).toBe('RetryInsideAdhocSubprocessError');
  });

  it('NotATimerEventError', () => {
    const error = new NotATimerEventError('not a timer');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('not_a_timer_event');
    expect(error.name).toBe('NotATimerEventError');
  });

  it('DispatchFailedError', () => {
    const error = new DispatchFailedError('dispatch failed');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(500);
    expect(error.errorCode).toBe('dispatch_failed');
    expect(error.name).toBe('DispatchFailedError');
  });

  it('ConflictError', () => {
    const error = new ConflictError('conflict');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(409);
    expect(error.errorCode).toBe('conflict');
    expect(error.name).toBe('ConflictError');
  });

  it('BadRequestError', () => {
    const error = new BadRequestError('bad request');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(400);
    expect(error.errorCode).toBe('bad_request');
    expect(error.name).toBe('BadRequestError');
  });

  it('NoMatchingConditionError', () => {
    const error = new NoMatchingConditionError('no match');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('no_matching_condition');
    expect(error.name).toBe('NoMatchingConditionError');
  });

  it('NoDecisionsError', () => {
    const error = new NoDecisionsError('no decisions');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('no_decisions');
    expect(error.name).toBe('NoDecisionsError');
  });

  it('ServiceUnavailableError', () => {
    const error = new ServiceUnavailableError('Engine is resuming');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error.statusCode).toBe(503);
    expect(error.errorCode).toBe('service_unavailable');
    expect(error.name).toBe('ServiceUnavailableError');
  });
});

describe('inheritance chain', () => {
  it('all subclasses are instanceof DaemonEngineError', () => {
    const subclasses = [
      new PayloadTooLargeError('f', 1, 2),
      new RateLimitedError(5, 'msg'),
      new EngineAtCapacityError(1, 1, 5, 'msg'),
      new NotFoundError('msg'),
      new UnauthorizedError(),
      new ForbiddenError('c', 'v', 'process', 'msg'),
      new ValidationError('msg', []),
      new ProcessNotFoundError('msg'),
      new NoActiveVersionError('msg'),
      new ProcessDisabledError('msg'),
      new AmbiguousStartEventError('msg'),
      new StartEventNotFoundError('msg'),
      new NoStartEventError('msg'),
      new NoExecutableProcessError('msg'),
      new ContractViolationError('msg', []),
      new ActiveInstancesExistError('msg'),
      new ProcessInstanceAlreadyTerminalError('msg', ProcessInstanceState.Finished),
      new ProcessInstanceNotTerminalError('msg', ProcessInstanceState.Running),
      new FniNotWaitingError('msg', FlowNodeInstanceState.Active),
      new ParseError('msg', []),
      new DeployValidationFailedError('msg'),
      new LinterGateFailedError('msg'),
      new VersionExistsError('msg', []),
      new InternalEngineError('msg'),
      new ProcessInstanceNotRetriableError('msg'),
      new IncompatibleVersionMigrationError('msg'),
      new GraphqlDepthLimitError('msg'),
      new GraphqlComplexityLimitError('msg'),
      new GraphqlIntrospectionDisabledError('msg'),
      new ServiceUnavailableError('msg'),
    ];

    for (const error of subclasses) {
      expect(error).toBeInstanceOf(DaemonEngineError);
      expect(error).toBeInstanceOf(Error);
    }

    expect(subclasses).toHaveLength(30);
  });

  it('subclasses are NOT instanceof each other', () => {
    const notFound = new NotFoundError('a');
    const processNotFound = new ProcessNotFoundError('b');

    expect(notFound).not.toBeInstanceOf(ProcessNotFoundError);
    expect(processNotFound).not.toBeInstanceOf(NotFoundError);
  });
});

describe('try/catch narrowing', () => {
  it('can narrow with instanceof in catch blocks', () => {
    const error: DaemonEngineError = new ProcessNotFoundError('order-process not found');

    if (error instanceof ProcessNotFoundError) {
      expect(error.errorCode).toBe('process_not_found');
    } else {
      expect.unreachable('should have matched ProcessNotFoundError');
    }
  });
});
