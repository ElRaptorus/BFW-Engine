import type { FlowNodeType } from './enums.js';

/** Describes an inner activity within an ad-hoc subprocess. */
export interface AdHocActivity {
  id: string;
  name: string | null;
  type: FlowNodeType;
  enabled: boolean;
  performedCount: number;
  activeCount: number;
}

/** Result of activating an activity in an ad-hoc subprocess. */
export interface AdHocActivateResult {
  flowNodeInstanceId: string;
}

/** Runtime status of an ad-hoc subprocess. */
export interface AdHocStatus {
  activeCount: number;
  performedActivities: string[];
  enabledActivities: string[];
  completionSignaled: boolean;
}

/** Result of signaling ad-hoc subprocess completion. */
export interface AdHocCompleteResult {
  completed: boolean;
}
