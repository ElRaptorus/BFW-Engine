import type { DeployResponse, ProcessModel, StartRequest, StartResult } from '@elraptorus/daemonengine_sdk';

import type { HttpTransport } from '../http/transport.js';

/**
 * REST sub-client for `GET/POST/PUT/DELETE /processes/*` — deployment,
 * catalog, and process lifecycle operations.
 */
export class ProcessClient {
  constructor(private readonly transport: HttpTransport) {}

  /** List all deployed process models. Returns the latest active version of each. */
  async getAll(): Promise<ProcessModel[]> {
    return this.transport.get<ProcessModel[]>('/processes');
  }

  /**
   * Get process model details by BPMN process ID.
   * Returns the latest version by default.
   * @param id - The BPMN process ID (ProcessModel.id).
   * @param options.includeXml - If true, includes the BPMN XML.
   */
  async get(id: string, options?: { includeXml?: boolean }): Promise<ProcessModel> {
    const encodedId = encodeURIComponent(id);
    const query = options?.includeXml ? '?includeXml=true' : '';
    return this.transport.get<ProcessModel>(`/processes/${encodedId}${query}`);
  }

  /**
   * List all deployed versions of a process.
   * @param id - The BPMN process ID (ProcessModel.id).
   * @param options.includeXml - If true, includes each version's BPMN XML.
   */
  async getVersions(id: string, options?: { includeXml?: boolean }): Promise<ProcessModel[]> {
    const encodedId = encodeURIComponent(id);
    const query = options?.includeXml ? '?includeXml=true' : '';
    return this.transport.get<ProcessModel[]>(`/processes/${encodedId}/versions${query}`);
  }

  /**
   * Deploy one or more BPMN processes to the engine.
   *
   * Accepts a single BPMN XML string or an array of XML strings.
   * All sources are parsed, validated, and persisted in one atomic transaction.
   * If any source fails validation, the entire batch is rejected.
   *
   * @param sources - A single BPMN XML string, or an array of BPMN XML strings.
   */
  async deploy(sources: string | string[]): Promise<DeployResponse> {
    const normalizedSources = Array.isArray(sources) ? sources : [sources];
    return this.transport.post<DeployResponse>('/processes', { sources: normalizedSources });
  }

  /**
   * Start a new process instance.
   * @param id - The BPMN process ID (ProcessModel.id).
   * @param options - Optional start event ID, payload, and business key.
   */
  async start(id: string, options?: StartRequest): Promise<StartResult> {
    const encodedId = encodeURIComponent(id);
    return this.transport.post<StartResult>(`/processes/${encodedId}/start`, options);
  }

  /** Enable a process, allowing new instances to be started. */
  async enable(id: string): Promise<void> {
    const encodedId = encodeURIComponent(id);
    await this.transport.put(`/processes/${encodedId}/enable`);
  }

  /** Disable a process, preventing new instances from being started. */
  async disable(id: string): Promise<void> {
    const encodedId = encodeURIComponent(id);
    await this.transport.put(`/processes/${encodedId}/disable`);
  }

  /**
   * Undeploy a process by deleting all its versions.
   * Running instances on existing versions continue unaffected.
   */
  async undeploy(id: string): Promise<void> {
    const encodedId = encodeURIComponent(id);
    await this.transport.delete(`/processes/${encodedId}`);
  }

  /** Delete a specific process version. */
  async deleteVersion(id: string, version: string): Promise<void> {
    const encodedId = encodeURIComponent(id);
    const encodedVersion = encodeURIComponent(version);
    await this.transport.delete(`/processes/${encodedId}/versions/${encodedVersion}`);
  }
}
