import {
  ActiveInstancesExistError,
  AmbiguousDecisionError,
  AmbiguousStartEventError,
  BadRequestError,
  BkmNotFoundError,
  ConflictError,
  ContractViolationError,
  type DaemonEngineError,
  DaemonEngineError as DaemonEngineErrorClass,
  DecisionDefinitionDisabledError,
  DecisionDefinitionNotFoundError,
  DecisionServiceNotFoundError,
  DecisionServiceValidationError,
  DecisionVersionExistsError,
  DecisionVersionNotFoundError,
  DeployValidationFailedError,
  DispatchFailedError,
  DmnCycleError,
  DmnEvaluationError,
  DmnParseError,
  EngineAtCapacityError,
  FniNotWaitingError,
  ForbiddenError,
  GraphqlComplexityLimitError,
  GraphqlDepthLimitError,
  GraphqlIntrospectionDisabledError,
  IncompatibleVersionMigrationError,
  InputValueViolationError,
  InternalEngineError,
  LinterGateFailedError,
  MissingServiceInputError,
  NoActiveVersionError,
  NoDecisionsError,
  ServiceUnavailableError,
  NoExecutableProcessError,
  NoMatchingConditionError,
  NoStartEventError,
  NotATimerEventError,
  NotFoundError,
  ParseError,
  PayloadTooLargeError,
  ProcessDisabledError,
  ProcessInstanceAlreadyTerminalError,
  ProcessInstanceNotRetriableError,
  ProcessInstanceNotTerminalError,
  ProcessNotFoundError,
  RateLimitedError,
  RetryCheckpointInsideAdhocSubprocessError,
  RetryCheckpointInsideTransactionError,
  RetryCheckpointIsEbgLoserError,
  RetryCheckpointIsJoinGatewayError,
  RetryCheckpointIsMiIterationError,
  RetryCheckpointIsNonRetryableError,
  RetryInsideAdhocSubprocessError,
  RetryInsideTransactionScopeError,
  StartEventNotFoundError,
  UnauthorizedError,
  ValidationError,
  VersionExistsError,
} from '@elraptorus/daemonengine_sdk';
import type { FlowNodeInstanceState, ProcessInstanceState } from '@elraptorus/daemonengine_sdk';

/**
 * Maps an engine error response to the most specific `DaemonEngineError` subclass.
 *
 * Strategy:
 * 1. Match `body.error` against known domain error codes (domain-specific errors).
 * 2. Fall back to HTTP status code (generic HTTP errors: 401, 403, 404, 422, 500).
 * 3. Catch-all: unrecognized errors get the base `DaemonEngineError` with raw body preserved.
 *
 * @param status - HTTP status code from the engine response.
 * @param body - Parsed JSON response body.
 * @returns A `DaemonEngineError` (or subclass) instance ready to be thrown.
 */
export function mapResponseError(status: number, body: Record<string, unknown>): DaemonEngineError {
  const errorCode = String(body['error'] ?? 'unknown');
  const message = String(body['message'] ?? errorCode);

  const domainError = mapByErrorCode(errorCode, message, body);
  if (domainError) {
    return domainError;
  }

  const statusError = mapByStatusCode(status, errorCode, message, body);
  if (statusError) {
    return statusError;
  }

  return new DaemonEngineErrorClass(status, errorCode, message, body);
}

function mapByErrorCode(errorCode: string, message: string, body: Record<string, unknown>): DaemonEngineError | null {
  switch (errorCode) {
    case 'payload_too_large':
      return new PayloadTooLargeError(
        String(body['field'] ?? 'payload'),
        Number(body['size'] ?? 0),
        Number(body['limit'] ?? 0),
        body,
      );
    case 'rate_limited':
      return new RateLimitedError(Number(body['retryAfterSeconds'] ?? 0), message, body);
    case 'engine_at_capacity':
      return new EngineAtCapacityError(
        Number(body['active'] ?? 0),
        body['limit'] != null ? Number(body['limit']) : null,
        Number(body['retryAfterSeconds'] ?? 0),
        message,
        body,
      );
    case 'service_unavailable':
      return new ServiceUnavailableError(message, body);
    case 'not_found':
    case 'metrics_disabled':
      return new NotFoundError(message, body);
    case 'forbidden': {
      let resourceKind: 'process' | 'process_instance' | 'decision' | 'message' | 'signal' = 'process';
      if (body['resource'] === 'process_instance') {
        resourceKind = 'process_instance';
      } else if (body['resource'] === 'decision') {
        resourceKind = 'decision';
      } else if (body['resource'] === 'message') {
        resourceKind = 'message';
      } else if (body['resource'] === 'signal') {
        resourceKind = 'signal';
      }
      return new ForbiddenError(
        String(body['requiredClaim'] ?? ''),
        String(body['requiredValue'] ?? ''),
        resourceKind,
        message,
        body,
      );
    }
    case 'process_not_found':
      return new ProcessNotFoundError(message, body);
    case 'no_active_version':
      return new NoActiveVersionError(message, body);
    case 'process_disabled':
      return new ProcessDisabledError(message, body);
    case 'active_instances_exist':
      return new ActiveInstancesExistError(message, body);
    case 'ambiguous_start_event':
      return new AmbiguousStartEventError(message, body);
    case 'start_event_not_found':
      return new StartEventNotFoundError(message, body);
    case 'no_start_event':
      return new NoStartEventError(message, body);
    case 'no_executable_process':
      return new NoExecutableProcessError(message, body);
    case 'contract_violation':
      return new ContractViolationError(
        message,
        Array.isArray(body['violations']) ? (body['violations'] as ContractViolationError['violations']) : [],
        body,
      );
    case 'process_already_terminal':
      return new ProcessInstanceAlreadyTerminalError(
        message,
        (body['currentState'] as ProcessInstanceState) ?? 'unknown',
        body,
      );
    case 'process_instance_not_terminal':
      return new ProcessInstanceNotTerminalError(
        message,
        (body['currentState'] as ProcessInstanceState) ?? 'unknown',
        body,
      );
    case 'fni_not_waiting':
    case 'fni_not_active':
    case 'fni_already_finished':
    case 'fni_already_aborted':
    case 'fni_already_interrupted':
    case 'fni_already_fatal':
      return new FniNotWaitingError(
        message,
        (body['currentState'] as FlowNodeInstanceState) ?? 'unknown',
        errorCode,
        body,
      );
    case 'parse_error':
      return new ParseError(
        message,
        Array.isArray(body['failures']) ? (body['failures'] as ParseError['failures']) : [],
        body,
      );
    case 'validation_failed':
      return new DeployValidationFailedError(message, body);
    case 'linter_gate_failed':
      return new LinterGateFailedError(message, body);
    case 'version_exists':
      return new VersionExistsError(
        message,
        Array.isArray(body['conflicts']) ? (body['conflicts'] as VersionExistsError['conflicts']) : [],
        body,
      );
    case 'process_instance_not_retriable':
      return new ProcessInstanceNotRetriableError(message, body);
    case 'version_migration_incompatible':
    case 'incompatible_version_migration':
      return new IncompatibleVersionMigrationError(message, body);
    case 'retry_checkpoint_is_join_gateway':
      return new RetryCheckpointIsJoinGatewayError(message, body);
    case 'retry_checkpoint_is_ebg_loser':
      return new RetryCheckpointIsEbgLoserError(message, body);
    case 'retry_checkpoint_is_mi_iteration':
      return new RetryCheckpointIsMiIterationError(message, body);
    case 'retry_checkpoint_is_non_retryable':
      return new RetryCheckpointIsNonRetryableError(message, body);
    case 'target_version_not_cached':
      return new ValidationError(message, [], body);
    case 'version_disabled':
      return new ProcessDisabledError(message, body);
    case 'not_applicable':
    case 'enable_failed':
    case 'disable_failed':
      return new ValidationError(message, [], body);
    case 'decision_not_found':
      return new DecisionDefinitionNotFoundError(message, body);
    case 'retry_checkpoint_inside_transaction':
      return new RetryCheckpointInsideTransactionError(message, body);
    case 'retry_inside_transaction_scope':
      return new RetryInsideTransactionScopeError(message, body);
    case 'retry_checkpoint_inside_adhoc_subprocess':
      return new RetryCheckpointInsideAdhocSubprocessError(message, body);
    case 'retry_inside_adhoc_subprocess':
      return new RetryInsideAdhocSubprocessError(message, body);
    case 'not_a_timer_event':
      return new NotATimerEventError(message, body);
    case 'dispatch_failed':
      return new DispatchFailedError(message, body);
    case 'conflict':
      return new ConflictError(message, body);
    case 'bad_request':
      return new BadRequestError(message, body);
    case 'no_matching_condition':
      return new NoMatchingConditionError(message, body);
    case 'no_decisions':
      return new NoDecisionsError(message, body);
    case 'root_process_instance_not_terminal':
      return new ProcessInstanceNotTerminalError(
        message,
        (body['currentState'] as ProcessInstanceState) ?? 'unknown',
        body,
      );
    case 'version_not_found':
    case 'flow_node_instance_not_found':
      return new NotFoundError(message, body);
    case 'batch_conflict':
      return new VersionExistsError(
        message,
        Array.isArray(body['conflicts']) ? (body['conflicts'] as VersionExistsError['conflicts']) : [],
        body,
      );
    case 'graphql_depth_limit':
      return new GraphqlDepthLimitError(message, body);
    case 'graphql_complexity_limit':
      return new GraphqlComplexityLimitError(message, body);
    case 'graphql_introspection_disabled':
      return new GraphqlIntrospectionDisabledError(message, body);
    case 'decision_definition_not_found':
      return new DecisionDefinitionNotFoundError(message, body);
    case 'decision_definition_disabled':
      return new DecisionDefinitionDisabledError(message, body);
    case 'dmn_evaluation_error':
      return new DmnEvaluationError(
        message,
        body['decisionModelId'] != null ? String(body['decisionModelId']) : null,
        body['details'] != null ? String(body['details']) : null,
        body,
      );
    case 'decision_version_not_found':
      return new DecisionVersionNotFoundError(message, body);
    case 'dmn_cycle_error':
      return new DmnCycleError(
        message,
        Array.isArray(body['decisionIds']) ? (body['decisionIds'] as string[]) : [],
        body,
      );
    case 'bkm_not_found':
      return new BkmNotFoundError(message, body);
    case 'service_not_found':
      return new DecisionServiceNotFoundError(message, body);
    case 'decision_service_validation_error':
      return new DecisionServiceValidationError(message, body);
    case 'ambiguous_decision':
      return new AmbiguousDecisionError(message, body);
    case 'input_value_violation':
      return new InputValueViolationError(message, body['inputId'] != null ? String(body['inputId']) : null, body);
    case 'missing_service_input':
      return new MissingServiceInputError(
        message,
        Array.isArray(body['missingInputs']) ? (body['missingInputs'] as string[]) : [],
        body,
      );
    case 'dmn_parse_error':
      return new DmnParseError(
        message,
        Array.isArray(body['failures']) ? (body['failures'] as DmnParseError['failures']) : [],
        body,
      );
    case 'decision_version_exists':
      return new DecisionVersionExistsError(
        message,
        Array.isArray(body['conflicts']) ? (body['conflicts'] as DecisionVersionExistsError['conflicts']) : [],
        body,
      );
    case 'not_adhoc_subprocess':
      return new ValidationError(message, [], body);
    case 'adhoc_activity_not_found':
      return new NotFoundError(message, body);
    case 'adhoc_already_completing':
      return new ValidationError(message, [], body);
    case 'adhoc_sequential_busy':
      return new ValidationError(message, [], body);
    case 'adhoc_not_active':
      return new ValidationError(message, [], body);
    case 'internal_error':
      return new InternalEngineError(message, body);
    default:
      return null;
  }
}

function mapByStatusCode(
  status: number,
  _errorCode: string,
  message: string,
  body: Record<string, unknown>,
): DaemonEngineError | null {
  switch (status) {
    case 401:
      return new UnauthorizedError(body['message'] != null ? String(body['message']) : undefined, body);
    case 403: {
      let resourceKind: 'process' | 'process_instance' | 'decision' | 'message' | 'signal' = 'process';
      if (body['resource'] === 'process_instance') {
        resourceKind = 'process_instance';
      } else if (body['resource'] === 'decision') {
        resourceKind = 'decision';
      } else if (body['resource'] === 'message') {
        resourceKind = 'message';
      } else if (body['resource'] === 'signal') {
        resourceKind = 'signal';
      }
      return new ForbiddenError(
        String(body['requiredClaim'] ?? ''),
        String(body['requiredValue'] ?? ''),
        resourceKind,
        message,
        body,
      );
    }
    case 404:
      return new NotFoundError(message, body);
    case 400:
      return new BadRequestError(message, body);
    case 409:
      return new ConflictError(message, body);
    case 422:
      return new ValidationError(message, Array.isArray(body['failures']) ? (body['failures'] as unknown[]) : [], body);
    case 500:
      return new InternalEngineError(message, body);
    case 503:
      return new EngineAtCapacityError(
        Number(body['active'] ?? 0),
        body['limit'] != null ? Number(body['limit']) : null,
        Number(body['retryAfterSeconds'] ?? 0),
        message,
        body,
      );
    default:
      return null;
  }
}
