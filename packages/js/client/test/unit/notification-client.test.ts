import { describe, it, expect, vi, beforeEach } from 'vitest';
import { NotificationClient } from '../../src/ws/notification-client.js';

let nextRef = 1;
let nextSocketRef = 100;

function createJoinChain() {
  const chain = {
    receive: vi.fn(),
  };
  chain.receive.mockImplementation((event: string, callback: (response?: unknown) => void) => {
    if (event === 'ok') {
      setTimeout(() => callback(), 0);
    }
    return chain;
  });
  return chain;
}

const mockChannel = {
  join: vi.fn(),
  on: vi.fn(() => nextRef++),
  off: vi.fn(),
  leave: vi.fn(),
};

const mockSocket = {
  connect: vi.fn(),
  disconnect: vi.fn(),
  channel: vi.fn().mockReturnValue(mockChannel),
  onOpen: vi.fn((callback: () => void) => {
    setTimeout(callback, 0);
    return String(nextSocketRef++);
  }),
  onClose: vi.fn(() => String(nextSocketRef++)),
  onError: vi.fn(() => String(nextSocketRef++)),
  off: vi.fn(),
};

vi.mock('phoenix', () => {
  return {
    Socket: class MockSocket {
      connect = mockSocket.connect;
      disconnect = mockSocket.disconnect;
      channel = mockSocket.channel;
      onOpen = mockSocket.onOpen;
      onClose = mockSocket.onClose;
      onError = mockSocket.onError;
      off = mockSocket.off;

      constructor(
        public url: string,
        public opts: { params: { token: string } },
      ) {
        mockSocket.__lastConstructorArgs = { url, opts };
      }

      static __lastConstructorArgs?: { url: string; opts: unknown };
    },
  };
});

declare module 'phoenix' {
  const __lastConstructorArgs: { url: string; opts: unknown } | undefined;
}

describe('NotificationClient', () => {
  let client: NotificationClient;

  beforeEach(() => {
    vi.clearAllMocks();
    nextRef = 1;
    nextSocketRef = 100;
    mockChannel.on.mockImplementation(() => nextRef++);
    mockChannel.join.mockReturnValue(createJoinChain());
    client = new NotificationClient('ws://localhost:4001/socket', 'test-jwt');
  });

  it('creates a Socket with the JWT token on connect', async () => {
    await client.connect();
    expect((mockSocket as Record<string, unknown>)['__lastConstructorArgs']).toEqual({
      url: 'ws://localhost:4001/socket',
      opts: { params: { token: 'test-jwt' } },
    });
  });

  it('calls socket.connect() on connect', async () => {
    await client.connect();
    expect(mockSocket.connect).toHaveBeenCalled();
  });

  it('rejects when subscribing before connecting', async () => {
    await expect(client.onEngineEvent(vi.fn())).rejects.toThrow('NotificationClient is not connected');
  });

  it('joins the engine:events channel on onEngineEvent', async () => {
    await client.connect();
    await client.onEngineEvent(vi.fn());
    expect(mockSocket.channel).toHaveBeenCalledWith('engine:events');
  });

  it('registers the handler on the channel', async () => {
    await client.connect();
    const handler = vi.fn();
    await client.onEngineEvent(handler);
    expect(mockChannel.on).toHaveBeenCalledWith('engine_event', handler);
  });

  it('dispose uses the ref returned by channel.on to remove only that listener', async () => {
    mockChannel.on.mockReturnValueOnce(42);
    await client.connect();
    const subscription = await client.onEngineEvent(vi.fn());
    subscription.dispose();
    expect(mockChannel.off).toHaveBeenCalledWith('engine_event', 42);
  });

  it('joins a process-instance-specific channel', async () => {
    await client.connect();
    await client.subscribeProcessInstance('pi-123', vi.fn());
    expect(mockSocket.channel).toHaveBeenCalledWith('process_instance:pi-123');
  });

  it('subscribeProcessInstance dispose uses ref and leaves the channel', async () => {
    mockChannel.on.mockReturnValueOnce(99);
    await client.connect();
    const subscription = await client.subscribeProcessInstance('pi-123', vi.fn());
    subscription.dispose();
    expect(mockChannel.off).toHaveBeenCalledWith('engine_event', 99);
    expect(mockChannel.leave).toHaveBeenCalled();
  });

  it('disconnect closes all channels and the socket', async () => {
    await client.connect();
    await client.onEngineEvent(vi.fn());
    client.disconnect();
    expect(mockChannel.leave).toHaveBeenCalled();
    expect(mockSocket.disconnect).toHaveBeenCalled();
  });

  it('reuses existing channel for the same topic', async () => {
    await client.connect();
    await client.onEngineEvent(vi.fn());
    await client.onEngineEvent(vi.fn());
    expect(mockSocket.channel).toHaveBeenCalledTimes(1);
  });

  it('resolves token from async factory on connect', async () => {
    let calls = 0;
    const factory = async () => {
      calls += 1;
      return `token-${String(calls)}`;
    };
    const asyncClient = new NotificationClient('ws://localhost:4001/socket', factory);
    await asyncClient.connect();
    expect((mockSocket as Record<string, unknown>)['__lastConstructorArgs']).toEqual({
      url: 'ws://localhost:4001/socket',
      opts: { params: { token: 'token-1' } },
    });
  });

  describe('socket lifecycle callbacks', () => {
    it('onSocketOpen registers callback on connect and fires it', async () => {
      const callback = vi.fn();
      client.onSocketOpen(callback);
      await client.connect();
      expect(mockSocket.onOpen).toHaveBeenCalledWith(callback);
    });

    it('onSocketClose registers callback on connect', async () => {
      const callback = vi.fn();
      client.onSocketClose(callback);
      await client.connect();
      expect(mockSocket.onClose).toHaveBeenCalledWith(callback);
    });

    it('onSocketError registers callback on connect', async () => {
      const callback = vi.fn();
      client.onSocketError(callback);
      await client.connect();
      expect(mockSocket.onError).toHaveBeenCalledWith(callback);
    });

    it('callbacks registered before connect are attached when connect is called', async () => {
      const openCallback = vi.fn();
      const closeCallback = vi.fn();
      const errorCallback = vi.fn();

      client.onSocketOpen(openCallback);
      client.onSocketClose(closeCallback);
      client.onSocketError(errorCallback);

      await client.connect();

      expect(mockSocket.onOpen).toHaveBeenCalledWith(openCallback);
      expect(mockSocket.onClose).toHaveBeenCalledWith(closeCallback);
      expect(mockSocket.onError).toHaveBeenCalledWith(errorCallback);
    });

    it('callbacks survive reconnect — re-attached on second connect()', async () => {
      const openCallback = vi.fn();
      client.onSocketOpen(openCallback);

      await client.connect();
      expect(mockSocket.onOpen).toHaveBeenCalledWith(openCallback);

      client.disconnect();
      vi.clearAllMocks();

      await client.connect();
      expect(mockSocket.onOpen).toHaveBeenCalledWith(openCallback);
    });

    it('dispose removes callback so it is not re-attached on next connect', async () => {
      const openCallback = vi.fn();
      const subscription = client.onSocketOpen(openCallback);

      await client.connect();
      expect(mockSocket.onOpen).toHaveBeenCalledWith(openCallback);

      subscription.dispose();
      client.disconnect();
      vi.clearAllMocks();

      await client.connect();
      expect(mockSocket.onOpen).not.toHaveBeenCalledWith(openCallback);
    });

    it('multiple callbacks of the same type are all registered', async () => {
      const callback1 = vi.fn();
      const callback2 = vi.fn();

      client.onSocketOpen(callback1);
      client.onSocketOpen(callback2);

      await client.connect();

      expect(mockSocket.onOpen).toHaveBeenCalledWith(callback1);
      expect(mockSocket.onOpen).toHaveBeenCalledWith(callback2);
    });

    it('callbacks registered after connect are stored but not immediately attached', async () => {
      await client.connect();
      vi.clearAllMocks();

      const lateCallback = vi.fn();
      client.onSocketOpen(lateCallback);

      expect(mockSocket.onOpen).not.toHaveBeenCalled();

      client.disconnect();
      await client.connect();
      expect(mockSocket.onOpen).toHaveBeenCalledWith(lateCallback);
    });
  });
});
