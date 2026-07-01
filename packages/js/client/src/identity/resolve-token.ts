import type { JwtFactory } from './types.js';

/** Resolve a JWT factory to a concrete token string. */
export async function resolveToken(factory: JwtFactory): Promise<string> {
  if (typeof factory === 'string') {
    return factory;
  }
  return await factory();
}
