import type { Identity } from '../types/identity.js';

/** Handler interface for auth provider plugins (Phase 2 item 11). */
export interface AuthProviderHandler {
  verifyAndResolve(token: string): Promise<Identity>;
}
