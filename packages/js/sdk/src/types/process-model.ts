import type { ProcessVersion } from './process-version.js';

/**
 * A deployed BPMN process model.
 *
 * REST responses use the BPMN process ID as `id` and include version/deployment
 * fields directly. GraphQL responses use the internal UUID as `id` and expose
 * the BPMN process ID separately as `processModelId`. Fields marked as
 * REST-only or GraphQL-only are optional to accommodate both wire formats.
 */
export interface ProcessModel {
  /** Internal UUID primary key (GraphQL `id`). In REST responses this is the BPMN process ID instead. */
  id: string;
  /** BPMN `<process id="...">` string identifier. Only present in GraphQL responses. */
  processModelId?: string;
  /** BPMN `<definitions id="...">` — groups processes from the same file. REST-only. */
  definitionsId?: string;
  /** Internal UUID of the ProcessVersion row. Present in REST listing, detail, and version-list responses. */
  versionId?: string;
  /** Deployment version string (`evil:version`). REST-only (use ProcessVersion in GraphQL). */
  version?: string;
  /** Human-readable name from the BPMN `name` attribute. */
  name: string | null;
  /** Whether new instances can be started on this version. */
  enabled: boolean;
  /** ISO 8601 timestamp when the Ash resource was created. */
  createdAt?: string;
  /** ISO 8601 timestamp when this version was deployed. REST-only. */
  deployedAt?: string;
  /** Identity snapshot of the deployer. REST-only. */
  deployer?: Record<string, unknown> | null;
  /** Raw BPMN XML, included when requested via `?includeXml=true`. REST-only. */
  bpmnXml?: string;
  /** Populated when loaded via GraphQL `include: { versions }`. */
  versions?: ProcessVersion[];
}
