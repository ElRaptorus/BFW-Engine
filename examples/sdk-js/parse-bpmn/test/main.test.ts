import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { describe, expect, it } from 'vitest';

import { FlowNodeType, parseBpmn } from '@elraptorus/daemonengine_sdk';

const sourceDirectoryPath = dirname(fileURLToPath(import.meta.url));
const sampleFilePath = join(sourceDirectoryPath, '..', 'bpmn', 'sample.bpmn');

describe('parse-bpmn sample', () => {
  it('parses the bundled BPMN into the expected structure', () => {
    const xmlString = readFileSync(sampleFilePath, 'utf8');
    const model = parseBpmn(xmlString);

    expect(model.processes.length).toBe(1);

    const firstProcess = model.processes[0];
    expect(firstProcess).toBeDefined();
    expect(firstProcess!.flowNodes.length).toBe(8);

    const reviewTask = firstProcess!.flowNodes.find((flowNode) => flowNode.id === 'UserTask_review');
    expect(reviewTask).toBeDefined();
    expect(reviewTask!.type).toBe(FlowNodeType.UserTask);
    expect(reviewTask!.typeData.type).toBe('user_task');
  });
});
