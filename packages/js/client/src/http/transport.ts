import { mapResponseError } from '../errors/error-mapper.js';
import { resolveToken } from '../identity/resolve-token.js';
import type { JwtFactory } from '../identity/types.js';

/** Options for individual HTTP requests. */
export interface RequestOptions {
  /** Skip JWT injection (for unauthenticated endpoints like /health). */
  skipAuth?: boolean;
  /** Additional HTTP headers to include in the request. */
  headers?: Record<string, string>;
}

/**
 * Shared HTTP transport layer handling auth header injection and error mapping.
 * All sub-clients receive a shared instance. Error construction is delegated
 * entirely to the `ErrorMapper` — the transport never instantiates errors directly.
 *
 * Uses the native `fetch` API (Node 21+, stable in Node 24 LTS target).
 */
export class HttpTransport {
  constructor(
    private readonly baseUrl: string,
    private readonly jwtFactory: JwtFactory,
  ) {}

  /** GET request returning parsed JSON. */
  async get<T>(path: string, options?: RequestOptions): Promise<T> {
    const headers = await this.buildHeaders(options);
    const response = await fetch(`${this.baseUrl}${path}`, { headers });
    return this.handleResponse<T>(response);
  }

  /** GET request returning raw text (for non-JSON endpoints like /metrics). Returns `null` on 404. */
  async getText(path: string, options?: RequestOptions): Promise<string | null> {
    const headers = await this.buildHeaders(options);
    const response = await fetch(`${this.baseUrl}${path}`, { headers });
    if (response.status === 404) {
      return null;
    }
    if (!response.ok) {
      const body = await response.json().catch(() => ({ error: 'unknown' }));
      throw mapResponseError(response.status, body as Record<string, unknown>);
    }
    return response.text();
  }

  /** POST request with JSON body. */
  async post<T>(path: string, body?: unknown, options?: RequestOptions): Promise<T> {
    const headers = await this.buildHeaders(options);
    headers['Content-Type'] = 'application/json';
    const fetchOptions: RequestInit = { method: 'POST', headers };
    if (body !== undefined) {
      fetchOptions.body = JSON.stringify(body);
    }
    const response = await fetch(`${this.baseUrl}${path}`, fetchOptions);
    return this.handleResponse<T>(response);
  }

  /** PUT request with optional JSON body. */
  async put(path: string, body?: unknown, options?: RequestOptions): Promise<void> {
    const headers = await this.buildHeaders(options);
    const fetchOptions: RequestInit = { method: 'PUT', headers };
    if (body !== undefined) {
      headers['Content-Type'] = 'application/json';
      fetchOptions.body = JSON.stringify(body);
    }
    const response = await fetch(`${this.baseUrl}${path}`, fetchOptions);
    await this.handleResponse<void>(response);
  }

  /** DELETE request. */
  async delete(path: string, options?: RequestOptions): Promise<void> {
    const headers = await this.buildHeaders(options);
    const response = await fetch(`${this.baseUrl}${path}`, {
      method: 'DELETE',
      headers,
    });
    await this.handleResponse<void>(response);
  }

  /**
   * HEAD request. Resolves if the server returns a 2xx status, rejects otherwise.
   * Used for lightweight liveness probes where no response body is needed.
   */
  async head(path: string, options?: RequestOptions & { expect?: number }): Promise<void> {
    const headers = await this.buildHeaders(options);
    const response = await fetch(`${this.baseUrl}${path}`, {
      method: 'HEAD',
      headers,
    });
    if (options?.expect !== undefined && response.status !== options.expect) {
      throw mapResponseError(response.status, { error: 'unexpected_status' });
    }
    if (!response.ok) {
      throw mapResponseError(response.status, { error: 'unknown' });
    }
  }

  private async buildHeaders(options?: RequestOptions): Promise<Record<string, string>> {
    const headers: Record<string, string> = {};
    if (!options?.skipAuth) {
      const token = await resolveToken(this.jwtFactory);
      headers['Authorization'] = `Bearer ${token}`;
    }
    if (options?.headers) {
      Object.assign(headers, options.headers);
    }
    return headers;
  }

  private async handleResponse<T>(response: Response): Promise<T> {
    if (!response.ok) {
      const body = await response.json().catch(() => ({ error: 'unknown' }));
      throw mapResponseError(response.status, body as Record<string, unknown>);
    }
    if (response.status === 204) {
      return undefined as T;
    }
    return response.json() as Promise<T>;
  }
}
