export interface TimerSchedule {
  id: string;
  processModelId: string;
  processVersionId: string;
  flowNodeId: string;
  kind: string;
  isoSpec: string;
  enabled: boolean;
  nextFireAt: string | null;
  lastTriggeredAt: string | null;
  cycleTotal: number | null;
  cycleRemaining: number | null;
}
