/**
 * A single form field definition as stored in the BPMN model and served
 * via `typeProperties.form_fields` on waiting user task FNIs.
 *
 * Field keys use the exact casing authored in the Studio — they are inside
 * the opaque `typeProperties` envelope and are NOT camelCased by the engine.
 */
export interface FormFieldDefinition {
  id: string;
  type: FormFieldType;
  label: string;
  required: boolean;
  placeholder?: string;
  /** The string the Studio form builder writes; checkbox and toggle use `"true"` / `"false"`. */
  defaultValue?: string;
  options?: FormFieldOption[];
  validationRules?: FormFieldValidationRule[];
  /** Help text shown with the field. */
  hint?: string;
}

/** Supported form field types. */
export type FormFieldType =
  'text' | 'number' | 'date' | 'checkbox' | 'dropdown' | 'radio' | 'textarea' | 'file' | 'toggle' | 'section_header';

/** A selectable option for dropdown, radio, and checkbox group fields. */
export interface FormFieldOption {
  label: string;
  value: string;
}

/**
 * A validation rule attached to a form field.
 *
 * Known rule `pattern`: `value` is a regular expression the whole input must
 * match; `message` is shown on failure.
 */
export interface FormFieldValidationRule {
  type: string;
  value?: unknown;
  message?: string;
}

/**
 * What a form action does when pressed.
 *
 * Mirrors the Studio's `FormModel.ts`, which is the authority for this shape.
 * The Engine stores the JSON and does not interpret it.
 *
 * - `submit` — the client calls `userTasks.finish` with `{ actionId, values }`.
 * - `abort` — the client calls `userTasks.cancel`, which aborts the process instance tree.
 * - `dismiss` — the client makes no Engine call.
 */
export type FormActionEffect = 'submit' | 'dismiss' | 'abort';

/**
 * A form action button definition as stored in the BPMN model and served
 * via `typeProperties.form_actions` on waiting user task FNIs.
 *
 * Mirrors the Studio's `FormModel.ts`, which is the authority for this shape.
 * Keys use the exact casing authored in the Studio — they are inside
 * the opaque `typeProperties` envelope and are NOT camelCased by the engine.
 */
export interface FormAction {
  id: string;
  label: string;
  preset: FormActionPreset;
  effect: FormActionEffect;
  /** Only meaningful for `submit`: collect field values without required or pattern validation. */
  skipsValidation?: boolean;
  isDefault?: boolean;
  /** Styling only. Independent of `effect`. */
  isDanger?: boolean;
}

/** Known action presets. */
export type FormActionPreset = 'confirm' | 'cancel' | 'ok' | 'yes' | 'no' | 'abort' | 'custom';

/**
 * The shape of `typeProperties` for a user task FNI in the `waiting` state.
 *
 * All keys inside `typeProperties` remain snake_case on the wire because
 * `typeProperties` is an opaque payload envelope.
 */
export interface UserTaskTypeProperties {
  form_fields: FormFieldDefinition[] | null;
  form_actions: FormAction[] | null;
  assignees: string[] | null;
  result_contract: Record<string, unknown> | null;
  due_date: string | null;
  priority: number | null;
}
