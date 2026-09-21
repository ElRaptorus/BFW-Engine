import type { EngineEventEnvelope } from '@elraptorus/bfw_engine_sdk';
import { Socket } from 'phoenix';
import type { Channel, MessageRef } from 'phoenix';

import { resolveToken } from '../identity/resolve-token.js';
import type { JwtFactory } from '../identity/types.js';

/**
 * Returned by subscription methods. Call `dispose()` to unsubscribe.
 * The object shape leaves room for future metadata (subscription ID,
 * channel info, reconnect state, etc.).
 */
export interface Subscription {
  dispose(): void;
}

export type SocketOpenCallback = () => void;
export type SocketCloseCallback = (event: CloseEvent) => void;
export type SocketErrorCallback = (
  error: Event | string | number,
  transport: new (endpoint: string) => object,
  establishedConnections: number,
) => void;

/**
 * WebSocket client wrapping Phoenix Channel protocol for real-time
 * engine event notifications. Uses the official `phoenix` npm package.
 *
 * Call {@link connect} before subscribing to any events.
 * Call {@link dispose} (or {@link disconnect}) to clean up all channels.
 *
 * Lifecycle callbacks registered via {@link onSocketOpen}, {@link onSocketClose},
 * and {@link onSocketError} survive reconnects — they are re-attached to the
 * new Socket instance on every {@link connect} call.
 */
export class NotificationClient {
  private socket: Socket | null = null;
  private channels: Map<string, Channel> = new Map();

  private openCallbacks: Set<SocketOpenCallback> = new Set();
  private closeCallbacks: Set<SocketCloseCallback> = new Set();
  private errorCallbacks: Set<SocketErrorCallback> = new Set();
  private socketRefs: MessageRef[] = [];

  constructor(
    private readonly wsUrl: string,
    private readonly jwtFactory: JwtFactory,
  ) {}

  private static readonly DEFAULT_CONNECT_TIMEOUT_MS = 10_000;

  /**
   * Resolve the JWT, open the WebSocket connection, and wait for
   * the socket to be fully open before resolving.
   *
   * @param timeoutMs - Maximum time in milliseconds to wait for the
   *   socket to open. Defaults to 10 000 ms. Pass `0` or `Infinity`
   *   to wait indefinitely (not recommended).
   */
  async connect(timeoutMs?: number): Promise<void> {
    const effectiveTimeout = timeoutMs === undefined ? NotificationClient.DEFAULT_CONNECT_TIMEOUT_MS : timeoutMs;

    const token = await resolveToken(this.jwtFactory);
    this.socket = new Socket(this.wsUrl, { params: { token } });
    this.attachLifecycleCallbacks();

    return new Promise<void>((resolve, reject) => {
      const socket = this.socket!;
      let timer: ReturnType<typeof setTimeout> | null = null;

      const settle = (outcome: 'open' | 'error' | 'timeout') => {
        if (timer !== null) {
          clearTimeout(timer);
          timer = null;
        }
        socket.off([openRef, errorRef]);

        if (outcome === 'open') {
          resolve();
        } else if (outcome === 'timeout') {
          reject(new Error(`WebSocket connection timed out after ${String(effectiveTimeout)} ms`));
        } else {
          reject(new Error('WebSocket connection failed'));
        }
      };

      const openRef = socket.onOpen(() => settle('open'));
      const errorRef = socket.onError(() => settle('error'));

      if (effectiveTimeout > 0 && effectiveTimeout < Infinity) {
        timer = setTimeout(() => settle('timeout'), effectiveTimeout);
      }

      socket.connect();
    });
  }

  get connected(): boolean {
    return this.socket?.isConnected() ?? false;
  }

  /**
   * Register a callback invoked whenever the underlying Phoenix Socket opens.
   * The callback persists across `connect()` calls (new Socket instances).
   */
  onSocketOpen(callback: SocketOpenCallback): Subscription {
    this.openCallbacks.add(callback);
    return {
      dispose: () => {
        this.openCallbacks.delete(callback);
      },
    };
  }

  /**
   * Register a callback invoked whenever the underlying Phoenix Socket closes.
   * Fires on both intentional disconnects and unexpected connection loss.
   * The callback persists across `connect()` calls.
   */
  onSocketClose(callback: SocketCloseCallback): Subscription {
    this.closeCallbacks.add(callback);
    return {
      dispose: () => {
        this.closeCallbacks.delete(callback);
      },
    };
  }

  /**
   * Register a callback invoked whenever the underlying Phoenix Socket
   * encounters a transport error. The callback persists across
   * `connect()` calls.
   */
  onSocketError(callback: SocketErrorCallback): Subscription {
    this.errorCallbacks.add(callback);
    return {
      dispose: () => {
        this.errorCallbacks.delete(callback);
      },
    };
  }

  /**
   * Subscribe to all engine-wide events on the `engine:events` channel.
   * @param handler - Called for every engine event received.
   * @returns A subscription whose `dispose()` removes only this listener.
   */
  async onEngineEvent(handler: (event: EngineEventEnvelope) => void): Promise<Subscription> {
    const channel = await this.joinChannel('engine:events');
    const ref = channel.on('engine_event', handler);
    return {
      dispose: () => {
        channel.off('engine_event', ref);
      },
    };
  }

  /**
   * Subscribe to events scoped to a single process instance.
   * @param processInstanceId - The process instance UUID to observe.
   * @param handler - Called for every event on this instance's channel.
   * @returns A subscription whose `dispose()` removes the listener and leaves the channel.
   */
  async subscribeProcessInstance(
    processInstanceId: string,
    handler: (event: EngineEventEnvelope) => void,
  ): Promise<Subscription> {
    const topic = `process_instance:${processInstanceId}`;
    const channel = await this.joinChannel(topic);
    const ref = channel.on('engine_event', handler);
    return {
      dispose: () => {
        channel.off('engine_event', ref);
        channel.leave();
        this.channels.delete(topic);
      },
    };
  }

  /**
   * Subscribe to pending user-task inbox events on `user_tasks:pending`.
   * Delivers `UserTaskCreated` and `UserTaskFinished` envelopes, filtered
   * by the subscriber's accessible lanes on the server.
   * @param handler - Called for every pending-task event received.
   * @returns A subscription whose `dispose()` removes only this listener.
   */
  async subscribePendingUserTasks(handler: (event: EngineEventEnvelope) => void): Promise<Subscription> {
    const channel = await this.joinChannel('user_tasks:pending');
    const ref = channel.on('engine_event', handler);
    return {
      dispose: () => {
        channel.off('engine_event', ref);
      },
    };
  }

  /** Close all channels and disconnect the underlying WebSocket. */
  disconnect(): void {
    for (const channel of this.channels.values()) {
      channel.leave();
    }
    this.channels.clear();
    this.socket?.disconnect();
    this.socketRefs = [];
    this.socket = null;
  }

  /**
   * Attach all stored lifecycle callbacks to the current Socket instance.
   * Called internally by `connect()` after creating a new Socket.
   */
  private attachLifecycleCallbacks(): void {
    if (!this.socket) {
      return;
    }

    this.socketRefs = [];

    for (const callback of this.openCallbacks) {
      this.socketRefs.push(this.socket.onOpen(callback));
    }
    for (const callback of this.closeCallbacks) {
      this.socketRefs.push(this.socket.onClose(callback));
    }
    for (const callback of this.errorCallbacks) {
      this.socketRefs.push(this.socket.onError(callback));
    }
  }

  private async joinChannel(topic: string): Promise<Channel> {
    const existing = this.channels.get(topic);
    if (existing) {
      return existing;
    }

    if (!this.socket) {
      throw new Error('NotificationClient is not connected. Call connect() first.');
    }

    const channel = this.socket.channel(topic);
    this.channels.set(topic, channel);

    return new Promise<Channel>((resolve, reject) => {
      channel
        .join()
        .receive('ok', () => resolve(channel))
        .receive('error', (response: unknown) =>
          reject(new Error(`Failed to join channel ${topic}: ${JSON.stringify(response)}`)),
        )
        .receive('timeout', () => reject(new Error(`Timeout joining channel ${topic}`)));
    });
  }
}
