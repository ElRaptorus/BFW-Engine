import { describe, expect, it } from 'vitest';

import { extensionManifest } from '../../src/index.js';

describe('extensionManifest', () => {
  it('exposes a non-empty, camelCased element list', () => {
    expect(extensionManifest.elements.length).toBeGreaterThan(30);

    for (const entry of extensionManifest.elements) {
      expect(entry.element).toBeTypeOf('string');
      expect(entry.element.length).toBeGreaterThan(0);
      expect(['feel', 'json_schema', 'static_string', 'integer', 'boolean', 'mapping']).toContain(entry.valueKind);
      expect(['body', 'attributes']).toContain(entry.carrier);
      expect(Array.isArray(entry.attributes)).toBe(true);
      expect(Array.isArray(entry.applicableTo)).toBe(true);
      expect(entry.applicableTo.length).toBeGreaterThan(0);
      expect(entry.modelField).toBeTypeOf('string');

      // The wrapper camelCases the raw JSON's snake_case keys — assert the
      // snake_case shape did not leak through.
      expect(entry as Record<string, unknown>).not.toHaveProperty('value_kind');
      expect(entry as Record<string, unknown>).not.toHaveProperty('applicable_to');
      expect(entry as Record<string, unknown>).not.toHaveProperty('model_field');
    }
  });

  it('has unique element names', () => {
    const names = extensionManifest.elements.map((entry) => entry.element);
    expect(new Set(names).size).toBe(names.length);
  });

  it('exposes the extensible container list', () => {
    expect(extensionManifest.extensible).toEqual(expect.arrayContaining(['Properties', 'Property']));
  });

  it('includes elements known to be exercised by the fixture corpus', () => {
    const names = new Set(extensionManifest.elements.map((entry) => entry.element));

    // Spot-check a representative element per BPMN element family (WP-0's
    // repaired surface) rather than the full 382-fixture corpus, which the
    // Elixir-side round-trip test (`extension_manifest_test.exs`) already covers.
    for (const expected of ['decisionRef', 'httpUrl', 'assignees', 'inputMapping', 'valueContract']) {
      expect(names.has(expected), `expected "${expected}" in the manifest`).toBe(true);
    }
  });
});
