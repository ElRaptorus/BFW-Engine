/** Handler interface for REST API extension plugins. */
export interface RestApiExtensionHandler {
  /** URL prefix under which this extension's routes are mounted. */
  prefix: string;
}
