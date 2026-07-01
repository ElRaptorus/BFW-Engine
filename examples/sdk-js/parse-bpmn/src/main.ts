import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import type { BpmnDefinitions, BpmnProcess, EventDefinition, FlowNode, SequenceFlow } from '@elraptorus/daemonengine_sdk';
import { FlowNodeType, parseBpmn } from '@elraptorus/daemonengine_sdk';

function formatEventDefinition(eventDefinition: EventDefinition): string {
  switch (eventDefinition.type) {
    case 'message':
      return `message (messageRef=${eventDefinition.messageRef ?? 'null'}, correlation=${eventDefinition.correlationRetrievalExpression ?? '—'})`;
    case 'timer':
      return `timer (timeDuration=${eventDefinition.timeDuration ?? 'null'}, timeDate=${eventDefinition.timeDate ?? 'null'}, timeCycle=${eventDefinition.timeCycle ?? 'null'})`;
    case 'error':
      return `error (errorRef=${eventDefinition.errorRef ?? 'null'}, errorCode=${eventDefinition.errorCode ?? 'null'})`;
    case 'none':
      return 'none';
    default:
      return eventDefinition.type;
  }
}

function formatFlowNodeDetails(flowNode: FlowNode): string {
  const data = flowNode.typeData;
  switch (data.type) {
    case 'start_event':
    case 'end_event':
    case 'intermediate_catch_event':
    case 'intermediate_throw_event':
    case 'boundary_event':
      return formatEventDefinition(data.eventDefinition);
    case 'user_task': {
      return `assigneesExpression=${data.assigneesExpression ?? 'null'}`;
    }
    case 'service_task': {
      return `implementation=${data.implementation ?? 'null'}, serviceTaskTypeConfig=${JSON.stringify(data.serviceTaskTypeConfig)}`;
    }
    case 'manual_task':
      return `requireConfirmation=${data.requireConfirmation}`;
    case 'exclusive_gateway':
      return `defaultFlowRef=${data.defaultFlowRef ?? 'null'}`;
    default:
      return `typeData.type=${data.type}`;
  }
}

function printGlobalDefinitions(model: BpmnDefinitions, indent: string): void {
  console.log(`${indent}messages`);
  for (const messageDefinition of model.messages) {
    console.log(`${indent}  - ${messageDefinition.id} (name=${messageDefinition.name ?? 'null'})`);
  }
  console.log(`${indent}signals`);
  for (const signalDefinition of model.signals) {
    console.log(`${indent}  - ${signalDefinition.id} (name=${signalDefinition.name ?? 'null'})`);
  }
  console.log(`${indent}errors`);
  for (const errorDefinition of model.errors) {
    console.log(
      `${indent}  - ${errorDefinition.id} (name=${errorDefinition.name ?? 'null'}, errorCode=${errorDefinition.errorCode ?? 'null'})`,
    );
  }
}

function printExtensionTree(extensions: BpmnProcess['extensions'], indent: string): void {
  if (extensions.length === 0) {
    console.log(
      `${indent}(no nested Extension records; parser lifts evil:version and evil:correlationKey onto the process object)`,
    );
    return;
  }
  function walk(extensionList: typeof extensions, depth: string): void {
    for (const extension of extensionList) {
      console.log(`${depth}- ${extension.key}=${extension.value ?? 'null'} attrs=${JSON.stringify(extension.attributes)}`);
      if (extension.children.length > 0) {
        walk(extension.children, `${depth}  `);
      }
    }
  }
  walk(extensions, `${indent}`);
}

function printSequenceFlow(sequenceFlow: SequenceFlow, indent: string): void {
  const conditionPart =
    sequenceFlow.conditionExpression !== null ? ` [condition: ${sequenceFlow.conditionExpression}]` : '';
  const defaultPart = sequenceFlow.isDefault ? ' (default)' : '';
  console.log(
    `${indent}${sequenceFlow.id}: ${sequenceFlow.sourceRef} → ${sequenceFlow.targetRef}${conditionPart}${defaultPart}`,
  );
}

function printProcessTree(process: BpmnProcess, indent: string): void {
  console.log(`${indent}process id=${process.id} name=${process.name ?? 'null'}`);
  console.log(`${indent}  executable=${process.isExecutable}`);
  console.log(`${indent}  evil:version → version=${process.version ?? 'null'}`);
  console.log(`${indent}  evil:correlationKey → correlationKey=${process.correlationKey ?? 'null'}`);
  console.log(`${indent}  extensionElements tree`);
  printExtensionTree(process.extensions, `${indent}    `);
  console.log(`${indent}  flowNodes (${process.flowNodes.length})`);
  for (const flowNode of process.flowNodes) {
    console.log(
      `${indent}    - ${flowNode.type} id=${flowNode.id} name=${flowNode.name ?? 'null'} | ${formatFlowNodeDetails(flowNode)}`,
    );
  }
  console.log(`${indent}  sequenceFlows (${process.sequenceFlows.length})`);
  for (const sequenceFlow of process.sequenceFlows) {
    printSequenceFlow(sequenceFlow, `${indent}    `);
  }
}

export async function main(): Promise<void> {
  const sourceDirectoryPath = dirname(fileURLToPath(import.meta.url));
  const sampleFilePath = join(sourceDirectoryPath, '..', 'bpmn', 'sample.bpmn');
  const xmlString = readFileSync(sampleFilePath, 'utf8');
  const model = parseBpmn(xmlString);

  console.log(`definitionsId=${model.definitionsId ?? 'null'}`);
  printGlobalDefinitions(model, '');
  console.log(`processes (${model.processes.length})`);
  for (const process of model.processes) {
    printProcessTree(process, '  ');
  }
}

main().catch(console.error);
