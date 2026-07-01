/** Request body for `POST /processes`. */
export interface DeployRequest {
  /** One or more BPMN XML strings to deploy atomically. */
  sources: string[];
}

/** A single successfully deployed process model. */
export interface DeployResult {
  /** BPMN process ID. */
  processModelId: string;
  /** The version string from `evil:version`. */
  version: string;
}

/** Response body for `POST /processes`. */
export interface DeployResponse {
  /** All processes that were deployed in this batch. */
  deployed: DeployResult[];
}
