import { describe, it, expect } from 'vitest';
import { resolveToken } from '../../src/identity/resolve-token.js';

describe('resolveToken', () => {
  it('returns a static string token as-is', async () => {
    const token = await resolveToken('my-jwt-token');
    expect(token).toBe('my-jwt-token');
  });

  it('calls a synchronous factory function and returns its result', async () => {
    const factory = () => 'sync-token';
    const token = await resolveToken(factory);
    expect(token).toBe('sync-token');
  });

  it('calls an async factory function and awaits its result', async () => {
    const factory = async () => 'async-token';
    const token = await resolveToken(factory);
    expect(token).toBe('async-token');
  });

  it('calls the factory on every invocation (no caching)', async () => {
    let counter = 0;
    const factory = () => {
      counter += 1;
      return `token-${String(counter)}`;
    };

    expect(await resolveToken(factory)).toBe('token-1');
    expect(await resolveToken(factory)).toBe('token-2');
    expect(await resolveToken(factory)).toBe('token-3');
    expect(counter).toBe(3);
  });

  it('handles a factory that returns a Promise', async () => {
    const factory = () => Promise.resolve('promise-token');
    const token = await resolveToken(factory);
    expect(token).toBe('promise-token');
  });
});
