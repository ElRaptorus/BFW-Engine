import type { PluginCapabilityType } from '../types/enums.js';
import type { EngineFacade } from './engine-facade.js';

/** Lifecycle interface that all plugins must implement. */
export interface Plugin {
  /** Called when the engine loads the plugin. Register capabilities here. */
  onLoad(facade: EngineFacade): Promise<void>;
  /** Called after all plugins have been loaded and the engine is ready. */
  onReady(facade: EngineFacade): Promise<void>;
}

/**
 * Read-only plugin manifest returned by introspection APIs.
 * The engine builds this from the registrations made during onLoad;
 * plugin authors do NOT construct it manually.
 */
export interface PluginDescriptor {
  name: string;
  version: string;
  capabilities: PluginCapabilitySummary[];
}

/**
 * Read-only capability summary for introspection / /stats.
 * Produced by the engine, not by plugin authors.
 */
export interface PluginCapabilitySummary {
  type: PluginCapabilityType;
  metadata: Record<string, unknown>;
}
