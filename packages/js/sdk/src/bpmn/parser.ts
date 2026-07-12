/**
 * BPMN XML parser producing the same typed model as the engine's
 * `EvilEngine.BPMN.Parser.SaxHandler`. Uses `fast-xml-parser` with
 * `preserveOrder: true` to maintain document order, then walks the
 * ordered tree to build model objects.
 */
import { XMLParser } from 'fast-xml-parser';

import { FlowNodeType } from '../types/enums.js';
import type {
  BoundaryEventTypeData,
  BpmnDefinitions,
  BpmnProcess,
  DataAssociation,
  DataContract,
  DataObject,
  DataObjectReference,
  DataStore,
  DataStoreReference,
  ErrorEventDefinition,
  EscalationDefinition,
  EventDefinition,
  ExclusiveGatewayTypeData,
  FlowNode,
  FlowNodeTypeData,
  Lane,
  LinterRulesetScore,
  Mapping,
  MessageEventDefinition,
  MultiInstance,
  SequenceFlow,
  ServiceTaskTypeData,
  SignalDefinition,
} from './model.js';

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Parse BPMN 2.0 XML into a fully typed model matching the engine's
 * internal parser output. Synchronous, pure, throws on malformed XML.
 */
export function parseBpmn(xml: string): BpmnDefinitions {
  const parser = new XMLParser({
    ignoreAttributes: false,
    removeNSPrefix: true,
    attributeNamePrefix: '@_',
    textNodeName: '#text',
    parseAttributeValue: false,
    trimValues: false,
    preserveOrder: true,
  });

  const parsed: OrderedNode[] = parser.parse(xml) as OrderedNode[];
  const definitionsNode = findElement(parsed, 'definitions');
  if (!definitionsNode) {
    return emptyDefinitions(xml);
  }

  return parseDefinitions(definitionsNode, xml);
}

// ---------------------------------------------------------------------------
// Ordered-mode types
//
// With preserveOrder: true, fast-xml-parser emits arrays of objects.
// Each object has a single tag-name key whose value is its children
// (also an ordered array), plus an optional `:@` key for attributes.
// Text nodes appear as { "#text": "..." }.
// ---------------------------------------------------------------------------

type OrderedNode = Record<string, unknown>;

function elementName(node: OrderedNode): string | null {
  for (const key of Object.keys(node)) {
    if (key !== ':@' && key !== '#text') {
      return key;
    }
  }
  return null;
}

function children(node: OrderedNode): OrderedNode[] {
  const name = elementName(node);
  if (!name) {
    return [];
  }
  const value = node[name];
  if (Array.isArray(value)) {
    return value as OrderedNode[];
  }
  return [];
}

function attrs(node: OrderedNode): Record<string, string> {
  const raw = node[':@'] as Record<string, string> | undefined;
  if (!raw) {
    return {};
  }
  return raw;
}

function attr(node: OrderedNode, name: string): string | null {
  const value = attrs(node)[`@_${name}`];
  if (value === undefined || value === null) {
    return null;
  }
  return String(value);
}

function findElement(nodes: OrderedNode[], tagName: string): OrderedNode | undefined {
  for (const node of nodes) {
    if (elementName(node) === tagName) {
      return node;
    }
  }
  return undefined;
}

function findAllElements(nodes: OrderedNode[], tagName: string): OrderedNode[] {
  return nodes.filter((node) => elementName(node) === tagName);
}

function textContent(node: OrderedNode): string {
  const kidList = children(node);
  for (const kid of kidList) {
    const text = kid['#text'];
    if (text !== undefined && text !== null) {
      return String(text).trim();
    }
  }
  if (node['#text'] !== undefined && node['#text'] !== null) {
    return String(node['#text']).trim();
  }
  return '';
}

function childText(parentChildren: OrderedNode[], tagName: string): string {
  const element = findElement(parentChildren, tagName);
  if (!element) {
    return '';
  }
  return textContent(element);
}

function parseJsonText(text: string): Record<string, unknown> | null {
  if (text === '') {
    return null;
  }
  try {
    const parsed: unknown = JSON.parse(text);
    if (parsed !== null && typeof parsed === 'object') {
      return parsed as Record<string, unknown>;
    }
    return null;
  } catch {
    return null;
  }
}

function parseJsonAttr(value: string | null): Record<string, unknown> {
  if (value === null || value === '') {
    return {};
  }
  try {
    const parsed: unknown = JSON.parse(value);
    if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>;
    }
    return {};
  } catch {
    return {};
  }
}

function parseIntValue(text: string): number | null {
  const parsed = parseInt(text, 10);
  return Number.isNaN(parsed) ? null : parsed;
}

function parseNumberValue(text: string | null): number {
  if (text === null || text === '') {
    return 0;
  }
  const parsed = parseFloat(text);
  return Number.isNaN(parsed) ? 0 : parsed;
}

function emptyDefinitions(rawXml: string): BpmnDefinitions {
  return {
    definitionsId: null,
    processes: [],
    messages: [],
    signals: [],
    errors: [],
    escalations: [],
    rawXml,
  };
}

// ---------------------------------------------------------------------------
// Element-to-type maps (mirrors @flow_node_elements in SaxHandler)
// ---------------------------------------------------------------------------

const FLOW_NODE_ELEMENTS: ReadonlySet<string> = new Set([
  'startEvent',
  'endEvent',
  'intermediateCatchEvent',
  'intermediateThrowEvent',
  'boundaryEvent',
  'task',
  'userTask',
  'serviceTask',
  'manualTask',
  'scriptTask',
  'businessRuleTask',
  'sendTask',
  'receiveTask',
  'callActivity',
  'subProcess',
  'transaction',
  'exclusiveGateway',
  'parallelGateway',
  'inclusiveGateway',
  'eventBasedGateway',
  'complexGateway',
]);

const ELEMENT_TO_TYPE: Record<string, FlowNodeType> = {
  startEvent: FlowNodeType.StartEvent,
  endEvent: FlowNodeType.EndEvent,
  intermediateCatchEvent: FlowNodeType.IntermediateCatchEvent,
  intermediateThrowEvent: FlowNodeType.IntermediateThrowEvent,
  boundaryEvent: FlowNodeType.BoundaryEvent,
  task: FlowNodeType.Task,
  userTask: FlowNodeType.UserTask,
  serviceTask: FlowNodeType.ServiceTask,
  manualTask: FlowNodeType.ManualTask,
  scriptTask: FlowNodeType.ScriptTask,
  businessRuleTask: FlowNodeType.BusinessRuleTask,
  sendTask: FlowNodeType.SendTask,
  receiveTask: FlowNodeType.ReceiveTask,
  callActivity: FlowNodeType.CallActivity,
  subProcess: FlowNodeType.SubProcess,
  transaction: FlowNodeType.SubProcess,
  exclusiveGateway: FlowNodeType.ExclusiveGateway,
  parallelGateway: FlowNodeType.ParallelGateway,
  inclusiveGateway: FlowNodeType.InclusiveGateway,
  eventBasedGateway: FlowNodeType.EventBasedGateway,
  complexGateway: FlowNodeType.ComplexGateway,
};

type EventDefKind =
  | 'message'
  | 'signal'
  | 'timer'
  | 'error'
  | 'escalation'
  | 'conditional'
  | 'compensation'
  | 'terminate'
  | 'cancel'
  | 'link';

const EVENT_DEF_ELEMENTS: Record<string, EventDefKind> = {
  messageEventDefinition: 'message',
  signalEventDefinition: 'signal',
  timerEventDefinition: 'timer',
  errorEventDefinition: 'error',
  escalationEventDefinition: 'escalation',
  conditionalEventDefinition: 'conditional',
  compensateEventDefinition: 'compensation',
  terminateEventDefinition: 'terminate',
  cancelEventDefinition: 'cancel',
  linkEventDefinition: 'link',
};

const NONE_EVENT_DEFINITION: EventDefinition = Object.freeze({ type: 'none' } as EventDefinition);

// ---------------------------------------------------------------------------
// Definitions
// ---------------------------------------------------------------------------

function parseDefinitions(node: OrderedNode, rawXml: string): BpmnDefinitions {
  const kids = children(node);
  const result = emptyDefinitions(rawXml);
  result.definitionsId = attr(node, 'id');

  for (const child of kids) {
    const tag = elementName(child);
    switch (tag) {
      case 'message':
        result.messages.push({
          id: attr(child, 'id') ?? '',
          name: attr(child, 'name'),
        });
        break;

      case 'signal':
        result.signals.push({
          id: attr(child, 'id') ?? '',
          name: attr(child, 'name'),
        } satisfies SignalDefinition);
        break;

      case 'error':
        result.errors.push({
          id: attr(child, 'id') ?? '',
          name: attr(child, 'name'),
          errorCode: attr(child, 'errorCode'),
        });
        break;

      case 'escalation':
        result.escalations.push({
          id: attr(child, 'id') ?? '',
          name: attr(child, 'name'),
          escalationCode: attr(child, 'escalationCode'),
        } satisfies EscalationDefinition);
        break;

      case 'process':
        result.processes.push(parseProcess(child));
        break;
    }
  }

  return result;
}

// ---------------------------------------------------------------------------
// Process
// ---------------------------------------------------------------------------

function parseProcess(node: OrderedNode): BpmnProcess {
  const kids = children(node);
  const flowNodes: FlowNode[] = [];
  const sequenceFlows: SequenceFlow[] = [];
  const lanes: Lane[] = [];
  const dataObjects: DataObject[] = [];
  const dataObjectReferences: DataObjectReference[] = [];
  const dataStores: DataStore[] = [];
  const dataStoreReferences: DataStoreReference[] = [];
  const defaultFlows = new Map<string, string>();

  let version: string | null = null;
  let correlationKey: string | null = null;
  const linterScores: LinterRulesetScore[] = [];

  for (const child of kids) {
    const tag = elementName(child);
    if (!tag) {
      continue;
    }

    if (FLOW_NODE_ELEMENTS.has(tag)) {
      const nodeId = attr(child, 'id') ?? '';
      const defaultRef = attr(child, 'default');
      if (defaultRef !== null) {
        defaultFlows.set(nodeId, defaultRef);
      }
      flowNodes.push(parseFlowNode(child, ELEMENT_TO_TYPE[tag]!));
      continue;
    }

    switch (tag) {
      case 'sequenceFlow':
        sequenceFlows.push(parseSequenceFlow(child));
        break;

      case 'laneSet':
        for (const laneNode of findAllElements(children(child), 'lane')) {
          lanes.push(parseLane(laneNode));
        }
        break;

      case 'dataObject':
        dataObjects.push(parseDataObject(child));
        break;

      case 'dataObjectReference':
        dataObjectReferences.push({
          id: attr(child, 'id') ?? '',
          name: attr(child, 'name'),
          dataObjectRef: attr(child, 'dataObjectRef'),
          dataState: attr(child, 'dataState'),
        });
        break;

      case 'dataStore':
        dataStores.push(parseDataStore(child));
        break;

      case 'dataStoreReference':
        dataStoreReferences.push({
          id: attr(child, 'id') ?? '',
          name: attr(child, 'name'),
          dataStoreRef: attr(child, 'dataStoreRef'),
          dataState: attr(child, 'dataState'),
        });
        break;

      case 'extensionElements':
        parseProcessExtensions(
          children(child),
          (value) => {
            version = value;
          },
          (key) => {
            correlationKey = key;
          },
          linterScores,
        );
        break;
    }
  }

  const process: BpmnProcess = {
    id: attr(node, 'id') ?? '',
    name: attr(node, 'name'),
    version,
    isExecutable: attr(node, 'isExecutable') !== 'false',
    correlationKey,
    flowNodes,
    sequenceFlows,
    lanes,
    dataObjects,
    dataObjectReferences,
    dataStores,
    dataStoreReferences,
    extensions: [],
    linterScores,
  };

  applyDefaultFlows(process, defaultFlows);
  linkBoundaryRefs(process);

  return process;
}

function parseProcessExtensions(
  extensionChildren: OrderedNode[],
  setVersion: (version: string) => void,
  setCorrelationKey: (key: string) => void,
  linterScores: LinterRulesetScore[],
): void {
  for (const child of extensionChildren) {
    const tag = elementName(child);
    switch (tag) {
      case 'version': {
        const text = textContent(child);
        if (text !== '') {
          setVersion(text);
        }
        break;
      }
      case 'correlationKey': {
        const text = textContent(child);
        if (text !== '') {
          setCorrelationKey(text);
        }
        break;
      }
      case 'linterRulesetScore':
        linterScores.push({
          rulesetId: attr(child, 'rulesetId') ?? attr(child, 'ruleset-id') ?? '',
          score: parseNumberValue(attr(child, 'score')),
          checks: parseJsonAttr(attr(child, 'checks')),
        });
        break;
    }
  }
}

// ---------------------------------------------------------------------------
// FlowNode
// ---------------------------------------------------------------------------

function parseFlowNode(node: OrderedNode, type: FlowNodeType): FlowNode {
  const kids = children(node);
  const incoming: string[] = [];
  const outgoing: string[] = [];
  let documentation: string | null = null;
  let multiInstance: MultiInstance | null = null;
  const dataContracts: DataContract[] = [];
  const dataInputAssociations: DataAssociation[] = [];
  const dataOutputAssociations: DataAssociation[] = [];

  for (const child of kids) {
    const tag = elementName(child);
    switch (tag) {
      case 'incoming': {
        const ref = textContent(child);
        if (ref !== '') {
          incoming.push(ref);
        }
        break;
      }
      case 'outgoing': {
        const ref = textContent(child);
        if (ref !== '') {
          outgoing.push(ref);
        }
        break;
      }
      case 'documentation': {
        const text = textContent(child);
        if (text !== '') {
          documentation = text;
        }
        break;
      }
      case 'multiInstanceLoopCharacteristics':
        multiInstance = parseMultiInstance(child);
        break;
      case 'dataInputAssociation':
        dataInputAssociations.push(parseAssociation(child, 'dia'));
        break;
      case 'dataOutputAssociation':
        dataOutputAssociations.push(parseAssociation(child, 'doa'));
        break;
    }
  }

  collectDataContracts(kids, dataContracts);

  const tagName = elementName(node) ?? undefined;
  const typeData = buildTypeData(node, kids, type, tagName);

  return {
    id: attr(node, 'id') ?? '',
    name: attr(node, 'name'),
    type,
    typeData,
    incoming,
    outgoing,
    boundaryEventRefs: [],
    dataContracts,
    dataInputAssociations,
    dataOutputAssociations,
    multiInstance,
    documentation,
  };
}

// ---------------------------------------------------------------------------
// Type data builders
// ---------------------------------------------------------------------------

function getExtensionChildren(kids: OrderedNode[]): OrderedNode[] {
  const extensionNode = findElement(kids, 'extensionElements');
  return extensionNode ? children(extensionNode) : [];
}

function buildTypeData(node: OrderedNode, kids: OrderedNode[], type: FlowNodeType, tagName?: string): FlowNodeTypeData {
  const extKids = getExtensionChildren(kids);

  switch (type) {
    case FlowNodeType.StartEvent:
      return {
        type: 'start_event',
        eventDefinition: parseEventDefinition(kids),
        isInterrupting: attr(node, 'isInterrupting') !== 'false',
        resultContract: parseJsonText(childText(extKids, 'resultContract')),
      };

    case FlowNodeType.EndEvent: {
      const { inMappings } = parseMappings(extKids);
      return {
        type: 'end_event',
        eventDefinition: parseEventDefinition(kids),
        inMappings,
        payloadContract: parseJsonText(childText(extKids, 'payloadContract')),
      };
    }

    case FlowNodeType.IntermediateCatchEvent: {
      const { outMappings } = parseMappings(extKids);
      return {
        type: 'intermediate_catch_event',
        eventDefinition: parseEventDefinition(kids),
        outMappings,
        resultContract: parseJsonText(childText(extKids, 'resultContract')),
      };
    }

    case FlowNodeType.IntermediateThrowEvent: {
      const { inMappings } = parseMappings(extKids);
      return {
        type: 'intermediate_throw_event',
        eventDefinition: parseEventDefinition(kids),
        inMappings,
        payloadContract: parseJsonText(childText(extKids, 'payloadContract')),
      };
    }

    case FlowNodeType.BoundaryEvent: {
      const { outMappings } = parseMappings(extKids);
      return {
        type: 'boundary_event',
        eventDefinition: parseEventDefinition(kids),
        attachedToRef: attr(node, 'attachedToRef'),
        cancelActivity: attr(node, 'cancelActivity') !== 'false',
        outMappings,
        resultContract: parseJsonText(childText(extKids, 'resultContract')),
      } satisfies BoundaryEventTypeData;
    }

    case FlowNodeType.Task:
      return { type: 'task' };

    case FlowNodeType.UserTask:
      return buildUserTaskTypeData(extKids);

    case FlowNodeType.ServiceTask:
      return buildServiceTaskTypeData(node, extKids);

    case FlowNodeType.ManualTask:
      return buildManualTaskTypeData(extKids);

    case FlowNodeType.ScriptTask:
      return buildScriptTaskTypeData(node, kids, extKids);

    case FlowNodeType.BusinessRuleTask:
      return buildBusinessRuleTaskTypeData(node, extKids);

    case FlowNodeType.SendTask: {
      const { inMappings } = parseMappings(extKids);
      return {
        type: 'send_task',
        messageRef: attr(node, 'messageRef'),
        payloadContract: parseJsonText(childText(extKids, 'payloadContract')),
        inMappings,
      };
    }

    case FlowNodeType.ReceiveTask: {
      const { outMappings } = parseMappings(extKids);
      return {
        type: 'receive_task',
        messageRef: attr(node, 'messageRef'),
        resultContract: parseJsonText(childText(extKids, 'resultContract')),
        outMappings,
      };
    }

    case FlowNodeType.CallActivity:
      return buildCallActivityTypeData(node, extKids);

    case FlowNodeType.SubProcess:
      return buildSubProcessTypeData(node, kids, extKids, tagName === 'transaction');

    case FlowNodeType.ExclusiveGateway:
      return {
        type: 'exclusive_gateway',
        defaultFlowRef: null,
      } satisfies ExclusiveGatewayTypeData;

    case FlowNodeType.ParallelGateway:
      return { type: 'parallel_gateway' };

    case FlowNodeType.InclusiveGateway:
      return { type: 'inclusive_gateway', defaultFlowRef: null };

    case FlowNodeType.EventBasedGateway:
      return { type: 'event_based_gateway' };

    case FlowNodeType.ComplexGateway:
      return { type: 'complex_gateway', activationCondition: null };
  }
}

function buildUserTaskTypeData(extKids: OrderedNode[]): FlowNodeTypeData {
  const { inMappings, outMappings } = parseMappings(extKids);

  const rawActions = parseJsonText(childText(extKids, 'formActions'));
  const formActions = Array.isArray(rawActions) ? (rawActions as Record<string, unknown>[]) : null;

  return {
    type: 'user_task',
    formSchema: parseJsonText(childText(extKids, 'formFields')),
    formActions,
    assigneesExpression: childText(extKids, 'assignees') || null,
    payloadContract: parseJsonText(childText(extKids, 'payloadContract')),
    resultContract: parseJsonText(childText(extKids, 'resultContract')),
    inMappings,
    outMappings,
    dueDate: childText(extKids, 'dueDate') || null,
    priority: parseIntValue(childText(extKids, 'priority')),
  };
}

function buildServiceTaskTypeData(node: OrderedNode, extKids: OrderedNode[]): FlowNodeTypeData {
  const { inMappings, outMappings } = parseMappings(extKids);

  const implementation = attr(node, 'implementation');

  const serviceTaskTypeConfig: Record<string, unknown> = {};

  const httpUrl = childText(extKids, 'httpUrl') || null;
  if (httpUrl) {
    serviceTaskTypeConfig['httpUrl'] = httpUrl;
  }

  const httpMethodRaw = childText(extKids, 'httpMethod');
  if (httpMethodRaw !== '') {
    serviceTaskTypeConfig['httpMethod'] = httpMethodRaw.toUpperCase();
  }

  const httpBody = childText(extKids, 'httpBody') || null;
  if (httpBody) {
    serviceTaskTypeConfig['httpBody'] = httpBody;
  }

  const httpAuthHeader = childText(extKids, 'httpAuthHeader') || null;
  if (httpAuthHeader) {
    serviceTaskTypeConfig['httpAuthHeader'] = httpAuthHeader;
  }

  const httpResponseHeaders = childText(extKids, 'httpResponseHeaders') || null;
  if (httpResponseHeaders) {
    serviceTaskTypeConfig['httpResponseHeaders'] = httpResponseHeaders;
  }

  return {
    type: 'service_task',
    implementation,
    payloadContract: parseJsonText(childText(extKids, 'payloadContract')),
    resultContract: parseJsonText(childText(extKids, 'resultContract')),
    inMappings,
    outMappings,
    serviceTaskTypeConfig,
  } satisfies ServiceTaskTypeData;
}

function buildManualTaskTypeData(extKids: OrderedNode[]): FlowNodeTypeData {
  return {
    type: 'manual_task',
    requireConfirmation: childText(extKids, 'requireConfirmation') === 'true',
  };
}

function buildScriptTaskTypeData(node: OrderedNode, kids: OrderedNode[], extKids: OrderedNode[]): FlowNodeTypeData {
  const { inMappings, outMappings } = parseMappings(extKids);

  return {
    type: 'script_task',
    scriptFormat: attr(node, 'scriptFormat'),
    script: childText(kids, 'script') || null,
    scriptRef: childText(extKids, 'scriptRef') || null,
    payloadContract: parseJsonText(childText(extKids, 'payloadContract')),
    resultContract: parseJsonText(childText(extKids, 'resultContract')),
    inMappings,
    outMappings,
  };
}

function buildBusinessRuleTaskTypeData(node: OrderedNode, extKids: OrderedNode[]): FlowNodeTypeData {
  const bpmnImpl = attr(node, 'implementation');
  const extImpl = childText(extKids, 'implementation') || null;

  return {
    type: 'business_rule_task',
    implementation: bpmnImpl ?? extImpl,
    ruleRef: null,
  };
}

/**
 * Recursively parses the inner scope of an embedded subprocess, mirroring
 * the Elixir parser's `handle_end("subProcess")` pipeline: inner flow
 * nodes, sequence flows, data objects, default flow assignment, and
 * boundary ref linking.
 */
function buildSubProcessTypeData(node: OrderedNode, kids: OrderedNode[], extKids: OrderedNode[], isTransaction = false): FlowNodeTypeData {
  const { inMappings, outMappings } = parseMappings(extKids);
  const innerFlowNodes: FlowNode[] = [];
  const innerSequenceFlows: SequenceFlow[] = [];
  const innerDataObjects: DataObject[] = [];
  const innerDataObjectRefs: DataObjectReference[] = [];
  const innerDefaults = new Map<string, string>();

  for (const child of kids) {
    const tag = elementName(child);
    if (!tag) {
      continue;
    }

    if (FLOW_NODE_ELEMENTS.has(tag)) {
      const nodeId = attr(child, 'id') ?? '';
      const defaultRef = attr(child, 'default');
      if (defaultRef !== null) {
        innerDefaults.set(nodeId, defaultRef);
      }
      innerFlowNodes.push(parseFlowNode(child, ELEMENT_TO_TYPE[tag]!));
      continue;
    }

    switch (tag) {
      case 'sequenceFlow':
        innerSequenceFlows.push(parseSequenceFlow(child));
        break;
      case 'dataObject':
        innerDataObjects.push(parseDataObject(child));
        break;
      case 'dataObjectReference':
        innerDataObjectRefs.push({
          id: attr(child, 'id') ?? '',
          name: attr(child, 'name'),
          dataObjectRef: attr(child, 'dataObjectRef'),
          dataState: attr(child, 'dataState'),
        });
        break;
    }
  }

  const syntheticProcess: BpmnProcess = {
    id: attr(node, 'id') ?? '',
    name: attr(node, 'name'),
    version: null,
    isExecutable: false,
    correlationKey: null,
    flowNodes: innerFlowNodes,
    sequenceFlows: innerSequenceFlows,
    lanes: [],
    dataObjects: innerDataObjects,
    dataObjectReferences: innerDataObjectRefs,
    dataStores: [],
    dataStoreReferences: [],
    extensions: [],
    linterScores: [],
  };

  applyDefaultFlows(syntheticProcess, innerDefaults);
  linkBoundaryRefs(syntheticProcess);

  return {
    type: 'sub_process',
    triggeredByEvent: attr(node, 'triggeredByEvent') === 'true',
    isTransaction,
    transactionMethod: isTransaction ? (attr(node, 'method') ?? null) : null,
    flowNodes: syntheticProcess.flowNodes,
    sequenceFlows: syntheticProcess.sequenceFlows,
    dataObjects: syntheticProcess.dataObjects,
    dataObjectReferences: syntheticProcess.dataObjectReferences,
    payloadContract: parseJsonText(childText(extKids, 'payloadContract')),
    resultContract: parseJsonText(childText(extKids, 'resultContract')),
    inMappings,
    outMappings,
  };
}

function buildCallActivityTypeData(node: OrderedNode, extKids: OrderedNode[]): FlowNodeTypeData {
  const { inMappings, outMappings } = parseMappings(extKids);
  return {
    type: 'call_activity',
    calledElement: attr(node, 'calledElement'),
    startEventId: childText(extKids, 'startEventId') || null,
    inMappings,
    outMappings,
  };
}

// ---------------------------------------------------------------------------
// Event definitions
// ---------------------------------------------------------------------------

function parseEventDefinition(kids: OrderedNode[]): EventDefinition {
  for (const child of kids) {
    const tag = elementName(child);
    if (tag && tag in EVENT_DEF_ELEMENTS) {
      return buildEventDefinition(EVENT_DEF_ELEMENTS[tag]!, child);
    }
  }
  return NONE_EVENT_DEFINITION;
}

function buildEventDefinition(kind: EventDefKind, node: OrderedNode): EventDefinition {
  const extKids = getExtensionChildren(children(node));
  const nodeKids = children(node);

  switch (kind) {
    case 'message': {
      const def: MessageEventDefinition = {
        type: 'message',
        messageRef: attr(node, 'messageRef'),
        correlationRetrievalExpression: childText(extKids, 'correlationRetrievalExpression') || null,
        payloadExpression: childText(extKids, 'payload') || null,
        eventMapping: childText(extKids, 'eventMapping') || null,
      };
      return def;
    }

    case 'signal':
      return { type: 'signal', signalRef: attr(node, 'signalRef') };

    case 'timer':
      return {
        type: 'timer',
        timeDate: childText(nodeKids, 'timeDate') || null,
        timeDuration: childText(nodeKids, 'timeDuration') || null,
        timeCycle: childText(nodeKids, 'timeCycle') || null,
      };

    case 'error': {
      const def: ErrorEventDefinition = {
        type: 'error',
        errorRef: attr(node, 'errorRef'),
        errorCode: childText(extKids, 'errorCode') || null,
        errorMessage: childText(extKids, 'errorMessage') || null,
      };
      return def;
    }

    case 'escalation':
      return {
        type: 'escalation',
        escalationRef: attr(node, 'escalationRef'),
        escalationCode: null,
      };

    case 'conditional':
      return {
        type: 'conditional',
        conditionExpression: childText(nodeKids, 'condition') || null,
      };

    case 'compensation':
      return {
        type: 'compensation',
        activityRef: attr(node, 'activityRef'),
        waitForCompletion: attr(node, 'waitForCompletion') !== 'false',
      };

    case 'terminate':
      return { type: 'terminate' };

    case 'cancel':
      return { type: 'cancel' };

    case 'link':
      return { type: 'link', linkName: attr(node, 'name') };
  }
}

// ---------------------------------------------------------------------------
// Sequence flow
// ---------------------------------------------------------------------------

function parseSequenceFlow(node: OrderedNode): SequenceFlow {
  const condText = childText(children(node), 'conditionExpression');
  return {
    id: attr(node, 'id') ?? '',
    name: attr(node, 'name'),
    sourceRef: attr(node, 'sourceRef') ?? '',
    targetRef: attr(node, 'targetRef') ?? '',
    conditionExpression: condText !== '' ? condText : null,
    isDefault: false,
  };
}

// ---------------------------------------------------------------------------
// Lane
// ---------------------------------------------------------------------------

function parseLane(node: OrderedNode): Lane {
  const flowNodeRefs: string[] = [];
  for (const child of findAllElements(children(node), 'flowNodeRef')) {
    const ref = textContent(child);
    if (ref !== '') {
      flowNodeRefs.push(ref);
    }
  }
  return {
    id: attr(node, 'id') ?? '',
    name: attr(node, 'name'),
    flowNodeRefs,
  };
}

// ---------------------------------------------------------------------------
// Data objects
// ---------------------------------------------------------------------------

function parseDataObject(node: OrderedNode): DataObject {
  const extKids = getExtensionChildren(children(node));
  let valueContract: Record<string, unknown> | null = null;

  const vcText = childText(extKids, 'valueContract');
  if (vcText !== '') {
    valueContract = parseJsonText(vcText);
  }

  return {
    id: attr(node, 'id') ?? '',
    name: attr(node, 'name'),
    itemSubjectRef: attr(node, 'itemSubjectRef'),
    valueContract,
  };
}

// ---------------------------------------------------------------------------
// Data stores
// ---------------------------------------------------------------------------

function parseDataStore(node: OrderedNode): DataStore {
  const capacityAttr = attr(node, 'capacity');
  const isUnlimited = attr(node, 'isUnlimited') === 'true';

  return {
    id: attr(node, 'id') ?? '',
    name: attr(node, 'name'),
    capacity: capacityAttr !== null ? parseIntValue(capacityAttr) : null,
    isUnlimited,
    itemSubjectRef: attr(node, 'itemSubjectRef'),
  };
}

// ---------------------------------------------------------------------------
// Data associations
// ---------------------------------------------------------------------------

let autoIdCounter = 0;

function parseAssociation(node: OrderedNode, prefix: string): DataAssociation {
  autoIdCounter++;
  const kids = children(node);
  const id = attr(node, 'id') ?? `${prefix}_auto_${String(autoIdCounter)}`;

  return {
    id,
    sourceRef: childText(kids, 'sourceRef') || null,
    targetRef: childText(kids, 'targetRef') || null,
    valueExpression: childText(kids, 'transformation') || null,
  };
}

// ---------------------------------------------------------------------------
// Data contracts
// ---------------------------------------------------------------------------

function collectDataContracts(kids: OrderedNode[], contracts: DataContract[]): void {
  const extKids = getExtensionChildren(kids);
  for (const child of findAllElements(extKids, 'dataContract')) {
    const text = textContent(child);
    const parsed = parseJsonText(text);
    if (parsed === null) {
      continue;
    }

    const direction: 'input' | 'output' = parsed['direction'] === 'output' ? 'output' : 'input';
    const schemaMap = (parsed['schema'] ?? parsed) as Record<string, unknown>;

    contracts.push({
      direction,
      jsonSchema: schemaMap,
      compiledSchema: null,
    });
  }
}

// ---------------------------------------------------------------------------
// Multi-instance
// ---------------------------------------------------------------------------

function parseMultiInstance(node: OrderedNode): MultiInstance {
  const kids = children(node);
  const extKids = getExtensionChildren(kids);

  const maxIterationsText = childText(extKids, 'maxIterations');

  return {
    isSequential: attr(node, 'isSequential') === 'true',
    cardinalityExpression: childText(kids, 'loopCardinality') || null,
    collectionExpression: childText(extKids, 'inputCollection') || null,
    elementVariable: null,
    completionCondition: childText(kids, 'completionCondition') || null,
    outputCollection: childText(extKids, 'outputCollection') || null,
    loopBreakCondition: childText(extKids, 'loopBreakCondition') || null,
    loopInterval: childText(extKids, 'loopInterval') || null,
    maxIterations: maxIterationsText !== '' ? parseIntValue(maxIterationsText) : null,
  };
}

// ---------------------------------------------------------------------------
// Mappings
// ---------------------------------------------------------------------------

function parseMappings(extKids: OrderedNode[]): {
  inMappings: Mapping[];
  outMappings: Mapping[];
} {
  const inMappings: Mapping[] = [];
  const outMappings: Mapping[] = [];

  for (const child of extKids) {
    const tag = elementName(child);
    if (tag === 'inputMapping') {
      inMappings.push({
        source: attr(child, 'source') ?? '',
        target: attr(child, 'target') ?? '',
      });
    } else if (tag === 'outputMapping') {
      outMappings.push({
        source: attr(child, 'source') ?? '',
        target: attr(child, 'target') ?? '',
      });
    }
  }

  return { inMappings, outMappings };
}

// ---------------------------------------------------------------------------
// Post-processing (mirrors Elixir finalize logic)
// ---------------------------------------------------------------------------

function applyDefaultFlows(process: BpmnProcess, defaults: Map<string, string>): void {
  if (defaults.size === 0) {
    return;
  }

  const defaultFlowIds = new Set(defaults.values());

  for (const node of process.flowNodes) {
    const defaultRef = defaults.get(node.id);
    if (defaultRef !== undefined) {
      applyDefaultToTypeData(node, defaultRef);
    }
  }

  for (const sequenceFlow of process.sequenceFlows) {
    if (defaultFlowIds.has(sequenceFlow.id)) {
      (sequenceFlow as { isDefault: boolean }).isDefault = true;
    }
  }
}

function applyDefaultToTypeData(node: FlowNode, defaultRef: string): void {
  const typeData = node.typeData;
  if ('defaultFlowRef' in typeData) {
    (typeData as { defaultFlowRef: string | null }).defaultFlowRef = defaultRef;
  }
}

function linkBoundaryRefs(process: BpmnProcess): void {
  const boundaryMap = new Map<string, string[]>();

  for (const node of process.flowNodes) {
    if (node.type === FlowNodeType.BoundaryEvent) {
      const attachedTo = (node.typeData as BoundaryEventTypeData).attachedToRef;
      if (attachedTo !== null) {
        const existing = boundaryMap.get(attachedTo) ?? [];
        existing.push(node.id);
        boundaryMap.set(attachedTo, existing);
      }
    }
  }

  if (boundaryMap.size === 0) {
    return;
  }

  for (const node of process.flowNodes) {
    const refs = boundaryMap.get(node.id);
    if (refs) {
      (node as { boundaryEventRefs: string[] }).boundaryEventRefs = refs;
    }
  }
}
