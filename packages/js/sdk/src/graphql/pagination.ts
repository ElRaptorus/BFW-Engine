/**
 * Cursor-based pagination (Relay-style).
 *
 * Best for: infinite scroll, "load more" UIs, real-time feeds where rows
 * may be inserted/deleted between fetches (no duplicate or missing rows).
 *
 * Forward: set `first` and optionally `after` (cursor from previous page).
 * Backward: set `last` and optionally `before`.
 */
export interface CursorPagination {
  mode: 'cursor';
  /** Return the first N results (forward pagination). */
  first?: number;
  /** Opaque cursor from a previous query's `pageInfo.endCursor`. */
  after?: string;
  /** Return the last N results (backward pagination). */
  last?: number;
  /** Opaque cursor from a previous query's `pageInfo.startCursor`. */
  before?: string;
}

/**
 * Offset-based pagination (traditional page-table style).
 *
 * Best for: page-table UIs with a page selector, "jump to page N",
 * displaying total page counts. Used by the Studio's Engine Browser.
 *
 * Trade-off: if rows are inserted/deleted between page fetches, results
 * may shift (duplicate or missing rows at page boundaries).
 */
export interface OffsetPagination {
  mode: 'offset';
  /** Maximum number of results per page. */
  limit: number;
  /** Number of results to skip (page * limit). */
  offset: number;
}

/** Discriminated union — callers pick one pagination style per query. */
export type PaginationOptions = CursorPagination | OffsetPagination;

/**
 * Paginated list result. Includes the unwrapped data array and metadata
 * for navigating between pages.
 *
 * For cursor pagination: `pageInfo` carries cursors and has-more flags.
 * For offset pagination: `pageInfo` carries total count and page position.
 * Both styles populate `data` the same way.
 */
export interface PaginatedResult<T> {
  /** The result records for this page. */
  data: T[];
  /** Navigation metadata — shape depends on which pagination style was used. */
  pageInfo: CursorPageInfo | OffsetPageInfo;
}

/** Relay-style page metadata (returned when using `CursorPagination`). */
export interface CursorPageInfo {
  type: 'cursor';
  /** Total number of records matching the filter (before pagination). */
  totalCount: number;
  /** Cursor of the first item in this page (pass as `before` for backward nav). */
  startCursor: string | null;
  /** Cursor of the last item in this page (pass as `after` for forward nav). */
  endCursor: string | null;
  /** True if there are more results after `endCursor`. */
  hasNextPage: boolean;
  /** True if there are more results before `startCursor`. */
  hasPreviousPage: boolean;
}

/** Offset-style page metadata (returned when using `OffsetPagination`). */
export interface OffsetPageInfo {
  type: 'offset';
  /** Total number of records matching the filter (before pagination). */
  totalCount: number;
  /** The offset that was applied. */
  offset: number;
  /** The limit that was applied. */
  limit: number;
  /** True if there are more results beyond this page. */
  hasNextPage: boolean;
  /** True if offset > 0. */
  hasPreviousPage: boolean;
  /** 1-based page number (server-provided). */
  pageNumber: number;
  /** Total number of pages (server-provided). */
  lastPage: number;
}
