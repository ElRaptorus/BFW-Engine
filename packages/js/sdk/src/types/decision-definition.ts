import type { DecisionVersion } from './decision-version.js';

/**
 * A deployed DMN decision definition.
 *
 * REST responses use the DMN definitions ID as `id` and include version/deployment
 * fields directly. GraphQL responses use the internal UUID as `id` and expose
 * the DMN definitions ID separately as `decisionDefinitionId`. Fields marked as
 * REST-only or GraphQL-only are optional to accommodate both wire formats.
 */
export interface DecisionDefinition {
  /** Internal UUID primary key (GraphQL `id`). In REST responses this is the DMN definitions ID instead. */
  id: string;
  /** DMN `<definitions id="...">` string identifier. Only present in GraphQL responses. */
  decisionDefinitionId?: string;
  /** Human-readable name from the DMN `name` attribute. */
  name: string | null;
  /** Whether evaluation requests are accepted for this definition. */
  enabled: boolean;
  /** ISO 8601 timestamp when the Ash resource was created. */
  createdAt?: string;
  /** Deployment version string (`evil:version`). REST-only. */
  version?: string;
  /** ISO 8601 timestamp when this version was deployed. REST-only. */
  deployedAt?: string;
  /** Identity snapshot of the deployer. REST-only. */
  deployer?: Record<string, unknown> | null;
  /** Raw DMN XML, included when requested via `?includeXml=true`. REST-only. */
  dmnXml?: string;
  /** Populated when loaded via GraphQL `include: { versions }`. */
  versions?: DecisionVersion[];
}
