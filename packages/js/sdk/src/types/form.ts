/**
 * A single form field definition as stored in the BPMN model and served
 * via `typeProperties.form_schema` on waiting user task FNIs.
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
  defaultValue?: unknown;
  options?: FormFieldOption[];
  validationRules?: FormFieldValidationRule[];
}

/** Supported form field types. */
export type FormFieldType =
  'text' | 'number' | 'date' | 'checkbox' | 'dropdown' | 'radio' | 'textarea' | 'file' | 'toggle' | 'section_header';

/** A selectable option for dropdown and radio fields. */
export interface FormFieldOption {
  label: string;
  value: string;
}

/** A validation rule attached to a form field. */
export interface FormFieldValidationRule {
  type: string;
  value?: unknown;
  message?: string;
}

/**
 * A form action button definition as stored in the BPMN model and served
 * via `typeProperties.form_actions` on waiting user task FNIs.
 *
 * Keys use the exact casing authored in the Studio — they are inside
 * the opaque `typeProperties` envelope and are NOT camelCased by the engine.
 */
export interface FormActionDefinition {
  id: string;
  label: string;
  preset: FormActionPreset;
  submitsForm: boolean;
  isDefault: boolean;
  isDanger?: boolean;
  actionId?: string;
}

/** Known action presets. */
export type FormActionPreset = 'confirm' | 'cancel' | 'ok' | 'yes' | 'no' | 'custom';

/**
 * The shape of `typeProperties` for a user task FNI in the `waiting` state.
 *
 * All keys inside `typeProperties` remain snake_case on the wire because
 * `typeProperties` is an opaque payload envelope.
 */
export interface UserTaskTypeProperties {
  form_schema: FormFieldDefinition[] | null;
  form_actions: FormActionDefinition[] | null;
  assignees: string[] | null;
  result_contract: Record<string, unknown> | null;
  due_date: string | null;
  priority: number | null;
}
