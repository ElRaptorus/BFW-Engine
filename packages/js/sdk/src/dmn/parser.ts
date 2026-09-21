/**
 * DMN XML parser producing the same typed model as the engine's
 * `BfwEngine.DMN.Parser`. Uses `fast-xml-parser` with
 * `preserveOrder: true` to maintain document order, then walks the
 * ordered tree to build model objects.
 */
import { XMLParser } from 'fast-xml-parser';

import { DmnHitPolicy } from '../types/enums.js';
import type {
  DmnAggregation,
  DmnAuthorityRequirement,
  DmnBinding,
  DmnBounds,
  DmnBoxedConditional,
  DmnBoxedContext,
  DmnBoxedEvery,
  DmnBoxedFilter,
  DmnBoxedFor,
  DmnBoxedInvocation,
  DmnBoxedList,
  DmnBoxedSome,
  DmnBusinessKnowledgeModel,
  DmnContextEntry,
  DmnDI,
  DmnDecision,
  DmnDecisionService,
  DmnDecisionTable,
  DmnDefinitions,
  DmnDiagram,
  DmnEdge,
  DmnExpressionBody,
  DmnFunctionDefinition,
  DmnImport,
  DmnInformationItem,
  DmnInformationRequirement,
  DmnInput,
  DmnInputData,
  DmnInputEntry,
  DmnItemDefinition,
  DmnKnowledgeRequirement,
  DmnKnowledgeSource,
  DmnLiteralExpression,
  DmnOrientation,
  DmnOutput,
  DmnOutputEntry,
  DmnPoint,
  DmnRelation,
  DmnRule,
  DmnShape,
} from './model.js';

export function parseDmn(xml: string): DmnDefinitions {
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

function emptyDefinitions(rawXml: string): DmnDefinitions {
  return {
    id: null,
    name: null,
    namespace: null,
    decisions: [],
    inputData: [],
    businessKnowledgeModels: [],
    knowledgeSources: [],
    itemDefinitions: [],
    imports: [],
    decisionServices: [],
    dmndi: null,
    rawXml,
  };
}

function parseDefinitions(node: OrderedNode, rawXml: string): DmnDefinitions {
  const result = emptyDefinitions(rawXml);
  result.id = attr(node, 'id');
  result.name = attr(node, 'name');
  result.namespace = attr(node, 'targetNamespace') ?? attr(node, 'namespace');

  for (const child of children(node)) {
    const tag = elementName(child);
    switch (tag) {
      case 'decision':
        result.decisions.push(parseDecision(child));
        break;
      case 'inputData':
        result.inputData.push(parseInputData(child));
        break;
      case 'businessKnowledgeModel':
        result.businessKnowledgeModels.push(parseBusinessKnowledgeModel(child));
        break;
      case 'knowledgeSource':
        result.knowledgeSources.push(parseKnowledgeSource(child));
        break;
      case 'itemDefinition':
        result.itemDefinitions.push(parseItemDefinition(child));
        break;
      case 'import':
        result.imports.push(parseImport(child));
        break;
      case 'decisionService':
        result.decisionServices.push(parseDecisionService(child));
        break;
      case 'DMNDI':
        result.dmndi = parseDMNDI(child);
        break;
      default:
        break;
    }
  }

  return result;
}

function parseDecision(node: OrderedNode): DmnDecision {
  const kidList = children(node);
  let outputLabel: string | null = null;
  let variable: DmnInformationItem | null = null;
  const variableNode = findElement(kidList, 'variable');
  if (variableNode) {
    variable = parseInformationItem(variableNode);
    outputLabel = variable.name !== '' ? variable.name : null;
  }

  let expression: DmnExpressionBody | null = null;
  const informationRequirements: DmnInformationRequirement[] = [];
  const knowledgeRequirements: DmnKnowledgeRequirement[] = [];
  const authorityRequirements: DmnAuthorityRequirement[] = [];

  for (const child of kidList) {
    const tag = elementName(child);
    const parsedExpression = parseExpressionBody(child, tag);
    if (parsedExpression !== null) {
      expression = parsedExpression;
    } else if (tag === 'informationRequirement') {
      informationRequirements.push(parseInformationRequirement(child));
    } else if (tag === 'knowledgeRequirement') {
      knowledgeRequirements.push(parseKnowledgeRequirement(child));
    } else if (tag === 'authorityRequirement') {
      authorityRequirements.push(parseAuthorityRequirement(child));
    }
  }

  return {
    id: attr(node, 'id') ?? '',
    name: attr(node, 'name'),
    outputLabel,
    expression,
    informationRequirements,
    knowledgeRequirements,
    authorityRequirements,
    variable,
  };
}

function parseDecisionTable(node: OrderedNode): DmnDecisionTable {
  const kidList = children(node);
  const inputs: DmnInput[] = [];
  const outputs: DmnOutput[] = [];
  const rules: DmnRule[] = [];

  for (const child of kidList) {
    const tag = elementName(child);
    switch (tag) {
      case 'input':
        inputs.push(parseInput(child));
        break;
      case 'output':
        outputs.push(parseOutput(child));
        break;
      case 'rule':
        rules.push(parseRule(child));
        break;
      default:
        break;
    }
  }

  return {
    id: attr(node, 'id'),
    hitPolicy: parseHitPolicy(attr(node, 'hitPolicy')),
    aggregation: parseAggregation(attr(node, 'aggregation')),
    preferredOrientation: parsePreferredOrientation(attr(node, 'preferredOrientation')),
    inputs,
    outputs,
    rules,
  };
}

function parseHitPolicy(raw: string | null): DmnHitPolicy {
  if (raw === null || raw === '') {
    return DmnHitPolicy.Unique;
  }
  const normalized = raw.trim().toUpperCase().replace(/\s+/g, '_');
  switch (normalized) {
    case 'UNIQUE':
    case 'U':
      return DmnHitPolicy.Unique;
    case 'FIRST':
    case 'F':
      return DmnHitPolicy.First;
    case 'ANY':
    case 'A':
      return DmnHitPolicy.Any;
    case 'COLLECT':
    case 'C':
      return DmnHitPolicy.Collect;
    case 'RULE_ORDER':
    case 'R':
      return DmnHitPolicy.RuleOrder;
    case 'OUTPUT_ORDER':
    case 'O':
      return DmnHitPolicy.OutputOrder;
    case 'PRIORITY':
    case 'P':
      return DmnHitPolicy.Priority;
    default:
      return DmnHitPolicy.Unique;
  }
}

function parseAggregation(raw: string | null): DmnAggregation | null {
  if (raw === null || raw === '') {
    return null;
  }
  const normalized = raw.trim().toUpperCase();
  if (normalized === 'SUM' || normalized === 'MIN' || normalized === 'MAX' || normalized === 'COUNT') {
    return normalized as DmnAggregation;
  }
  return null;
}

function parsePreferredOrientation(raw: string | null): DmnOrientation {
  if (raw === null || raw === '') {
    return 'Rule-as-Row';
  }
  const normalized = raw.trim().toLowerCase().replace(/\s+/g, '-');
  switch (normalized) {
    case 'rule-as-row':
    case 'rule_as_row':
      return 'Rule-as-Row';
    case 'rule-as-column':
    case 'rule_as_column':
      return 'Rule-as-Column';
    case 'crosstable':
    case 'cross-table':
      return 'CrossTable';
    default:
      return 'Rule-as-Row';
  }
}

function parseInput(node: OrderedNode): DmnInput {
  const kidList = children(node);
  const inputExpressionNode = findElement(kidList, 'inputExpression');
  let inputExpression: string | null = null;
  let typeRef: string | null = null;
  if (inputExpressionNode) {
    typeRef = attr(inputExpressionNode, 'typeRef');
    const expressionChildren = children(inputExpressionNode);
    const fromTextChild = childText(expressionChildren, 'text');
    inputExpression = fromTextChild !== '' ? fromTextChild : null;
    if (inputExpression === null) {
      const fallback = textContent(inputExpressionNode);
      inputExpression = fallback !== '' ? fallback : null;
    }
  }

  const inputValuesNode = findElement(kidList, 'inputValues');
  let inputValues: string | null = null;
  if (inputValuesNode) {
    const valuesChildren = children(inputValuesNode);
    const fromTextChild = childText(valuesChildren, 'text');
    inputValues = fromTextChild !== '' ? fromTextChild : null;
    if (inputValues === null) {
      const fallback = textContent(inputValuesNode);
      inputValues = fallback !== '' ? fallback : null;
    }
  }

  return {
    id: attr(node, 'id') ?? '',
    label: attr(node, 'label'),
    inputExpression,
    inputValues,
    typeRef,
  };
}

function parseOutput(node: OrderedNode): DmnOutput {
  const kidList = children(node);
  const outputValuesNode = findElement(kidList, 'outputValues');
  let outputValues: string | null = null;
  if (outputValuesNode) {
    const valuesChildren = children(outputValuesNode);
    const fromTextChild = childText(valuesChildren, 'text');
    outputValues = fromTextChild !== '' ? fromTextChild : null;
    if (outputValues === null) {
      const fallback = textContent(outputValuesNode);
      outputValues = fallback !== '' ? fallback : null;
    }
  }

  const defaultOutputEntryNode = findElement(kidList, 'defaultOutputEntry');
  let defaultOutputValue: string | null = null;
  if (defaultOutputEntryNode) {
    const entryChildren = children(defaultOutputEntryNode);
    const fromTextChild = childText(entryChildren, 'text');
    defaultOutputValue = fromTextChild !== '' ? fromTextChild : null;
    if (defaultOutputValue === null) {
      const fallback = textContent(defaultOutputEntryNode);
      defaultOutputValue = fallback !== '' ? fallback : null;
    }
  }

  return {
    id: attr(node, 'id') ?? '',
    label: attr(node, 'label'),
    name: attr(node, 'name'),
    outputValues,
    typeRef: attr(node, 'typeRef'),
    defaultOutputValue,
  };
}

function parseRule(node: OrderedNode): DmnRule {
  const kidList = children(node);
  let description: string | null = attr(node, 'description');
  if (description === null) {
    const descriptionNode = findElement(kidList, 'description');
    if (descriptionNode) {
      const descriptionText = entryBodyText(descriptionNode);
      description = descriptionText !== '' ? descriptionText : null;
    }
  }
  const inputEntries: DmnInputEntry[] = [];
  const outputEntries: DmnOutputEntry[] = [];
  const annotationEntries: string[] = [];

  for (const child of kidList) {
    const tag = elementName(child);
    switch (tag) {
      case 'inputEntry':
        inputEntries.push(parseInputEntry(child));
        break;
      case 'outputEntry':
        outputEntries.push(parseOutputEntry(child));
        break;
      case 'annotationEntry': {
        const annotationText = entryBodyText(child);
        annotationEntries.push(annotationText);
        break;
      }
      default:
        break;
    }
  }

  return {
    id: attr(node, 'id') ?? '',
    description,
    inputEntries,
    outputEntries,
    annotationEntries,
  };
}

function parseInputEntry(node: OrderedNode): DmnInputEntry {
  return {
    id: attr(node, 'id') ?? '',
    text: entryBodyText(node),
  };
}

function parseOutputEntry(node: OrderedNode): DmnOutputEntry {
  return {
    id: attr(node, 'id') ?? '',
    text: entryBodyText(node),
  };
}

function entryBodyText(node: OrderedNode): string {
  const kidList = children(node);
  const fromTextChild = childText(kidList, 'text');
  if (fromTextChild !== '') {
    return fromTextChild;
  }
  return textContent(node);
}

function parseInputData(node: OrderedNode): DmnInputData {
  const kidList = children(node);
  const variableNode = findElement(kidList, 'variable');
  let typeRef: string | null = null;
  if (variableNode) {
    typeRef = attr(variableNode, 'typeRef');
  }

  return {
    id: attr(node, 'id') ?? '',
    name: attr(node, 'name') ?? '',
    typeRef,
  };
}

function parseInformationRequirement(node: OrderedNode): DmnInformationRequirement {
  const kidList = children(node);
  const requiredDecisionNode = findElement(kidList, 'requiredDecision');
  const requiredInputNode = findElement(kidList, 'requiredInput');

  return {
    id: attr(node, 'id'),
    requiredDecisionId: fragmentIdFromHref(requiredDecisionNode ? attr(requiredDecisionNode, 'href') : null),
    requiredInputId: fragmentIdFromHref(requiredInputNode ? attr(requiredInputNode, 'href') : null),
  };
}

function parseLiteralExpression(node: OrderedNode): DmnLiteralExpression {
  const kidList = children(node);
  const textNode = findElement(kidList, 'text');

  return {
    id: attr(node, 'id'),
    text: textNode ? textContent(textNode) : '',
    typeRef: attr(node, 'typeRef'),
    expressionLanguage: attr(node, 'expressionLanguage'),
  };
}

function parseBusinessKnowledgeModel(node: OrderedNode): DmnBusinessKnowledgeModel {
  const kidList = children(node);
  let encapsulatedLogic: DmnFunctionDefinition | null = null;
  let variable: DmnInformationItem | null = null;
  const knowledgeRequirements: DmnKnowledgeRequirement[] = [];
  const authorityRequirements: DmnAuthorityRequirement[] = [];

  for (const child of kidList) {
    const tag = elementName(child);
    switch (tag) {
      case 'encapsulatedLogic':
        encapsulatedLogic = parseEncapsulatedLogic(child);
        break;
      case 'variable':
        variable = parseInformationItem(child);
        break;
      case 'knowledgeRequirement':
        knowledgeRequirements.push(parseKnowledgeRequirement(child));
        break;
      case 'authorityRequirement':
        authorityRequirements.push(parseAuthorityRequirement(child));
        break;
      default:
        break;
    }
  }

  return {
    id: attr(node, 'id') ?? '',
    name: attr(node, 'name'),
    encapsulatedLogic,
    knowledgeRequirements,
    authorityRequirements,
    variable,
  };
}

function parseEncapsulatedLogic(node: OrderedNode): DmnFunctionDefinition {
  return parseFunctionDefinition(node);
}

function parseFunctionDefinition(node: OrderedNode): DmnFunctionDefinition {
  const kidList = children(node);
  const formalParameters: DmnInformationItem[] = [];
  let body: DmnExpressionBody | null = null;

  for (const child of kidList) {
    const tag = elementName(child);
    if (tag === 'formalParameter') {
      formalParameters.push(parseInformationItem(child));
    } else {
      const parsed = parseExpressionBody(child, tag);
      if (parsed !== null) {
        body = parsed;
      }
    }
  }

  const rawKind = attr(node, 'kind') ?? 'FEEL';
  const kind = rawKind.toUpperCase() === 'FEEL' ? 'FEEL' : rawKind;

  return {
    id: attr(node, 'id'),
    kind,
    formalParameters,
    body,
  };
}

function parseExpressionBody(node: OrderedNode, tag: string | null): DmnExpressionBody | null {
  switch (tag) {
    case 'decisionTable':
      return parseDecisionTable(node);
    case 'literalExpression':
      return parseLiteralExpression(node);
    case 'context':
      return parseBoxedContext(node);
    case 'invocation':
      return parseBoxedInvocation(node);
    case 'list':
      return parseBoxedList(node);
    case 'relation':
      return parseRelation(node);
    case 'functionDefinition':
      return parseFunctionDefinition(node);
    case 'conditional':
      return parseBoxedConditional(node);
    case 'filter':
      return parseBoxedFilter(node);
    case 'for':
      return parseBoxedFor(node);
    case 'every':
      return parseBoxedEvery(node);
    case 'some':
      return parseBoxedSome(node);
    default:
      return null;
  }
}

function firstExpressionBodyInChildren(parent: OrderedNode): DmnExpressionBody | null {
  for (const child of children(parent)) {
    const tag = elementName(child);
    const parsed = parseExpressionBody(child, tag);
    if (parsed !== null) {
      return parsed;
    }
  }
  return null;
}

function parseBoxedContext(node: OrderedNode): DmnBoxedContext {
  const contextEntries: DmnContextEntry[] = [];

  for (const child of children(node)) {
    if (elementName(child) === 'contextEntry') {
      contextEntries.push(parseContextEntry(child));
    }
  }

  return {
    id: attr(node, 'id'),
    contextEntries,
  };
}

function parseContextEntry(node: OrderedNode): DmnContextEntry {
  let variable: DmnInformationItem | null = null;
  let expression: DmnExpressionBody | null = null;

  for (const child of children(node)) {
    const tag = elementName(child);
    if (tag === 'variable') {
      variable = parseInformationItem(child);
    } else {
      const parsed = parseExpressionBody(child, tag);
      if (parsed !== null) {
        expression = parsed;
      }
    }
  }

  return { variable, expression };
}

function parseBoxedInvocation(node: OrderedNode): DmnBoxedInvocation {
  let calledFunction = '';
  const bindings: DmnBinding[] = [];
  let foundCalledFunction = false;

  for (const child of children(node)) {
    const tag = elementName(child);
    if (tag === 'binding') {
      bindings.push(parseBinding(child));
    } else {
      const parsed = parseExpressionBody(child, tag);
      if (parsed !== null && !foundCalledFunction) {
        foundCalledFunction = true;
        if ('text' in parsed && typeof parsed.text === 'string') {
          calledFunction = parsed.text;
        }
      }
    }
  }

  return {
    id: attr(node, 'id'),
    calledFunction,
    bindings,
  };
}

function parseBinding(node: OrderedNode): DmnBinding {
  let parameter: DmnInformationItem | null = null;
  let expression: DmnExpressionBody | null = null;

  for (const child of children(node)) {
    const tag = elementName(child);
    if (tag === 'parameter') {
      parameter = parseInformationItem(child);
    } else {
      const parsed = parseExpressionBody(child, tag);
      if (parsed !== null) {
        expression = parsed;
      }
    }
  }

  return { parameter, expression };
}

function parseBoxedList(node: OrderedNode): DmnBoxedList {
  const elements: DmnExpressionBody[] = [];

  for (const child of children(node)) {
    const tag = elementName(child);
    const parsed = parseExpressionBody(child, tag);
    if (parsed !== null) {
      elements.push(parsed);
    }
  }

  return {
    id: attr(node, 'id'),
    elements,
  };
}

function parseRelation(node: OrderedNode): DmnRelation {
  const columns: DmnInformationItem[] = [];
  const rows: DmnExpressionBody[][] = [];

  for (const child of children(node)) {
    const tag = elementName(child);
    if (tag === 'column') {
      columns.push(parseInformationItem(child));
    } else if (tag === 'row') {
      const cells: DmnExpressionBody[] = [];
      for (const rowChild of children(child)) {
        const rowChildTag = elementName(rowChild);
        const parsed = parseExpressionBody(rowChild, rowChildTag);
        if (parsed !== null) {
          cells.push(parsed);
        }
      }
      rows.push(cells);
    }
  }

  return {
    id: attr(node, 'id'),
    columns,
    rows,
  };
}

function parseBoxedConditional(node: OrderedNode): DmnBoxedConditional {
  let ifExpression: DmnExpressionBody | null = null;
  let thenExpression: DmnExpressionBody | null = null;
  let elseExpression: DmnExpressionBody | null = null;

  for (const child of children(node)) {
    const tag = elementName(child);
    if (tag === 'if') {
      ifExpression = firstExpressionBodyInChildren(child);
    } else if (tag === 'then') {
      thenExpression = firstExpressionBodyInChildren(child);
    } else if (tag === 'else') {
      elseExpression = firstExpressionBodyInChildren(child);
    }
  }

  return {
    id: attr(node, 'id'),
    ifExpression,
    thenExpression,
    elseExpression,
  };
}

function parseBoxedFilter(node: OrderedNode): DmnBoxedFilter {
  let inExpression: DmnExpressionBody | null = null;
  let matchExpression: DmnExpressionBody | null = null;

  for (const child of children(node)) {
    const tag = elementName(child);
    if (tag === 'in') {
      inExpression = firstExpressionBodyInChildren(child);
    } else if (tag === 'match') {
      matchExpression = firstExpressionBodyInChildren(child);
    }
  }

  return {
    id: attr(node, 'id'),
    inExpression,
    matchExpression,
  };
}

function parseBoxedFor(node: OrderedNode): DmnBoxedFor {
  let inExpression: DmnExpressionBody | null = null;
  let returnExpression: DmnExpressionBody | null = null;

  for (const child of children(node)) {
    const tag = elementName(child);
    if (tag === 'in') {
      inExpression = firstExpressionBodyInChildren(child);
    } else if (tag === 'return') {
      returnExpression = firstExpressionBodyInChildren(child);
    }
  }

  return {
    id: attr(node, 'id'),
    iteratorVariable: attr(node, 'iteratorVariable') ?? '',
    inExpression,
    returnExpression,
  };
}

function parseBoxedEvery(node: OrderedNode): DmnBoxedEvery {
  let inExpression: DmnExpressionBody | null = null;
  let satisfiesExpression: DmnExpressionBody | null = null;

  for (const child of children(node)) {
    const tag = elementName(child);
    if (tag === 'in') {
      inExpression = firstExpressionBodyInChildren(child);
    } else if (tag === 'satisfies') {
      satisfiesExpression = firstExpressionBodyInChildren(child);
    }
  }

  return {
    id: attr(node, 'id'),
    iteratorVariable: attr(node, 'iteratorVariable') ?? '',
    inExpression,
    satisfiesExpression,
  };
}

function parseBoxedSome(node: OrderedNode): DmnBoxedSome {
  let inExpression: DmnExpressionBody | null = null;
  let satisfiesExpression: DmnExpressionBody | null = null;

  for (const child of children(node)) {
    const tag = elementName(child);
    if (tag === 'in') {
      inExpression = firstExpressionBodyInChildren(child);
    } else if (tag === 'satisfies') {
      satisfiesExpression = firstExpressionBodyInChildren(child);
    }
  }

  return {
    id: attr(node, 'id'),
    iteratorVariable: attr(node, 'iteratorVariable') ?? '',
    inExpression,
    satisfiesExpression,
  };
}

function parseDecisionService(node: OrderedNode): DmnDecisionService {
  const outputDecisions: string[] = [];
  const encapsulatedDecisions: string[] = [];
  const inputDecisions: string[] = [];
  const inputData: string[] = [];

  for (const child of children(node)) {
    const tag = elementName(child);
    const href = fragmentIdFromHref(attr(child, 'href'));
    if (href === null) {
      continue;
    }
    switch (tag) {
      case 'outputDecision':
        outputDecisions.push(href);
        break;
      case 'encapsulatedDecision':
        encapsulatedDecisions.push(href);
        break;
      case 'inputDecision':
        inputDecisions.push(href);
        break;
      case 'inputData':
        inputData.push(href);
        break;
      default:
        break;
    }
  }

  return {
    id: attr(node, 'id') ?? '',
    name: attr(node, 'name'),
    outputDecisions,
    encapsulatedDecisions,
    inputDecisions,
    inputData,
  };
}

function parseDMNDI(node: OrderedNode): DmnDI {
  const diagrams: DmnDiagram[] = [];

  for (const child of children(node)) {
    if (elementName(child) === 'DMNDiagram') {
      diagrams.push(parseDMNDiagram(child));
    }
  }

  return { diagrams };
}

function parseDMNDiagram(node: OrderedNode): DmnDiagram {
  const shapes: DmnShape[] = [];
  const edges: DmnEdge[] = [];

  for (const child of children(node)) {
    const tag = elementName(child);
    if (tag === 'DMNShape') {
      shapes.push(parseDMNShape(child));
    } else if (tag === 'DMNEdge') {
      edges.push(parseDMNEdge(child));
    }
  }

  return {
    id: attr(node, 'id'),
    name: attr(node, 'name'),
    shapes,
    edges,
  };
}

function parseDMNShape(node: OrderedNode): DmnShape {
  const boundsNode = findElement(children(node), 'Bounds');
  const defaultBounds: DmnBounds = { x: 0, y: 0, width: 0, height: 0 };

  return {
    id: attr(node, 'id'),
    dmnElementRef: attr(node, 'dmnElementRef') ?? '',
    bounds: boundsNode ? parseBounds(boundsNode) : defaultBounds,
  };
}

function parseDMNEdge(node: OrderedNode): DmnEdge {
  const waypoints: DmnPoint[] = [];

  for (const child of children(node)) {
    if (elementName(child) === 'waypoint') {
      waypoints.push(parseWaypoint(child));
    }
  }

  return {
    id: attr(node, 'id'),
    dmnElementRef: attr(node, 'dmnElementRef') ?? '',
    waypoints,
  };
}

function parseBounds(node: OrderedNode): DmnBounds {
  return {
    x: parseFloatAttribute(node, 'x'),
    y: parseFloatAttribute(node, 'y'),
    width: parseFloatAttribute(node, 'width'),
    height: parseFloatAttribute(node, 'height'),
  };
}

function parseWaypoint(node: OrderedNode): DmnPoint {
  return {
    x: parseFloatAttribute(node, 'x'),
    y: parseFloatAttribute(node, 'y'),
  };
}

function parseFloatAttribute(node: OrderedNode, attributeName: string): number {
  const raw = attr(node, attributeName);
  if (raw === null || raw === '') {
    return 0;
  }
  const value = Number.parseFloat(raw);
  return Number.isNaN(value) ? 0 : value;
}

function parseKnowledgeRequirement(node: OrderedNode): DmnKnowledgeRequirement {
  const kidList = children(node);
  const requiredKnowledgeNode = findElement(kidList, 'requiredKnowledge');
  const href = requiredKnowledgeNode ? attr(requiredKnowledgeNode, 'href') : null;
  const requiredKnowledgeId = fragmentIdFromHref(href) ?? '';

  return {
    id: attr(node, 'id'),
    requiredKnowledgeId,
  };
}

function parseKnowledgeSource(node: OrderedNode): DmnKnowledgeSource {
  const kidList = children(node);
  const authorityRequirements: DmnAuthorityRequirement[] = [];

  for (const child of kidList) {
    const tag = elementName(child);
    if (tag === 'authorityRequirement') {
      authorityRequirements.push(parseAuthorityRequirement(child));
    }
  }

  return {
    id: attr(node, 'id') ?? '',
    name: attr(node, 'name'),
    type: attr(node, 'type'),
    authorityRequirements,
  };
}

function parseAuthorityRequirement(node: OrderedNode): DmnAuthorityRequirement {
  const kidList = children(node);
  const requiredAuthorityNode = findElement(kidList, 'requiredAuthority');
  const requiredDecisionNode = findElement(kidList, 'requiredDecision');
  const requiredInputNode = findElement(kidList, 'requiredInput');

  return {
    id: attr(node, 'id'),
    requiredAuthorityId: fragmentIdFromHref(requiredAuthorityNode ? attr(requiredAuthorityNode, 'href') : null),
    requiredDecisionId: fragmentIdFromHref(requiredDecisionNode ? attr(requiredDecisionNode, 'href') : null),
    requiredInputId: fragmentIdFromHref(requiredInputNode ? attr(requiredInputNode, 'href') : null),
  };
}

function parseItemDefinition(node: OrderedNode): DmnItemDefinition {
  const kidList = children(node);
  let typeRef: string | null = null;
  let allowedValues: string | null = null;
  const itemComponents: DmnItemDefinition[] = [];

  for (const child of kidList) {
    const tag = elementName(child);
    switch (tag) {
      case 'typeRef': {
        const text = textContent(child);
        typeRef = text !== '' ? text : null;
        break;
      }
      case 'allowedValues': {
        const text = textContent(child);
        allowedValues = text !== '' ? text : null;
        break;
      }
      case 'itemComponent':
        itemComponents.push(parseItemDefinition(child));
        break;
      default:
        break;
    }
  }

  return {
    id: attr(node, 'id') ?? '',
    name: attr(node, 'name') ?? '',
    typeRef,
    allowedValues,
    itemComponents,
    isCollection: parseIsCollection(attr(node, 'isCollection')),
  };
}

function parseIsCollection(raw: string | null): boolean {
  if (raw === null || raw === '') {
    return false;
  }
  const normalized = raw.trim().toLowerCase();
  return normalized === 'true' || normalized === '1';
}

function parseImport(node: OrderedNode): DmnImport {
  const locationUri = attr(node, 'locationURI') ?? attr(node, 'locationUri');

  return {
    id: attr(node, 'id'),
    namespace: attr(node, 'namespace') ?? '',
    locationUri,
    importType: attr(node, 'importType') ?? '',
  };
}

function parseInformationItem(node: OrderedNode): DmnInformationItem {
  return {
    id: attr(node, 'id'),
    name: attr(node, 'name') ?? '',
    typeRef: attr(node, 'typeRef'),
  };
}

function fragmentIdFromHref(href: string | null): string | null {
  if (href === null || href === '') {
    return null;
  }
  const trimmed = href.trim();
  if (trimmed.startsWith('#')) {
    return trimmed.slice(1);
  }
  return trimmed;
}
