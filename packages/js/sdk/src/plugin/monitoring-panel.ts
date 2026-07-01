/** Handler interface for monitoring panel plugins. */
export interface MonitoringPanelHandler {
  panelTitle(): string;
  render(assigns: Record<string, unknown>): string;
}
