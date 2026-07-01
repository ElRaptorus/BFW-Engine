import type {
  DecisionDefinition,
  DmnDeployResponse,
  DmnServiceEvaluationResult,
  EvaluateDecisionRequest,
  EvaluateServiceRequest,
  EvaluationResult,
} from '@elraptorus/daemonengine_sdk';

import type { HttpTransport } from '../http/transport.js';

/**
 * REST sub-client for `GET/POST/PUT/DELETE /decisions/*` — DMN deployment,
 * catalog, and ad-hoc decision evaluation.
 */
export class DecisionClient {
  constructor(private readonly transport: HttpTransport) {}

  /** List all deployed decision definitions. Returns the latest active version of each. */
  async getAll(): Promise<DecisionDefinition[]> {
    return this.transport.get<DecisionDefinition[]>('/decisions');
  }

  /**
   * Get decision definition details by DMN definitions ID.
   * @param id - The DMN definitions ID (DecisionDefinition.id).
   * @param options.includeXml - If true, includes the DMN XML.
   */
  async get(id: string, options?: { includeXml?: boolean }): Promise<DecisionDefinition> {
    const encodedId = encodeURIComponent(id);
    const query = options?.includeXml ? '?includeXml=true' : '';
    return this.transport.get<DecisionDefinition>(`/decisions/${encodedId}${query}`);
  }

  /**
   * List all deployed versions of a decision definition.
   * @param id - The DMN definitions ID (DecisionDefinition.id).
   * @param options.includeXml - If true, includes each version's DMN XML.
   */
  async getVersions(id: string, options?: { includeXml?: boolean }): Promise<DecisionDefinition[]> {
    const encodedId = encodeURIComponent(id);
    const query = options?.includeXml ? '?includeXml=true' : '';
    return this.transport.get<DecisionDefinition[]>(`/decisions/${encodedId}/versions${query}`);
  }

  /**
   * Deploy one or more DMN decision definitions to the engine.
   *
   * Accepts a single DMN XML string or an array of XML strings.
   * All sources are parsed, validated, and persisted in one atomic transaction.
   * If any source fails validation, the entire batch is rejected.
   */
  async deploy(sources: string | string[]): Promise<DmnDeployResponse> {
    const normalizedSources = Array.isArray(sources) ? sources : [sources];
    return this.transport.post<DmnDeployResponse>('/decisions', { sources: normalizedSources });
  }

  /** Enable a decision definition, allowing evaluation requests. */
  async enable(id: string): Promise<void> {
    const encodedId = encodeURIComponent(id);
    await this.transport.put(`/decisions/${encodedId}/enable`);
  }

  /** Disable a decision definition, blocking evaluation requests. */
  async disable(id: string): Promise<void> {
    const encodedId = encodeURIComponent(id);
    await this.transport.put(`/decisions/${encodedId}/disable`);
  }

  /** Undeploy a decision definition by deleting all its versions. */
  async undeploy(id: string): Promise<void> {
    const encodedId = encodeURIComponent(id);
    await this.transport.delete(`/decisions/${encodedId}`);
  }

  /** Delete a specific decision definition version. */
  async deleteVersion(id: string, version: string): Promise<void> {
    const encodedId = encodeURIComponent(id);
    const encodedVersion = encodeURIComponent(version);
    await this.transport.delete(`/decisions/${encodedId}/versions/${encodedVersion}`);
  }

  /**
   * Evaluate a decision table using the latest active version.
   *
   * @param id - The DMN definitions ID.
   * @param input - Input variables for the decision table.
   * @param options.decisionModelId - Target a specific decision within the definitions.
   * @param options.includeUnmatchedDetails - Include per-cell detail for unmatched rules in the trace.
   */
  async evaluate(
    id: string,
    input: Record<string, unknown>,
    options?: { decisionModelId?: string; includeUnmatchedDetails?: boolean },
  ): Promise<EvaluationResult> {
    const encodedId = encodeURIComponent(id);
    const body: EvaluateDecisionRequest = { input };
    if (options?.decisionModelId !== undefined) {
      body.decisionModelId = options.decisionModelId;
    }
    if (options?.includeUnmatchedDetails !== undefined) {
      body.includeUnmatchedDetails = options.includeUnmatchedDetails;
    }
    return this.transport.post<EvaluationResult>(`/decisions/${encodedId}/evaluate`, body);
  }

  /**
   * Evaluate a decision table using a specific deployed version.
   *
   * Unlike {@link evaluate}, this bypasses the "latest version" resolution
   * and evaluates a pinned version directly. Useful for regression testing
   * and A/B comparison.
   *
   * @param id - The DMN definitions ID.
   * @param version - The version string to evaluate.
   * @param input - Input variables for the decision table.
   * @param options.decisionModelId - Target a specific decision within the definitions.
   * @param options.includeUnmatchedDetails - Include per-cell detail for unmatched rules in the trace.
   */
  async evaluateByVersion(
    id: string,
    version: string,
    input: Record<string, unknown>,
    options?: { decisionModelId?: string; includeUnmatchedDetails?: boolean },
  ): Promise<EvaluationResult> {
    const encodedId = encodeURIComponent(id);
    const encodedVersion = encodeURIComponent(version);
    const body: EvaluateDecisionRequest = { input };
    if (options?.decisionModelId !== undefined) {
      body.decisionModelId = options.decisionModelId;
    }
    if (options?.includeUnmatchedDetails !== undefined) {
      body.includeUnmatchedDetails = options.includeUnmatchedDetails;
    }
    return this.transport.post<EvaluationResult>(`/decisions/${encodedId}/versions/${encodedVersion}/evaluate`, body);
  }

  /**
   * Evaluate a Decision Service within a deployed DMN model.
   *
   * @param id - The DMN definitions ID.
   * @param serviceId - The ID of the Decision Service to evaluate.
   * @param input - Input variables for the Decision Service.
   * @param options.includeUnmatchedDetails - Include per-cell detail for unmatched rules in the trace.
   */
  async evaluateService(
    id: string,
    serviceId: string,
    input: Record<string, unknown>,
    options?: { includeUnmatchedDetails?: boolean },
  ): Promise<DmnServiceEvaluationResult> {
    const encodedId = encodeURIComponent(id);
    const encodedServiceId = encodeURIComponent(serviceId);
    const body: EvaluateServiceRequest = { input };
    if (options?.includeUnmatchedDetails !== undefined) {
      body.includeUnmatchedDetails = options.includeUnmatchedDetails;
    }
    return this.transport.post<DmnServiceEvaluationResult>(
      `/decisions/${encodedId}/services/${encodedServiceId}/evaluate`,
      body,
    );
  }
}
