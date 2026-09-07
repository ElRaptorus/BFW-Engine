import type { PaginationOptions, SelectionField, SortClause } from '@elraptorus/daemonengine_sdk';

/**
 * Builds a GraphQL query string and variables object for a list or
 * single-record query. This is the internal query construction layer —
 * callers use the typed `GraphqlClient` methods instead.
 */

interface BuildListQueryParams {
  resourceName: string;
  /** The AshGraphql type prefix used for filter/sort input types (e.g. "ProcessInstance" → ProcessInstanceFilterInput). */
  ashTypeName: string;
  fields: SelectionField[];
  filter?: Record<string, unknown> | undefined;
  sort?: SortClause<string>[] | undefined;
  include?:
    Record<string, { fields: string[]; filter?: Record<string, unknown>; sort?: SortClause<string>[] }> | undefined;
  pagination?: PaginationOptions | undefined;
}

interface BuildGetQueryParams {
  resourceName: string;
  fields: SelectionField[];
  include?:
    Record<string, { fields: string[]; filter?: Record<string, unknown>; sort?: SortClause<string>[] }> | undefined;
}

interface BuiltQuery {
  query: string;
  variables: Record<string, unknown>;
  /** The actual GraphQL field name used in the query (needed for extracting data from the response). */
  getFieldName?: string;
}

export function buildListQuery(params: BuildListQueryParams): BuiltQuery {
  const { resourceName, ashTypeName, fields, filter, sort, include, pagination } = params;
  const variables: Record<string, unknown> = {};
  const variableDeclarations: string[] = [];
  const queryArguments: string[] = [];

  if (filter) {
    variables['filter'] = buildFilterInput(filter);
    variableDeclarations.push(`$filter: ${ashTypeName}FilterInput`);
    queryArguments.push('filter: $filter');
  }

  if (sort && sort.length > 0) {
    variables['sort'] = sort.map((clause) => ({
      field: toScreamingSnakeCase(clause.field),
      order: clause.direction.toUpperCase(),
    }));
    variableDeclarations.push(`$sort: [${ashTypeName}SortInput]`);
    queryArguments.push('sort: $sort');
  }

  if (pagination) {
    if (pagination.mode === 'cursor') {
      if (pagination.first !== undefined) {
        variables['first'] = pagination.first;
        variableDeclarations.push('$first: Int');
        queryArguments.push('first: $first');
      }
      if (pagination.after !== undefined) {
        variables['after'] = pagination.after;
        variableDeclarations.push('$after: String');
        queryArguments.push('after: $after');
      }
      if (pagination.last !== undefined) {
        variables['last'] = pagination.last;
        variableDeclarations.push('$last: Int');
        queryArguments.push('last: $last');
      }
      if (pagination.before !== undefined) {
        variables['before'] = pagination.before;
        variableDeclarations.push('$before: String');
        queryArguments.push('before: $before');
      }
    } else {
      variables['limit'] = pagination.limit;
      variableDeclarations.push('$limit: Int');
      queryArguments.push('limit: $limit');
      if (pagination.offset > 0) {
        variables['offset'] = pagination.offset;
        variableDeclarations.push('$offset: Int');
        queryArguments.push('offset: $offset');
      }
    }
  }

  const selectionSet = buildSelectionSet(fields, include);
  const varBlock = variableDeclarations.length > 0 ? `(${variableDeclarations.join(', ')})` : '';
  const argBlock = queryArguments.length > 0 ? `(${queryArguments.join(', ')})` : '';

  let pageMetaFields: string;
  if (pagination?.mode === 'cursor') {
    pageMetaFields = '\n    count\n    startKeyset\n    endKeyset';
  } else if (pagination?.mode === 'offset') {
    pageMetaFields = '\n    count\n    hasNextPage\n    hasPreviousPage\n    pageNumber\n    lastPage\n    limit';
  } else {
    pageMetaFields = '\n    count';
  }

  const query = `query ${capitalizeFirst(resourceName)}List${varBlock} {
  ${resourceName}${argBlock} {
    results {
${selectionSet}
    }${pageMetaFields}
  }
}`;

  return { query, variables };
}

export function buildGetQuery(id: string, params: BuildGetQueryParams): BuiltQuery {
  const { resourceName, fields, include } = params;
  const selectionSet = buildSelectionSet(fields, include);
  const getFieldName = `get${capitalizeFirst(resourceName)}`;

  const query = `query ${capitalizeFirst(resourceName)}Get($id: ID!) {
  ${getFieldName}(id: $id) {
${selectionSet}
  }
}`;

  return { query, variables: { id }, getFieldName };
}

function buildSelectionSet(
  fields: SelectionField[],
  include?: Record<string, { fields: string[]; filter?: Record<string, unknown>; sort?: SortClause<string>[] }>,
  indent: number = 6,
): string {
  const prefix = ' '.repeat(indent);
  const lines: string[] = fields.flatMap((field) => renderSelectionField(field, prefix));

  if (include) {
    for (const [relation, config] of Object.entries(include)) {
      const snakeRelation = toSnakeCase(relation);
      const nestedArgs = buildNestedIncludeArgs(config);
      const nestedFields = config.fields.map((field) => `${prefix}    ${toSnakeCase(field)}`);
      if (nestedFields.length === 0) {
        nestedFields.push(`${prefix}    __typename`);
      }
      const argSuffix = nestedArgs ? `(${nestedArgs})` : '';
      lines.push(`${prefix}${snakeRelation}${argSuffix} {`);
      lines.push(...nestedFields);
      lines.push(`${prefix}}`);
    }
  }

  return lines.join('\n');
}

/**
 * Renders a single `SelectionField` (see `@elraptorus/daemonengine_sdk`) —
 * either a bare scalar field name, or a nested object/interface/union field
 * with its own sub-selection and optional inline fragments (`... on Type`).
 * Used to render the polymorphic Model graph (`flowNode`, `eventDefinition`,
 * ...), where a flat `string[]` cannot express "these fields, plus these
 * extra fields only for concrete type X".
 */
function renderSelectionField(field: SelectionField, prefix: string): string[] {
  if (typeof field === 'string') {
    return [`${prefix}${toSnakeCase(field)}`];
  }

  const name = toSnakeCase(field.name);
  const body: string[] = [];

  for (const child of field.fields ?? []) {
    body.push(...renderSelectionField(child, `${prefix}  `));
  }

  if (field.on) {
    for (const [typeName, fragmentFields] of Object.entries(field.on)) {
      const fragmentBody: string[] = [];
      for (const fragmentField of fragmentFields) {
        fragmentBody.push(...renderSelectionField(fragmentField, `${prefix}    `));
      }
      // GraphQL forbids empty selection sets. Types whose extra-field list is
      // empty (TaskNode, ParallelGatewayNode, EventBasedGatewayNode) are
      // covered by the interface common fields — emitting `... on TaskNode { }`
      // is a syntax error (`syntax error before: '}'` in Absinthe).
      if (fragmentBody.length === 0) {
        continue;
      }
      body.push(`${prefix}  ... on ${typeName} {`, ...fragmentBody, `${prefix}  }`);
    }
  }

  if (body.length === 0) {
    // A nested field with no sub-selection is meaningless in GraphQL —
    // always request at least `__typename` so the query stays valid.
    body.push(`${prefix}  __typename`);
  }

  return [`${prefix}${name} {`, ...body, `${prefix}}`];
}

function buildNestedIncludeArgs(config: {
  fields: string[];
  filter?: Record<string, unknown>;
  sort?: SortClause<string>[];
}): string | null {
  const parts: string[] = [];

  if (config.filter) {
    const filterInput = buildFilterInput(config.filter);
    parts.push(`filter: ${inlineJson(filterInput)}`);
  }

  if (config.sort && config.sort.length > 0) {
    const sortInput = config.sort.map((clause) => ({
      field: toScreamingSnakeCase(clause.field),
      order: clause.direction.toUpperCase(),
    }));
    parts.push(`sort: ${inlineJson(sortInput)}`);
  }

  return parts.length > 0 ? parts.join(', ') : null;
}

/**
 * Serializes a value as inline GraphQL literal syntax.
 * Unlike JSON, GraphQL uses unquoted enum values for `field` and `order`
 * keys inside sort/filter input objects.
 */
function inlineJson(value: unknown, enumKeys = new Set(['field', 'order'])): string {
  if (value === null || value === undefined) {
    return 'null';
  }
  if (typeof value === 'string') {
    return `"${value}"`;
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return String(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((item) => inlineJson(item, enumKeys)).join(', ')}]`;
  }
  if (typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>).map(([key, val]) => {
      const rendered = enumKeys.has(key) && typeof val === 'string' ? val : inlineJson(val, enumKeys);
      return `${key}: ${rendered}`;
    });
    return `{${entries.join(', ')}}`;
  }
  return String(value);
}

function buildFilterInput(filter: Record<string, unknown>): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const [field, operators] of Object.entries(filter)) {
    if (operators != null && typeof operators === 'object') {
      const snakeOperators: Record<string, unknown> = {};
      for (const [operator, value] of Object.entries(operators as Record<string, unknown>)) {
        snakeOperators[toSnakeCase(operator)] = value;
      }
      result[toSnakeCase(field)] = snakeOperators;
    }
  }
  return result;
}

function toSnakeCase(camelCase: string): string {
  return camelCase.replace(/[A-Z]/g, (letter) => `_${letter.toLowerCase()}`);
}

function toScreamingSnakeCase(camelCase: string): string {
  return camelCase.replace(/[A-Z]/g, (letter) => `_${letter}`).toUpperCase();
}

function capitalizeFirst(value: string): string {
  return value.charAt(0).toUpperCase() + value.slice(1);
}
