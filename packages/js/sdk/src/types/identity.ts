/**
 * Well-known engine claims with index signature for custom ones.
 * `deploy_bpmn` and `delete_bpmn` are enforced by Ash policies on
 * Process and ProcessVersion resources (S-1 resolution, 2026-05-07).
 * The `zeeky_boogie_doog` claim provides a full bypass on all resource
 * actions via a custom Ash policy check.
 */
export interface IdentityClaims {
  deploy_bpmn?: boolean;
  delete_bpmn?: boolean;
  abort_process_instance?: 'none' | 'own' | 'all';
  delete_process_instance?: 'none' | 'own' | 'all';
  retry_process_instance?: 'none' | 'own' | 'all';
  purge_audit_data?: boolean;
  trigger_message?: 'none' | 'all';
  trigger_signal?: 'none' | 'all';
  trigger_escalation?: boolean;
  zeeky_boogie_doog?: boolean;
  /** Unbounded read/observe. Never grants write. */
  observe_all?: boolean;
  /**
   * Lane access. Keys are `lane:<name>`; values must be `"read"` or `"write"`.
   * Boolean `true` is rejected (fail closed).
   */
  [customClaim: string]: unknown;
}

/** The authenticated caller's identity as resolved from the JWT. */
export interface Identity {
  /** Unique user identifier from the JWT subject claim. */
  id: string;
  /** Roles assigned to this identity. */
  roles: string[];
  /** Groups this identity belongs to. */
  groups: string[];
  /** Well-known and custom claims extracted from the JWT. */
  claims: IdentityClaims;
}
