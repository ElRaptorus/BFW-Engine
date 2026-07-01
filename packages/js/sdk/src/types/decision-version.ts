/**
 * A deployed version of a DMN decision definition.
 *
 * Each `DecisionDefinition` can have multiple versions deployed over time.
 */
export interface DecisionVersion {
  /** Internal UUID primary key. */
  id: string;
  /** UUID of the parent DecisionDefinition this version belongs to. */
  decisionDefinitionId: string;
  /** Deployment version string. */
  version: string;
  /** ISO 8601 timestamp when this version was deployed. */
  deployedAt: string;
  /** Raw DMN XML of this version. Only populated when explicitly requested. */
  dmnXml?: string | null;
  /** Identity of the user/system that deployed this version. */
  deployer?: Record<string, unknown> | null;
}
