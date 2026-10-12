import type { SortClause } from './filters.js';
import type { PaginationOptions } from './pagination.js';

/**
 * Options for list queries: field selection, filtering, sorting, pagination,
 * and optional relationship loading.
 *
 * @typeParam SelectedField - String literal union of selectable field names for this resource.
 * @typeParam Filter - Typed filter interface for this resource.
 * @typeParam Include - Typed include interface for this resource's relationships.
 */
export interface ListQueryOptions<SelectedField extends string, Filter, Include> {
  /** Which scalar fields to retrieve. Controls the GraphQL selection set. */
  fields: SelectedField[];
  /** Typed filter criteria (per-field operators). */
  filter?: Filter;
  /** Sort order. Multiple clauses are applied in array order. */
  sort?: SortClause<SelectedField>[];
  /** Nested relationship loading with typed sub-field selection. */
  include?: Include;
  /** Pagination style and parameters. Omit for unpaginated queries. */
  pagination?: PaginationOptions;
}

/**
 * Options for single-record `get` queries: field selection and
 * optional relationship loading.
 *
 * @typeParam SelectedField - String literal union of selectable field names for this resource.
 * @typeParam Include - Typed include interface for this resource's relationships.
 */
export interface GetQueryOptions<SelectedField extends string, Include> {
  /** Which scalar fields to retrieve. Controls the GraphQL selection set. */
  fields: SelectedField[];
  /** Nested relationship loading with typed sub-field selection. */
  include?: Include;
}
