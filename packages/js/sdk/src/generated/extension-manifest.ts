// GENERATED FILE — do not edit by hand.
//
// The JSON payload (`extension-manifest.json`, in this same directory) is
// written by `mix bfw.gen.extension_manifest` from
// `BfwEngine.BPMN.ExtensionManifest` (Phase 6.1, WP-5). This wrapper adds
// the TypeScript types the Studio's moddle-conformance check (§4.6 of the
// plan) and other consumers need — it is hand-written once and does not
// change shape unless the manifest schema itself changes.
//
// `mix bfw.gen.extension_manifest --check` is the CI diff-guard: it fails
// if this JSON drifts from `BfwEngine.BPMN.ExtensionManifest`.
import extensionManifestJson from './extension-manifest.json' with { type: 'json' };

/** How the extension element's text/attribute value should be interpreted. */
export type ExtensionValueKind = 'feel' | 'json_schema' | 'static_string' | 'integer' | 'boolean' | 'mapping';

/** Whether the value is carried in the element's body text or its XML attributes. */
export type ExtensionCarrier = 'body' | 'attributes';

/**
 * One `bfw:*` extension element the Engine's parser
 * (`BfwEngine.BPMN.Parser.SaxHandler`) reads.
 */
export interface ExtensionManifestEntry {
  /** The `bfw:*` element name as written in XML (e.g. `httpUrl`). */
  element: string;
  valueKind: ExtensionValueKind;
  carrier: ExtensionCarrier;
  /** For `carrier: 'attributes'`, the attribute names (empty otherwise). */
  attributes: string[];
  /** BPMN element types the parser reads this extension on. */
  applicableTo: string[];
  /** The Elixir struct field this extension populates, for traceability. */
  modelField: string;
}

export interface ExtensionManifest {
  elements: ExtensionManifestEntry[];
  /**
   * Generic containers whose instance data the Engine does not interpret
   * (`Properties`, `Property` — the bag holding Studio-only values such as
   * `studio.examplePayload`). Conformance checks should exempt these from
   * the "every descriptor type appears in the manifest" direction.
   */
  extensible: string[];
}

interface RawEntry {
  element: string;
  value_kind: ExtensionValueKind;
  carrier: ExtensionCarrier;
  attributes: string[];
  applicable_to: string[];
  model_field: string;
}

interface RawManifest {
  elements: RawEntry[];
  extensible: string[];
}

function toCamelCase(raw: RawManifest): ExtensionManifest {
  return {
    elements: raw.elements.map((entry) => ({
      element: entry.element,
      valueKind: entry.value_kind,
      carrier: entry.carrier,
      attributes: entry.attributes,
      applicableTo: entry.applicable_to,
      modelField: entry.model_field,
    })),
    extensible: raw.extensible,
  };
}

/** The Engine's `bfw:*` extension vocabulary, typed and camelCased. */
export const extensionManifest: ExtensionManifest = toCamelCase(extensionManifestJson as RawManifest);
