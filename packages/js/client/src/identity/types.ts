/**
 * A JWT factory is either a static token string or a function that
 * produces one (synchronously or asynchronously). The client calls
 * the factory before every request so the token can be refreshed.
 */
export type JwtFactory = string | (() => string | Promise<string>);
