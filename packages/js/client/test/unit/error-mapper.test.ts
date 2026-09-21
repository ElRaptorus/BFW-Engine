import { describe, it, expect } from 'vitest';
import { mapResponseError } from '../../src/errors/error-mapper.js';
import {
  BkmNotFoundError,
  DecisionServiceNotFoundError,
  DecisionServiceValidationError,
  BfwEngineError,
  PayloadTooLargeError,
  RateLimitedError,
  EngineAtCapacityError,
  ProcessNotFoundError,
  NoActiveVersionError,
  ProcessDisabledError,
  ActiveInstancesExistError,
  AmbiguousStartEventError,
  StartEventNotFoundError,
  NoStartEventError,
  NoExecutableProcessError,
  ContractViolationError,
  ProcessInstanceAlreadyTerminalError,
  ProcessInstanceNotTerminalError,
  FniNotWaitingError,
  ParseError,
  DeployValidationFailedError,
  LinterGateFailedError,
  VersionExistsError,
  ProcessInstanceNotRetriableError,
  IncompatibleVersionMigrationError,
  GraphqlDepthLimitError,
  GraphqlComplexityLimitError,
  GraphqlIntrospectionDisabledError,
  InternalEngineError,
  UnauthorizedError,
  ForbiddenError,
  NotFoundError,
  ValidationError,
  DecisionDefinitionNotFoundError,
  DecisionDefinitionDisabledError,
  DmnCycleError,
  DmnEvaluationError,
  DecisionVersionNotFoundError,
  DmnParseError,
  DecisionVersionExistsError,
  AmbiguousDecisionError,
  InputValueViolationError,
  MissingServiceInputError,
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
} from '@elraptorus/bfw_engine_sdk';

describe('mapResponseError — domain error code mapping', () => {
  it('maps payload_too_large to PayloadTooLargeError', () => {
    const error = mapResponseError(413, {
      error: 'payload_too_large',
      field: 'token',
      size: 2_000_000,
      limit: 1_000_000,
    });
    expect(error).toBeInstanceOf(PayloadTooLargeError);
    const typed = error as PayloadTooLargeError;
    expect(typed.field).toBe('token');
    expect(typed.size).toBe(2_000_000);
    expect(typed.limit).toBe(1_000_000);
  });

  it('defaults PayloadTooLargeError field to "payload" when not in body', () => {
    const error = mapResponseError(413, { error: 'payload_too_large', size: 500, limit: 100 });
    expect(error).toBeInstanceOf(PayloadTooLargeError);
    expect((error as PayloadTooLargeError).field).toBe('payload');
  });

  it('maps rate_limited to RateLimitedError', () => {
    const error = mapResponseError(429, {
      error: 'rate_limited',
      message: 'Too many requests',
      retryAfterSeconds: 30,
    });
    expect(error).toBeInstanceOf(RateLimitedError);
    const typed = error as RateLimitedError;
    expect(typed.retryAfterSeconds).toBe(30);
    expect(typed.message).toBe('Too many requests');
  });

  it('maps engine_at_capacity to EngineAtCapacityError', () => {
    const error = mapResponseError(503, {
      error: 'engine_at_capacity',
      message: 'Engine busy',
      active: 100,
      limit: 100,
      retryAfterSeconds: 5,
    });
    expect(error).toBeInstanceOf(EngineAtCapacityError);
    const typed = error as EngineAtCapacityError;
    expect(typed.active).toBe(100);
    expect(typed.limit).toBe(100);
    expect(typed.retryAfterSeconds).toBe(5);
  });

  it('maps service_unavailable to ServiceUnavailableError, not EngineAtCapacityError', () => {
    const error = mapResponseError(503, {
      error: 'service_unavailable',
      message: 'Engine is resuming — message subscriptions not ready yet',
    });
    expect(error).toBeInstanceOf(ServiceUnavailableError);
    expect(error).not.toBeInstanceOf(EngineAtCapacityError);
    expect(error.errorCode).toBe('service_unavailable');
    expect(error.message).toBe('Engine is resuming — message subscriptions not ready yet');
  });

  it('maps not_found and metrics_disabled to NotFoundError', () => {
    expect(mapResponseError(404, { error: 'not_found', message: 'Not found' })).toBeInstanceOf(
      NotFoundError,
    );
    expect(
      mapResponseError(404, { error: 'metrics_disabled', message: 'Metrics endpoint is not enabled' }),
    ).toBeInstanceOf(NotFoundError);
  });

  it('maps forbidden to ForbiddenError', () => {
    const error = mapResponseError(403, {
      error: 'forbidden',
      message: 'Insufficient permissions',
      requiredClaim: 'trigger_message',
      requiredValue: 'all',
      resource: 'message',
    });
    expect(error).toBeInstanceOf(ForbiddenError);
    const typed = error as ForbiddenError;
    expect(typed.requiredClaim).toBe('trigger_message');
    expect(typed.requiredValue).toBe('all');
    expect(typed.resource).toBe('message');
  });

  it('maps process_not_found to ProcessNotFoundError', () => {
    const error = mapResponseError(404, {
      error: 'process_not_found',
      message: 'Process "foo" not found',
    });
    expect(error).toBeInstanceOf(ProcessNotFoundError);
    expect(error.message).toBe('Process "foo" not found');
  });

  it('maps no_active_version to NoActiveVersionError', () => {
    const error = mapResponseError(404, {
      error: 'no_active_version',
      message: 'No active version',
    });
    expect(error).toBeInstanceOf(NoActiveVersionError);
  });

  it('maps process_disabled to ProcessDisabledError', () => {
    const error = mapResponseError(422, {
      error: 'process_disabled',
      message: 'Process is disabled',
    });
    expect(error).toBeInstanceOf(ProcessDisabledError);
  });

  it('maps active_instances_exist to ActiveInstancesExistError', () => {
    const error = mapResponseError(409, {
      error: 'active_instances_exist',
      message: 'Active instances exist',
    });
    expect(error).toBeInstanceOf(ActiveInstancesExistError);
  });

  it('maps ambiguous_start_event to AmbiguousStartEventError', () => {
    const error = mapResponseError(422, {
      error: 'ambiguous_start_event',
      message: 'Multiple start events found',
    });
    expect(error).toBeInstanceOf(AmbiguousStartEventError);
  });

  it('maps start_event_not_found to StartEventNotFoundError', () => {
    const error = mapResponseError(422, {
      error: 'start_event_not_found',
      message: 'Start event not found',
    });
    expect(error).toBeInstanceOf(StartEventNotFoundError);
  });

  it('maps no_start_event to NoStartEventError', () => {
    const error = mapResponseError(422, {
      error: 'no_start_event',
      message: 'No start event',
    });
    expect(error).toBeInstanceOf(NoStartEventError);
  });

  it('maps no_executable_process to NoExecutableProcessError', () => {
    const error = mapResponseError(422, {
      error: 'no_executable_process',
      message: 'No executable process',
    });
    expect(error).toBeInstanceOf(NoExecutableProcessError);
  });

  it('maps contract_violation to ContractViolationError with violations', () => {
    const violations = [{ message: 'Missing field', path: ['token', 'orderId'] }];
    const error = mapResponseError(422, {
      error: 'contract_violation',
      message: 'Contract violation',
      violations,
    });
    expect(error).toBeInstanceOf(ContractViolationError);
    const typed = error as ContractViolationError;
    expect(typed.violations).toEqual(violations);
  });

  it('maps process_already_terminal to ProcessInstanceAlreadyTerminalError', () => {
    const error = mapResponseError(422, {
      error: 'process_already_terminal',
      message: 'Already finished',
      currentState: 'finished',
    });
    expect(error).toBeInstanceOf(ProcessInstanceAlreadyTerminalError);
    const typed = error as ProcessInstanceAlreadyTerminalError;
    expect(typed.currentState).toBe('finished');
  });

  it('maps process_instance_not_terminal to ProcessInstanceNotTerminalError', () => {
    const error = mapResponseError(422, {
      error: 'process_instance_not_terminal',
      message: 'Not terminal',
      currentState: 'running',
    });
    expect(error).toBeInstanceOf(ProcessInstanceNotTerminalError);
    const typed = error as ProcessInstanceNotTerminalError;
    expect(typed.currentState).toBe('running');
  });

  it('maps fni_not_waiting to FniNotWaitingError', () => {
    const error = mapResponseError(422, {
      error: 'fni_not_waiting',
      message: 'FNI not waiting',
      currentState: 'running',
    });
    expect(error).toBeInstanceOf(FniNotWaitingError);
    const typed = error as FniNotWaitingError;
    expect(typed.currentState).toBe('running');
  });

  it('maps parse_error to ParseError with failures', () => {
    const failures = [{ file: 'test.bpmn', details: ['Invalid XML'] }];
    const error = mapResponseError(400, {
      error: 'parse_error',
      message: 'Parse failed',
      failures,
    });
    expect(error).toBeInstanceOf(ParseError);
    const typed = error as ParseError;
    expect(typed.failures).toEqual(failures);
  });

  it('maps validation_failed to DeployValidationFailedError', () => {
    const error = mapResponseError(422, {
      error: 'validation_failed',
      message: 'Validation failed',
    });
    expect(error).toBeInstanceOf(DeployValidationFailedError);
  });

  it('maps linter_gate_failed to LinterGateFailedError', () => {
    const error = mapResponseError(422, {
      error: 'linter_gate_failed',
      message: 'Linter gate failed',
    });
    expect(error).toBeInstanceOf(LinterGateFailedError);
  });

  it('maps version_exists to VersionExistsError with conflicts', () => {
    const conflicts = [{ processModelId: 'order-process', version: '1.0.0' }];
    const error = mapResponseError(409, {
      error: 'version_exists',
      message: 'Version already exists',
      conflicts,
    });
    expect(error).toBeInstanceOf(VersionExistsError);
    const typed = error as VersionExistsError;
    expect(typed.conflicts).toEqual(conflicts);
  });

  it('maps process_instance_not_retriable to ProcessInstanceNotRetriableError', () => {
    const error = mapResponseError(422, {
      error: 'process_instance_not_retriable',
      message: 'Not retriable',
    });
    expect(error).toBeInstanceOf(ProcessInstanceNotRetriableError);
  });

  it('maps version_migration_incompatible to IncompatibleVersionMigrationError', () => {
    const error = mapResponseError(422, {
      error: 'version_migration_incompatible',
      message: 'Incompatible version',
    });
    expect(error).toBeInstanceOf(IncompatibleVersionMigrationError);
    expect(error.errorCode).toBe('version_migration_incompatible');
  });

  it('maps the legacy incompatible_version_migration alias to IncompatibleVersionMigrationError', () => {
    const error = mapResponseError(422, {
      error: 'incompatible_version_migration',
      message: 'Incompatible version',
    });
    expect(error).toBeInstanceOf(IncompatibleVersionMigrationError);
  });

  it('maps retry_checkpoint_is_non_retryable to RetryCheckpointIsNonRetryableError', () => {
    const error = mapResponseError(422, {
      error: 'retry_checkpoint_is_non_retryable',
      message: 'Cannot retry at this flow node',
    });
    expect(error).toBeInstanceOf(RetryCheckpointIsNonRetryableError);
  });

  it('maps version_disabled to ProcessDisabledError', () => {
    const error = mapResponseError(422, {
      error: 'version_disabled',
      message: 'Target process is disabled',
    });
    expect(error).toBeInstanceOf(ProcessDisabledError);
  });

  it('maps decision_not_found to DecisionDefinitionNotFoundError', () => {
    const error = mapResponseError(404, {
      error: 'decision_not_found',
      message: "Decision model 'x' not found in DMN definitions",
    });
    expect(error).toBeInstanceOf(DecisionDefinitionNotFoundError);
  });

  it('maps target_version_not_cached, not_applicable, enable_failed, and disable_failed to ValidationError', () => {
    for (const errorCode of ['target_version_not_cached', 'not_applicable', 'enable_failed', 'disable_failed']) {
      const error = mapResponseError(422, { error: errorCode, message: errorCode });
      expect(error).toBeInstanceOf(ValidationError);
      expect(error.rawBody?.['error']).toBe(errorCode);
    }
  });

  it('maps graphql_depth_limit to GraphqlDepthLimitError', () => {
    const error = mapResponseError(200, {
      error: 'graphql_depth_limit',
      message: 'Query too deep',
    });
    expect(error).toBeInstanceOf(GraphqlDepthLimitError);
  });

  it('maps graphql_complexity_limit to GraphqlComplexityLimitError', () => {
    const error = mapResponseError(200, {
      error: 'graphql_complexity_limit',
      message: 'Query too complex',
    });
    expect(error).toBeInstanceOf(GraphqlComplexityLimitError);
  });

  it('maps graphql_introspection_disabled to GraphqlIntrospectionDisabledError', () => {
    const error = mapResponseError(200, {
      error: 'graphql_introspection_disabled',
      message: 'Introspection disabled',
    });
    expect(error).toBeInstanceOf(GraphqlIntrospectionDisabledError);
  });

  it('maps internal_error to InternalEngineError', () => {
    const error = mapResponseError(500, {
      error: 'internal_error',
      message: 'Something went wrong',
    });
    expect(error).toBeInstanceOf(InternalEngineError);
  });

  it('maps decision_definition_not_found to DecisionDefinitionNotFoundError', () => {
    const body = { error: 'decision_definition_not_found', message: 'Decision "missing" not found' };
    const error = mapResponseError(404, body);
    expect(error).toBeInstanceOf(DecisionDefinitionNotFoundError);
    expect(error.statusCode).toBe(404);
    expect(error.errorCode).toBe('decision_definition_not_found');
    expect(error.message).toBe('Decision "missing" not found');
    expect(error.rawBody).toEqual(body);
  });

  it('maps decision_definition_disabled to DecisionDefinitionDisabledError', () => {
    const body = { error: 'decision_definition_disabled', message: 'Decision is disabled' };
    const error = mapResponseError(422, body);
    expect(error).toBeInstanceOf(DecisionDefinitionDisabledError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('decision_definition_disabled');
    expect(error.message).toBe('Decision is disabled');
    expect(error.rawBody).toEqual(body);
  });

  it('maps dmn_evaluation_error to DmnEvaluationError with decisionModelId and details', () => {
    const body = {
      error: 'dmn_evaluation_error',
      message: 'Evaluation failed',
      decisionModelId: 'Decision_approve',
      details: 'Hit policy violation',
    };
    const error = mapResponseError(422, body);
    expect(error).toBeInstanceOf(DmnEvaluationError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('dmn_evaluation_error');
    expect(error.message).toBe('Evaluation failed');
    const typed = error as DmnEvaluationError;
    expect(typed.decisionModelId).toBe('Decision_approve');
    expect(typed.details).toBe('Hit policy violation');
    expect(typed.rawBody).toEqual(body);
  });

  it('maps dmn_evaluation_error with null decisionModelId and details', () => {
    const error = mapResponseError(422, {
      error: 'dmn_evaluation_error',
      message: 'Generic failure',
    });
    expect(error).toBeInstanceOf(DmnEvaluationError);
    const typed = error as DmnEvaluationError;
    expect(typed.decisionModelId).toBeNull();
    expect(typed.details).toBeNull();
  });

  it('maps decision_version_not_found to DecisionVersionNotFoundError', () => {
    const body = { error: 'decision_version_not_found', message: 'Version not found' };
    const error = mapResponseError(404, body);
    expect(error).toBeInstanceOf(DecisionVersionNotFoundError);
    expect(error.statusCode).toBe(404);
    expect(error.errorCode).toBe('decision_version_not_found');
    expect(error.message).toBe('Version not found');
    expect(error.rawBody).toEqual(body);
  });

  it('maps dmn_parse_error to DmnParseError with failures', () => {
    const failures = [{ file: 'rules.dmn', details: ['Invalid DMN XML'] }];
    const body = { error: 'dmn_parse_error', message: 'DMN parse failed', failures };
    const error = mapResponseError(400, body);
    expect(error).toBeInstanceOf(DmnParseError);
    expect(error.statusCode).toBe(400);
    expect(error.errorCode).toBe('dmn_parse_error');
    expect(error.message).toBe('DMN parse failed');
    const typed = error as DmnParseError;
    expect(typed.failures).toEqual(failures);
    expect(typed.rawBody).toEqual(body);
  });

  it('maps dmn_parse_error with empty failures when body has no failures array', () => {
    const error = mapResponseError(400, { error: 'dmn_parse_error', message: 'Parse failed' });
    expect(error).toBeInstanceOf(DmnParseError);
    const typed = error as DmnParseError;
    expect(typed.failures).toEqual([]);
  });

  it('maps decision_version_exists to DecisionVersionExistsError with conflicts', () => {
    const conflicts = [{ decisionDefinitionId: 'discount-rules', version: '1.0.0' }];
    const body = { error: 'decision_version_exists', message: 'Version already exists', conflicts };
    const error = mapResponseError(409, body);
    expect(error).toBeInstanceOf(DecisionVersionExistsError);
    expect(error.statusCode).toBe(409);
    expect(error.errorCode).toBe('decision_version_exists');
    expect(error.message).toBe('Version already exists');
    const typed = error as DecisionVersionExistsError;
    expect(typed.conflicts).toEqual(conflicts);
    expect(typed.rawBody).toEqual(body);
  });

  it('maps decision_version_exists with empty conflicts when body has no conflicts array', () => {
    const error = mapResponseError(409, { error: 'decision_version_exists', message: 'Exists' });
    expect(error).toBeInstanceOf(DecisionVersionExistsError);
    const typed = error as DecisionVersionExistsError;
    expect(typed.conflicts).toEqual([]);
  });

  it('maps dmn_cycle_error to DmnCycleError with decisionIds', () => {
    const decisionIds = ['Decision_A', 'Decision_B'];
    const body = {
      error: 'dmn_cycle_error',
      message: 'Cycle detected in decision dependency graph',
      decisionIds,
    };
    const error = mapResponseError(422, body);
    expect(error).toBeInstanceOf(DmnCycleError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('dmn_cycle_error');
    expect(error.message).toBe('Cycle detected in decision dependency graph');
    const typed = error as DmnCycleError;
    expect(typed.decisionIds).toEqual(decisionIds);
    expect(typed.rawBody).toEqual(body);
  });

  it('maps dmn_cycle_error with empty decisionIds when body has no array', () => {
    const error = mapResponseError(422, { error: 'dmn_cycle_error', message: 'Cycle detected' });
    expect(error).toBeInstanceOf(DmnCycleError);
    const typed = error as DmnCycleError;
    expect(typed.decisionIds).toEqual([]);
  });

  it('maps bkm_not_found to BkmNotFoundError', () => {
    const body = {
      error: 'bkm_not_found',
      message: "Business Knowledge Model 'BKM_nonexistent' not found",
    };
    const error = mapResponseError(404, body);
    expect(error).toBeInstanceOf(BkmNotFoundError);
    expect(error.statusCode).toBe(404);
    expect(error.errorCode).toBe('bkm_not_found');
    expect(error.message).toBe("Business Knowledge Model 'BKM_nonexistent' not found");
    expect(error.rawBody).toEqual(body);
  });

  it('maps service_not_found to DecisionServiceNotFoundError', () => {
    const body = {
      error: 'service_not_found',
      message: "Decision Service 'DS_nonexistent' not found",
    };
    const error = mapResponseError(404, body);
    expect(error).toBeInstanceOf(DecisionServiceNotFoundError);
    expect(error.statusCode).toBe(404);
    expect(error.errorCode).toBe('service_not_found');
    expect(error.message).toBe("Decision Service 'DS_nonexistent' not found");
    expect(error.rawBody).toEqual(body);
  });

  it('maps decision_service_validation_error to DecisionServiceValidationError', () => {
    const body = {
      error: 'decision_service_validation_error',
      message: 'Decision Service has no output decisions',
    };
    const error = mapResponseError(422, body);
    expect(error).toBeInstanceOf(DecisionServiceValidationError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('decision_service_validation_error');
    expect(error.message).toBe('Decision Service has no output decisions');
    expect(error.rawBody).toEqual(body);
  });
  it('maps ambiguous_decision to AmbiguousDecisionError', () => {
    const body = {
      error: 'ambiguous_decision',
      message: 'Multiple decisions found — specify a decision_id',
    };
    const error = mapResponseError(422, body);
    expect(error).toBeInstanceOf(AmbiguousDecisionError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('ambiguous_decision');
    expect(error.message).toBe('Multiple decisions found — specify a decision_id');
    expect(error.rawBody).toEqual(body);
  });

  it('maps input_value_violation to InputValueViolationError with inputId', () => {
    const body = {
      error: 'input_value_violation',
      message: "Input 'grade' value does not satisfy inputValues constraint",
      inputId: 'Input_grade',
    };
    const error = mapResponseError(422, body);
    expect(error).toBeInstanceOf(InputValueViolationError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('input_value_violation');
    expect(error.message).toBe("Input 'grade' value does not satisfy inputValues constraint");
    const typed = error as InputValueViolationError;
    expect(typed.inputId).toBe('Input_grade');
    expect(typed.rawBody).toEqual(body);
  });

  it('maps input_value_violation with null inputId when body has no inputId', () => {
    const error = mapResponseError(422, { error: 'input_value_violation', message: 'Constraint violated' });
    expect(error).toBeInstanceOf(InputValueViolationError);
    const typed = error as InputValueViolationError;
    expect(typed.inputId).toBeNull();
  });

  it('maps missing_service_input to MissingServiceInputError with missingInputs', () => {
    const body = {
      error: 'missing_service_input',
      message: 'Required inputData not provided for Decision Service',
      missingInputs: ['Income', 'Age'],
    };
    const error = mapResponseError(422, body);
    expect(error).toBeInstanceOf(MissingServiceInputError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('missing_service_input');
    expect(error.message).toBe('Required inputData not provided for Decision Service');
    const typed = error as MissingServiceInputError;
    expect(typed.missingInputs).toEqual(['Income', 'Age']);
    expect(typed.rawBody).toEqual(body);
  });

  it('maps missing_service_input with empty array when body has no missingInputs', () => {
    const error = mapResponseError(422, { error: 'missing_service_input', message: 'Missing' });
    expect(error).toBeInstanceOf(MissingServiceInputError);
    const typed = error as MissingServiceInputError;
    expect(typed.missingInputs).toEqual([]);
  });

  it('maps retry_checkpoint_inside_adhoc_subprocess to RetryCheckpointInsideAdhocSubprocessError', () => {
    const error = mapResponseError(422, {
      error: 'retry_checkpoint_inside_adhoc_subprocess',
      message: 'Cannot set a retry checkpoint to an FNI inside an ad-hoc subprocess scope',
    });
    expect(error).toBeInstanceOf(RetryCheckpointInsideAdhocSubprocessError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('retry_checkpoint_inside_adhoc_subprocess');
  });

  it('maps retry_inside_adhoc_subprocess to RetryInsideAdhocSubprocessError', () => {
    const error = mapResponseError(422, {
      error: 'retry_inside_adhoc_subprocess',
      message: 'Cannot retry a PI that is a child of an ad-hoc subprocess scope',
    });
    expect(error).toBeInstanceOf(RetryInsideAdhocSubprocessError);
    expect(error).not.toBeInstanceOf(ValidationError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('retry_inside_adhoc_subprocess');
  });

  it('maps not_a_timer_event to NotATimerEventError', () => {
    const error = mapResponseError(422, {
      error: 'not_a_timer_event',
      message: 'Flow node instance is not a timer event',
    });
    expect(error).toBeInstanceOf(NotATimerEventError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('not_a_timer_event');
  });

  it('maps dispatch_failed to DispatchFailedError', () => {
    const error = mapResponseError(500, {
      error: 'dispatch_failed',
      message: 'Inner activity dispatch failed',
    });
    expect(error).toBeInstanceOf(DispatchFailedError);
    expect(error.statusCode).toBe(500);
    expect(error.errorCode).toBe('dispatch_failed');
  });

  it('maps conflict to ConflictError', () => {
    const error = mapResponseError(409, {
      error: 'conflict',
      message: 'Timer is not currently triggerable',
    });
    expect(error).toBeInstanceOf(ConflictError);
    expect(error.statusCode).toBe(409);
    expect(error.errorCode).toBe('conflict');
  });

  it('maps bad_request to BadRequestError', () => {
    const error = mapResponseError(400, {
      error: 'bad_request',
      message: 'Malformed request body',
    });
    expect(error).toBeInstanceOf(BadRequestError);
    expect(error.statusCode).toBe(400);
    expect(error.errorCode).toBe('bad_request');
  });

  it('maps no_matching_condition to NoMatchingConditionError', () => {
    const error = mapResponseError(422, {
      error: 'no_matching_condition',
      message: 'No outgoing sequence flow matched',
    });
    expect(error).toBeInstanceOf(NoMatchingConditionError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('no_matching_condition');
  });

  it('maps no_decisions to NoDecisionsError', () => {
    const error = mapResponseError(422, {
      error: 'no_decisions',
      message: 'DMN definitions contain no decision elements',
    });
    expect(error).toBeInstanceOf(NoDecisionsError);
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('no_decisions');
  });
});

describe('mapResponseError — HTTP status fallback', () => {
  it('falls back to UnauthorizedError for 401 with unknown error code', () => {
    const error = mapResponseError(401, { error: 'unknown', message: 'Bad token' });
    expect(error).toBeInstanceOf(UnauthorizedError);
  });

  it('falls back to ForbiddenError for 403 with unknown error code', () => {
    const error = mapResponseError(403, {
      error: 'unknown',
      message: 'Forbidden',
      requiredClaim: 'role',
      requiredValue: 'admin',
      resource: 'process',
    });
    expect(error).toBeInstanceOf(ForbiddenError);
    const typed = error as ForbiddenError;
    expect(typed.requiredClaim).toBe('role');
    expect(typed.requiredValue).toBe('admin');
    expect(typed.resource).toBe('process');
  });

  it('maps 403 with resource "decision" to ForbiddenError with decision resource', () => {
    const error = mapResponseError(403, {
      error: 'unknown',
      message: 'Forbidden',
      requiredClaim: 'deploy_dmn',
      requiredValue: 'true',
      resource: 'decision',
    });
    expect(error).toBeInstanceOf(ForbiddenError);
    const typed = error as ForbiddenError;
    expect(typed.resource).toBe('decision');
    expect(typed.requiredClaim).toBe('deploy_dmn');
  });

  it('maps 403 with resource "process_instance" to ForbiddenError with process_instance resource', () => {
    const error = mapResponseError(403, {
      error: 'unknown',
      message: 'Forbidden',
      requiredClaim: 'role',
      requiredValue: 'admin',
      resource: 'process_instance',
    });
    expect(error).toBeInstanceOf(ForbiddenError);
    const typed = error as ForbiddenError;
    expect(typed.resource).toBe('process_instance');
  });

  it('falls back to NotFoundError for 404 with unknown error code', () => {
    const error = mapResponseError(404, { error: 'unknown', message: 'Not found' });
    expect(error).toBeInstanceOf(NotFoundError);
  });

  it('falls back to ValidationError for 422 with unknown error code', () => {
    const error = mapResponseError(422, {
      error: 'unknown',
      message: 'Invalid input',
      failures: ['bad field'],
    });
    expect(error).toBeInstanceOf(ValidationError);
  });

  it('falls back to BadRequestError for 400 with unknown error code', () => {
    const error = mapResponseError(400, { error: 'unknown', message: 'Malformed JSON' });
    expect(error).toBeInstanceOf(BadRequestError);
  });

  it('falls back to ConflictError for 409 with unknown error code', () => {
    const error = mapResponseError(409, { error: 'unknown', message: 'State conflict' });
    expect(error).toBeInstanceOf(ConflictError);
  });

  it('falls back to InternalEngineError for 500 with unknown error code', () => {
    const error = mapResponseError(500, { error: 'unknown', message: 'Server error' });
    expect(error).toBeInstanceOf(InternalEngineError);
  });

  it('returns a base BfwEngineError for unrecognized status and code', () => {
    const error = mapResponseError(418, { error: 'teapot', message: 'I am a teapot' });
    expect(error).toBeInstanceOf(BfwEngineError);
    expect(error.statusCode).toBe(418);
    expect(error.errorCode).toBe('teapot');
    expect(error.message).toBe('I am a teapot');
  });

  it('preserves the raw body on every error', () => {
    const body = { error: 'process_not_found', message: 'Not found', extra: 'data' };
    const error = mapResponseError(404, body);
    expect(error.rawBody).toEqual(body);
  });

  it('uses error code as message when no message field is provided', () => {
    const error = mapResponseError(404, { error: 'process_not_found' });
    expect(error.message).toBe('process_not_found');
  });

  it('defaults error code to "unknown" when body has no error field', () => {
    const error = mapResponseError(418, {});
    expect(error.errorCode).toBe('unknown');
  });
});
