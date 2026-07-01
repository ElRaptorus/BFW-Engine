import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when deploying a DMN version that already exists. */
export class DecisionVersionExistsError extends DaemonEngineError {
  constructor(
    message: string,
    public readonly conflicts: { decisionDefinitionId: string; version: string }[],
    rawBody?: Record<string, unknown>,
  ) {
    super(409, 'decision_version_exists', message, rawBody);
    this.name = 'DecisionVersionExistsError';
  }
}
