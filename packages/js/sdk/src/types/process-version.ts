/**
 * A deployed version of a BPMN process model.
 *
 * Each `ProcessModel` can have multiple versions deployed over time.
 * The `version` field holds the `bfw:version` string from the BPMN XML.
 */
export interface ProcessVersion {
  /** Internal UUID primary key. */
  id: string;
  /** UUID of the parent Process this version belongs to. */
  processId: string;
  /** Deployment version string (`bfw:version` from the BPMN XML). */
  version: string;
  /** BPMN `<definitions id="...">` identifier. */
  definitionsId?: string | null;
  /** ISO 8601 timestamp when this version was deployed. */
  deployedAt: string;
  /** Raw BPMN XML of this version. Only populated when explicitly requested. */
  bpmnXml?: string | null;
  /** Identity of the user/system that deployed this version. */
  deployer?: Record<string, unknown> | null;
}
