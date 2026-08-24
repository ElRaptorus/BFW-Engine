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

import { mapDaemonEngineError } from './map-daemon-engine-error.js';

type ErrorSpecimen = {
  name: string;
  statusLine: string;
  instance: DaemonEngineError;
};

function describeDaemonEngineError(error: DaemonEngineError): string {
  return mapDaemonEngineError(error);
}

const inheritanceTreeLines = [
  'DaemonEngineError (base)',
  '├── PayloadTooLargeError (413)',
  '├── RateLimitedError (429)',
  '├── EngineAtCapacityError (503)',
  '├── NotFoundError (404)',
  '├── ProcessNotFoundError (404)',
  '├── NoActiveVersionError (404)',
  '├── UnauthorizedError (401)',
  '├── ForbiddenError (403)',
  '├── ValidationError (422)',
  '├── DeployValidationFailedError (422, validation_failed)',
  '├── LinterGateFailedError (422, linter_gate_failed)',
  '├── ContractViolationError (422, contract_violation)',
  '├── ProcessDisabledError (422, process_disabled)',
  '├── AmbiguousStartEventError (422, ambiguous_start_event)',
  '├── StartEventNotFoundError (422, start_event_not_found)',
  '├── NoStartEventError (422, no_start_event)',
  '├── NoExecutableProcessError (422, no_executable_process)',
  '├── FniNotWaitingError (422, errorCode may vary)',
  '├── ProcessInstanceAlreadyTerminalError (422, process_already_terminal)',
  '├── ProcessInstanceNotTerminalError (422, process_instance_not_terminal)',
  '├── ProcessInstanceNotRetriableError (422, process_instance_not_retriable)',
  '├── IncompatibleVersionMigrationError (422, version_migration_incompatible)',
  '├── ParseError (400)',
  '├── VersionExistsError (409, version_exists)',
  '├── ActiveInstancesExistError (409, active_instances_exist)',
  '├── InternalEngineError (500)',
  '├── GraphqlDepthLimitError (200, graphql_depth_limit)',
  '├── GraphqlComplexityLimitError (200, graphql_complexity_limit)',
  '└── GraphqlIntrospectionDisabledError (200, graphql_introspection_disabled)',
];

function buildSpecimens(): ErrorSpecimen[] {
  return [
    {
      name: 'PayloadTooLargeError',
      statusLine: '413 payload_too_large',
      instance: new PayloadTooLargeError('payload', 8192, 4096),
    },
    { name: 'RateLimitedError', statusLine: '429 rate_limited', instance: new RateLimitedError(12, 'try later') },
    {
      name: 'EngineAtCapacityError',
      statusLine: '503 engine_at_capacity',
      instance: new EngineAtCapacityError(900, 800, 45, 'limit reached'),
    },
    { name: 'NotFoundError', statusLine: '404 not_found', instance: new NotFoundError('missing') },
    {
      name: 'ProcessNotFoundError',
      statusLine: '404 process_not_found',
      instance: new ProcessNotFoundError('unknown process'),
    },
    {
      name: 'NoActiveVersionError',
      statusLine: '404 no_active_version',
      instance: new NoActiveVersionError('no enabled version'),
    },
    { name: 'UnauthorizedError', statusLine: '401 unauthorized', instance: new UnauthorizedError('invalid token') },
    {
      name: 'ForbiddenError',
      statusLine: '403 forbidden',
      instance: new ForbiddenError('role', 'admin', 'process', 'insufficient privilege'),
    },
    {
      name: 'ValidationError',
      statusLine: '422 validation_error',
      instance: new ValidationError('invalid body', [{ path: 'id', message: 'required' }]),
    },
    {
      name: 'DeployValidationFailedError',
      statusLine: '422 validation_failed',
      instance: new DeployValidationFailedError('BPMN invalid'),
    },
    {
      name: 'LinterGateFailedError',
      statusLine: '422 linter_gate_failed',
      instance: new LinterGateFailedError('linter rejected deploy'),
    },
    {
      name: 'ContractViolationError',
      statusLine: '422 contract_violation',
      instance: new ContractViolationError('schema mismatch', [{ message: 'bad', path: ['a'] }]),
    },
    {
      name: 'ProcessDisabledError',
      statusLine: '422 process_disabled',
      instance: new ProcessDisabledError('process disabled'),
    },
    {
      name: 'AmbiguousStartEventError',
      statusLine: '422 ambiguous_start_event',
      instance: new AmbiguousStartEventError('pick a start'),
    },
    {
      name: 'StartEventNotFoundError',
      statusLine: '422 start_event_not_found',
      instance: new StartEventNotFoundError('no such start'),
    },
    {
      name: 'NoStartEventError',
      statusLine: '422 no_start_event',
      instance: new NoStartEventError('process lacks start'),
    },
    {
      name: 'NoExecutableProcessError',
      statusLine: '422 no_executable_process',
      instance: new NoExecutableProcessError('nothing executable'),
    },
    {
      name: 'ActiveInstancesExistError',
      statusLine: '409 active_instances_exist',
      instance: new ActiveInstancesExistError('still running'),
    },
    {
      name: 'ProcessInstanceAlreadyTerminalError',
      statusLine: '422 process_already_terminal',
      instance: new ProcessInstanceAlreadyTerminalError('already done', ProcessInstanceState.Finished),
    },
    {
      name: 'ProcessInstanceNotTerminalError',
      statusLine: '422 process_instance_not_terminal',
      instance: new ProcessInstanceNotTerminalError('still running', ProcessInstanceState.Running),
    },
    {
      name: 'FniNotWaitingError',
      statusLine: '422 fni_not_waiting (default wire code)',
      instance: new FniNotWaitingError('wrong state', FlowNodeInstanceState.Active),
    },
    {
      name: 'ParseError',
      statusLine: '400 parse_error',
      instance: new ParseError('XML bad', [{ file: 'model.bpmn', details: ['unclosed tag'] }]),
    },
    {
      name: 'VersionExistsError',
      statusLine: '409 version_exists',
      instance: new VersionExistsError('dup', [{ processModelId: 'demo', version: '1.0.0' }]),
    },
    {
      name: 'InternalEngineError',
      statusLine: '500 internal_error',
      instance: new InternalEngineError('unexpected'),
    },
    {
      name: 'ProcessInstanceNotRetriableError',
      statusLine: '422 process_instance_not_retriable',
      instance: new ProcessInstanceNotRetriableError('cannot retry'),
    },
    {
      name: 'IncompatibleVersionMigrationError',
      statusLine: '422 version_migration_incompatible',
      instance: new IncompatibleVersionMigrationError('bad migration target'),
    },
    {
      name: 'GraphqlDepthLimitError',
      statusLine: '200 graphql_depth_limit',
      instance: new GraphqlDepthLimitError('depth exceeded'),
    },
    {
      name: 'GraphqlComplexityLimitError',
      statusLine: '200 graphql_complexity_limit',
      instance: new GraphqlComplexityLimitError('complexity exceeded'),
    },
    {
      name: 'GraphqlIntrospectionDisabledError',
      statusLine: '200 graphql_introspection_disabled',
      instance: new GraphqlIntrospectionDisabledError('introspection off'),
    },
  ];
}

export async function main(): Promise<void> {
  console.log('Reference tree (each class extends DaemonEngineError directly in the SDK):\n');
  console.log(inheritanceTreeLines.join('\n'));
  console.log('\nInstances\n');
  const specimens = buildSpecimens();
  for (const specimen of specimens) {
    console.log(`--- ${specimen.name} (${specimen.statusLine})`);
    console.log(describeDaemonEngineError(specimen.instance));
  }
  console.log('\ninstanceof illustration');
  const notFound = new NotFoundError('a');
  const processNotFound = new ProcessNotFoundError('b');
  console.log(`notFound instanceof DaemonEngineError → ${notFound instanceof DaemonEngineError}`);
  console.log(`processNotFound instanceof DaemonEngineError → ${processNotFound instanceof DaemonEngineError}`);
  console.log(`processNotFound instanceof NotFoundError → ${processNotFound instanceof NotFoundError}`);

  console.log('\nmapDaemonEngineError');
  try {
    throw new UnauthorizedError('missing bearer');
  } catch (caughtError: unknown) {
    console.log(mapDaemonEngineError(caughtError));
  }
}

main().catch(console.error);
