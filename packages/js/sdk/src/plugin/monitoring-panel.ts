/**
 * Handler interface for monitoring panel plugins.
 *
 * Not implemented in v1. `registerMonitoringPanel` is accepted and unused at
 * runtime — there is no admin UI to host panels.
 */
export interface MonitoringPanelHandler {
  panelTitle(): string;
  render(assigns: Record<string, unknown>): string;
}
