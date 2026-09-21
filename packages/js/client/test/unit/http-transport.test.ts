import { describe, it, expect, vi, beforeEach } from 'vitest';
import { HttpTransport } from '../../src/http/transport.js';
import { UnauthorizedError, NotFoundError, BfwEngineError } from '@elraptorus/bfw_engine_sdk';

function mockFetch(
  status: number,
  body: unknown = {},
  options?: { headers?: Headers; text?: string },
): void {
  const response = {
    ok: status >= 200 && status < 300,
    status,
    json: vi.fn().mockResolvedValue(body),
    text: vi.fn().mockResolvedValue(options?.text ?? JSON.stringify(body)),
    headers: options?.headers ?? new Headers(),
  } as unknown as Response;

  vi.spyOn(globalThis, 'fetch').mockResolvedValue(response);
}

function mockFetchJsonError(): void {
  const response = {
    ok: false,
    status: 500,
    json: vi.fn().mockRejectedValue(new Error('not json')),
    text: vi.fn().mockResolvedValue('Internal Server Error'),
    headers: new Headers(),
  } as unknown as Response;

  vi.spyOn(globalThis, 'fetch').mockResolvedValue(response);
}

describe('HttpTransport', () => {
  let transport: HttpTransport;

  beforeEach(() => {
    vi.restoreAllMocks();
    transport = new HttpTransport('http://localhost:4000', 'test-jwt');
  });

  describe('get', () => {
    it('sends a GET request with Authorization header', async () => {
      mockFetch(200, { id: '1' });
      const result = await transport.get<{ id: string }>('/processes');

      expect(fetch).toHaveBeenCalledWith('http://localhost:4000/processes', {
        headers: { Authorization: 'Bearer test-jwt' },
      });
      expect(result).toEqual({ id: '1' });
    });

    it('skips auth header when skipAuth is true', async () => {
      mockFetch(200, { version: '1.0' });
      await transport.get('/info', { skipAuth: true });

      expect(fetch).toHaveBeenCalledWith('http://localhost:4000/info', {
        headers: {},
      });
    });

    it('throws a typed error on non-ok response', async () => {
      mockFetch(401, { error: 'unauthorized', message: 'Bad token' });
      await expect(transport.get('/processes')).rejects.toThrow(UnauthorizedError);
    });

    it('returns undefined for 204 responses', async () => {
      mockFetch(204);
      const result = await transport.get('/something');
      expect(result).toBeUndefined();
    });
  });

  describe('getText', () => {
    it('returns response text on success', async () => {
      mockFetch(200, {}, { text: 'prometheus_metrics 42' });
      const result = await transport.getText('/metrics', { skipAuth: true });
      expect(result).toBe('prometheus_metrics 42');
    });

    it('returns null on 404', async () => {
      mockFetch(404, { error: 'not_found' });
      const result = await transport.getText('/metrics', { skipAuth: true });
      expect(result).toBeNull();
    });

    it('throws on non-404 errors', async () => {
      mockFetch(500, { error: 'internal_error', message: 'Boom' });
      await expect(transport.getText('/metrics')).rejects.toThrow();
    });
  });

  describe('post', () => {
    it('sends a POST request with JSON body', async () => {
      mockFetch(200, { id: 'pi-1' });
      const body = { initialToken: { orderId: '123' } };
      await transport.post('/processes/order/start', body);

      expect(fetch).toHaveBeenCalledWith(
        'http://localhost:4000/processes/order/start',
        expect.objectContaining({
          method: 'POST',
          headers: {
            Authorization: 'Bearer test-jwt',
            'Content-Type': 'application/json',
          },
        }),
      );

      const callArgs = vi.mocked(fetch).mock.calls[0]!;
      const requestInit = callArgs[1] as RequestInit;
      expect(requestInit.body).toBe(JSON.stringify(body));
    });

    it('sends a POST without body when body is undefined', async () => {
      mockFetch(200, {});
      await transport.post('/processes/order/start');

      const callArgs = vi.mocked(fetch).mock.calls[0]!;
      const requestInit = callArgs[1] as RequestInit;
      expect(requestInit.body).toBeUndefined();
    });
  });

  describe('put', () => {
    it('sends a PUT request with optional body', async () => {
      mockFetch(204);
      await transport.put('/processes/order/enable');

      expect(fetch).toHaveBeenCalledWith(
        'http://localhost:4000/processes/order/enable',
        expect.objectContaining({ method: 'PUT' }),
      );
    });

    it('throws on error responses', async () => {
      mockFetch(404, { error: 'process_not_found', message: 'Not found' });
      await expect(transport.put('/processes/unknown/enable')).rejects.toThrow();
    });
  });

  describe('delete', () => {
    it('sends a DELETE request', async () => {
      mockFetch(204);
      await transport.delete('/processes/order');

      expect(fetch).toHaveBeenCalledWith(
        'http://localhost:4000/processes/order',
        expect.objectContaining({ method: 'DELETE' }),
      );
    });
  });

  describe('head', () => {
    it('sends a HEAD request and resolves on expected status', async () => {
      mockFetch(204);
      await expect(
        transport.head('/health', { skipAuth: true, expect: 204 }),
      ).resolves.toBeUndefined();
    });

    it('throws when actual status does not match expected', async () => {
      mockFetch(503);
      await expect(
        transport.head('/health', { skipAuth: true, expect: 204 }),
      ).rejects.toThrow(BfwEngineError);
    });
  });

  describe('auth with factory function', () => {
    it('calls the JWT factory before each request', async () => {
      const factory = vi.fn().mockResolvedValue('dynamic-token');
      const dynamicTransport = new HttpTransport('http://localhost:4000', factory);

      mockFetch(200, {});
      await dynamicTransport.get('/processes');

      expect(factory).toHaveBeenCalledOnce();
      expect(fetch).toHaveBeenCalledWith(
        'http://localhost:4000/processes',
        expect.objectContaining({
          headers: { Authorization: 'Bearer dynamic-token' },
        }),
      );
    });
  });

  describe('error body parsing fallback', () => {
    it('falls back to unknown error when response body is not JSON', async () => {
      mockFetchJsonError();
      await expect(transport.get('/processes')).rejects.toThrow(BfwEngineError);
    });
  });
});
