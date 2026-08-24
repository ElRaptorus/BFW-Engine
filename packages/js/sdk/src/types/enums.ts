/**
 * All possible states of a process instance.
 */
export enum ProcessInstanceState {
  /** Actively executing flow nodes. */
  Running = 'running',
  /** All paths reached an end event normally. */
  Finished = 'finished',
  /** An unrecoverable error terminated the instance. */
  Fatal = 'fatal',
  /** Explicitly killed by a user through the API. */
  Aborted = 'aborted',
  /** Completed via compensation (Phase 5). */
  Compensated = 'compensated',
  /** Terminated by an unhandled escalation event (Phase 4). */
  Escalated = 'escalated',
  /** Terminated by an Error End Event (unhandled or standalone). */
  Error = 'error',
  /** Cancelled by a Cancel End Event within a Transaction subprocess (Phase 5.4). */
  Cancelled = 'cancelled',
}

/**
 * All possible states of a flow node instance.
 */
export enum FlowNodeInstanceState {
  /** Currently executing (handler running or task dispatched). */
  Active = 'active',
  /** Suspended, waiting for an external signal (user task claim, message arrival, timer, etc.). */
  Waiting = 'waiting',
  /** Completed successfully. */
  Finished = 'finished',
  /** An unrecoverable error occurred during execution. */
  Fatal = 'fatal',
  /** The owning process instance was killed by a user through the API; all its FNIs transition to aborted. */
  Aborted = 'aborted',
  /** A boundary event on the decorated activity fired and interrupted this FNI. */
  Interrupted = 'interrupted',
  /** The flow node threw a modeled BPMN error (Error End Event). */
  Error = 'error',
}

/**
 * All BPMN flow node element types recognized by the engine.
 */
export enum FlowNodeType {
  StartEvent = 'start_event',
  EndEvent = 'end_event',
  Task = 'task',
  UserTask = 'user_task',
  ServiceTask = 'service_task',
  ManualTask = 'manual_task',
  ScriptTask = 'script_task',
  BusinessRuleTask = 'business_rule_task',
  SendTask = 'send_task',
  ReceiveTask = 'receive_task',
  CallActivity = 'call_activity',
  SubProcess = 'sub_process',
  ExclusiveGateway = 'exclusive_gateway',
  ParallelGateway = 'parallel_gateway',
  InclusiveGateway = 'inclusive_gateway',
  EventBasedGateway = 'event_based_gateway',
  ComplexGateway = 'complex_gateway',
  IntermediateCatchEvent = 'intermediate_catch_event',
  IntermediateThrowEvent = 'intermediate_throw_event',
  BoundaryEvent = 'boundary_event',
}

/**
 * Event definition subtypes carried by event-shaped flow nodes and
 * message-oriented tasks (SendTask, ReceiveTask).
 *
 * Non-event flow nodes and plain (untyped) events have `eventType: null`.
 */
export enum EventDefinitionType {
  Message = 'message',
  Signal = 'signal',
  Timer = 'timer',
  Error = 'error',
  Escalation = 'escalation',
  Conditional = 'conditional',
  Compensation = 'compensation',
  Terminate = 'terminate',
  Cancel = 'cancel',
  Link = 'link',
}

/**
 * The type of capability a plugin registers with the engine.
 * Used in `PluginCapabilitySummary` for introspection / `/stats`.
 */
export enum PluginCapabilityType {
  ServiceTaskHandler = 'service_task_handler',
  EventSink = 'event_sink',
  RestApiExtension = 'rest_api_extension',
  NamedScript = 'named_script',
  AuthProvider = 'auth_provider',
}

/**
 * Standard DMN 1.3 hit policies that control how matching rules
 * are reduced to a final decision table result.
 *
 * Values are lowercase to match the engine's wire format.
 * `Literal` and `BoxedExpression` are synthetic policies assigned by
 * the engine when the decision uses a literal expression or CL3 boxed
 * expression instead of a decision table.
 */
export enum DmnHitPolicy {
  Unique = 'unique',
  First = 'first',
  Any = 'any',
  Collect = 'collect',
  RuleOrder = 'rule_order',
  OutputOrder = 'output_order',
  Priority = 'priority',
  Literal = 'literal',
  BoxedExpression = 'boxed_expression',
}
