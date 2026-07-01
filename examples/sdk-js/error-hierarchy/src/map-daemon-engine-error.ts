import {
  ContractViolationError,
  DaemonEngineError,
  EngineAtCapacityError,
  ForbiddenError,
  FniNotWaitingError,
  ParseError,
  PayloadTooLargeError,
  ProcessInstanceAlreadyTerminalError,
  ProcessInstanceNotTerminalError,
  RateLimitedError,
  ValidationError,
  VersionExistsError,
} from '@elraptorus/daemonengine_sdk';

function describeDaemonEngineError(error: DaemonEngineError): string {
  const base = `statusCode=${error.statusCode} errorCode=${error.errorCode} message=${JSON.stringify(error.message)}`;
  const extras: string[] = [];
  if (error instanceof PayloadTooLargeError) {
    extras.push(`field=${error.field} size=${error.size} limit=${error.limit}`);
  }
  if (error instanceof RateLimitedError) {
    extras.push(`retryAfterSeconds=${error.retryAfterSeconds}`);
  }
  if (error instanceof EngineAtCapacityError) {
    extras.push(`active=${error.active} limit=${error.limit} retryAfterSeconds=${error.retryAfterSeconds}`);
  }
  if (error instanceof ForbiddenError) {
    extras.push(`requiredClaim=${error.requiredClaim} requiredValue=${error.requiredValue} resource=${error.resource}`);
  }
  if (error instanceof ValidationError) {
    extras.push(`failures=${JSON.stringify(error.failures)}`);
  }
  if (error instanceof ContractViolationError) {
    extras.push(`violations=${JSON.stringify(error.violations)}`);
  }
  if (error instanceof FniNotWaitingError) {
    extras.push(`currentState=${error.currentState}`);
  }
  if (error instanceof ProcessInstanceAlreadyTerminalError || error instanceof ProcessInstanceNotTerminalError) {
    extras.push(`currentState=${error.currentState}`);
  }
  if (error instanceof ParseError) {
    extras.push(`failures=${JSON.stringify(error.failures)}`);
  }
  if (error instanceof VersionExistsError) {
    extras.push(`conflicts=${JSON.stringify(error.conflicts)}`);
  }
  const extraLine = extras.length > 0 ? ` ${extras.join(' ')}` : '';
  return `${base}${extraLine}`;
}

export function mapDaemonEngineError(error: unknown): string {
  if (error instanceof DaemonEngineError) {
    return describeDaemonEngineError(error);
  }
  if (error instanceof Error) {
    return `non-engine Error: ${error.name} ${error.message}`;
  }
  return `non-Error throw: ${String(error)}`;
}
