import type {
  EscalationTriggerResult,
  MessageTriggerResult,
  SignalTriggerResult,
  TimerTriggerResult,
  TriggerOptions,
} from '@elraptorus/bfw_engine_sdk';

import type { HttpTransport } from '../http/transport.js';

/**
 * REST sub-client for message, signal, timer, and escalation triggering.
 *
 * - Messages: `POST /messages/{messageName}/trigger`
 * - Signals: `POST /signals/{signalName}/trigger`
 * - Timers: `POST /timer-events/{flowNodeInstanceId}/trigger`
 * - Escalations: `POST /escalations/{escalationCode}/trigger`
 *
 * Named `EventClient` (not `TriggerClient`) to accommodate future
 * BPMN event operations (compensation).
 */
export class EventClient {
  constructor(private readonly transport: HttpTransport) {}

  /**
   * Trigger a named message event.
   * Auth claim required: `trigger_message`.
   */
  async triggerMessage(
    name: string,
    payload: Record<string, unknown>,
    options?: TriggerOptions,
  ): Promise<MessageTriggerResult> {
    return this.transport.post<MessageTriggerResult>(`/messages/${encodeURIComponent(name)}/trigger`, {
      payload,
      correlation: options?.correlation,
    });
  }

  /**
   * Trigger a named signal event.
   * Auth claim required: `trigger_signal`.
   *
   * Signals carry no payload — any `payload` in the request body is
   * silently ignored by the engine (consistent with general API
   * behavior of cherry-picking known fields).
   */
  async triggerSignal(name: string): Promise<SignalTriggerResult> {
    return this.transport.post<SignalTriggerResult>(`/signals/${encodeURIComponent(name)}/trigger`, {});
  }

  /**
   * Manually trigger a waiting timer event (intermediate catch or boundary).
   *
   * Lane access is enforced by the engine — the caller must hold the
   * `lane:<laneName>` claim for the FNI's lane (or `zeeky_boogie_doog`
   * admin override).
   */
  async triggerTimer(flowNodeInstanceId: string): Promise<TimerTriggerResult> {
    return this.transport.post<TimerTriggerResult>(
      `/timer-events/${encodeURIComponent(flowNodeInstanceId)}/trigger`,
      {},
    );
  }

  /**
   * Inject a named escalation into waiting catchers engine-wide.
   * Auth claim required: `trigger_escalation`.
   *
   * Escalations carry no payload — any `payload` in the request body is
   * silently ignored by the engine.
   */
  async triggerEscalation(escalationCode: string): Promise<EscalationTriggerResult> {
    return this.transport.post<EscalationTriggerResult>(
      `/escalations/${encodeURIComponent(escalationCode)}/trigger`,
      {},
    );
  }
}
