/** Request body for `POST /decisions`. */
export interface DmnDeployRequest {
  sources: string[];
}

/** A single deployment result within a `DmnDeployResponse`. */
export interface DmnDeployResult {
  decisionDefinitionId: string;
  version: string;
}

/** Response from `POST /decisions`. */
export interface DmnDeployResponse {
  deployed: DmnDeployResult[];
}
