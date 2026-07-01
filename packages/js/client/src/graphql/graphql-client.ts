import type {
  CursorPageInfo,
  DataObjectValue,
  DataObjectValueField,
  DataObjectValueFilter,
  DataObjectValueInclude,
  DecisionDefinition,
  DecisionDefinitionField,
  DecisionDefinitionFilter,
  DecisionDefinitionInclude,
  DecisionVersion,
  DecisionVersionField,
  DecisionVersionFilter,
  FlowNodeInstance,
  FlowNodeInstanceField,
  FlowNodeInstanceFilter,
  FlowNodeInstanceInclude,
  GetQueryOptions,
  ListQueryOptions,
  OffsetPageInfo,
  OffsetPagination,
  PaginatedResult,
  PaginationOptions,
  ProcessInstance,
  ProcessInstanceField,
  ProcessInstanceFilter,
  ProcessInstanceInclude,
  ProcessModel,
  ProcessModelField,
  ProcessModelFilter,
  ProcessModelInclude,
  ProcessVersion,
  ProcessVersionField,
  ProcessVersionFilter,
} from '@elraptorus/daemonengine_sdk';

import { mapResponseError } from '../errors/error-mapper.js';
import type { HttpTransport } from '../http/transport.js';
import { buildGetQuery, buildListQuery } from './query-builder.js';

const GRAPHQL_PATH = '/api/v1/graphql';

interface GraphqlResponse<T> {
  data?: T;
  errors?: { message: string; extensions?: Record<string, unknown> }[];
}

interface ConnectionResponse {
  results: unknown[];
  count: number;
  startKeyset?: string | null;
  endKeyset?: string | null;
  hasNextPage?: boolean;
  hasPreviousPage?: boolean;
  pageNumber?: number;
  lastPage?: number;
  limit?: number;
}

/**
 * Typed GraphQL sub-client. Provides query-builder methods for each
 * engine resource — users never write raw GraphQL strings. Field selection,
 * filtering, sorting, pagination, and relationship loading are all typed.
 */
export class GraphqlClient {
  constructor(private readonly transport: HttpTransport) {}

  /** Query process models with typed field selection, filters, sorting, pagination, and includes. */
  async queryProcessModels<F extends ProcessModelField>(
    options: ListQueryOptions<F, ProcessModelFilter, ProcessModelInclude>,
  ): Promise<PaginatedResult<Pick<ProcessModel, F>>> {
    return this.executeListQuery<ProcessModel, F, ProcessModelFilter, ProcessModelInclude>(
      'processes',
      'Process',
      options,
    );
  }

  /**
   * Get a single process model by its BPMN process ID.
   * Uses a filtered list query internally because the AshGraphql `getProcess`
   * endpoint expects the internal UUID primary key, not the string process model ID.
   */
  async getProcessModel<F extends ProcessModelField>(
    processModelId: string,
    options: GetQueryOptions<F, ProcessModelInclude>,
  ): Promise<Pick<ProcessModel, F>> {
    const listOptions: ListQueryOptions<F, ProcessModelFilter, ProcessModelInclude> = {
      fields: options.fields,
      filter: { processModelId: { eq: processModelId } },
      pagination: { mode: 'offset', limit: 1, offset: 0 },
    };
    if (options.include) {
      listOptions.include = options.include;
    }
    const result = await this.executeListQuery<ProcessModel, F, ProcessModelFilter, ProcessModelInclude>(
      'processes',
      'Process',
      listOptions,
    );
    if (result.data.length === 0) {
      return null as unknown as Pick<ProcessModel, F>;
    }
    return result.data[0]!;
  }

  /** Query process versions with typed field selection, filters, sorting, and pagination. */
  async queryProcessVersions<F extends ProcessVersionField>(
    options: ListQueryOptions<F, ProcessVersionFilter, Record<string, never>>,
  ): Promise<PaginatedResult<Pick<ProcessVersion, F>>> {
    return this.executeListQuery<ProcessVersion, F, ProcessVersionFilter, Record<string, never>>(
      'processVersions',
      'ProcessVersion',
      options,
    );
  }

  /** Query process instances with typed field selection, filters, sorting, pagination, and includes. */
  async queryProcessInstances<F extends ProcessInstanceField>(
    options: ListQueryOptions<F, ProcessInstanceFilter, ProcessInstanceInclude>,
  ): Promise<PaginatedResult<Pick<ProcessInstance, F>>> {
    return this.executeListQuery<ProcessInstance, F, ProcessInstanceFilter, ProcessInstanceInclude>(
      'processInstances',
      'ProcessInstance',
      options,
    );
  }

  /** Get a single process instance by ID. */
  async getProcessInstance<F extends ProcessInstanceField>(
    id: string,
    options: GetQueryOptions<F, ProcessInstanceInclude>,
  ): Promise<Pick<ProcessInstance, F>> {
    return this.executeGetQuery<ProcessInstance, F, ProcessInstanceInclude>('processInstance', id, options);
  }

  /** Query flow node instances with typed field selection, filters, sorting, pagination, and includes. */
  async queryFlowNodeInstances<F extends FlowNodeInstanceField>(
    options: ListQueryOptions<F, FlowNodeInstanceFilter, FlowNodeInstanceInclude>,
  ): Promise<PaginatedResult<Pick<FlowNodeInstance, F>>> {
    return this.executeListQuery<FlowNodeInstance, F, FlowNodeInstanceFilter, FlowNodeInstanceInclude>(
      'flowNodeInstances',
      'FlowNodeInstance',
      options,
    );
  }

  /** Get a single flow node instance by ID. */
  async getFlowNodeInstance<F extends FlowNodeInstanceField>(
    id: string,
    options: GetQueryOptions<F, FlowNodeInstanceInclude>,
  ): Promise<Pick<FlowNodeInstance, F>> {
    return this.executeGetQuery<FlowNodeInstance, F, FlowNodeInstanceInclude>('flowNodeInstance', id, options);
  }

  /** Query current data object values (latest value per Data Object per PI). */
  async queryDataObjectValues<F extends DataObjectValueField>(
    options: ListQueryOptions<F, DataObjectValueFilter, DataObjectValueInclude>,
  ): Promise<PaginatedResult<Pick<DataObjectValue, F>>> {
    return this.executeListQuery<DataObjectValue, F, DataObjectValueFilter, DataObjectValueInclude>(
      'dataObjectValues',
      'DataObjectValue',
      options,
    );
  }

  /** Get a single data object value by ID. */
  async getDataObjectValue<F extends DataObjectValueField>(
    id: string,
    options: GetQueryOptions<F, DataObjectValueInclude>,
  ): Promise<Pick<DataObjectValue, F>> {
    return this.executeGetQuery<DataObjectValue, F, DataObjectValueInclude>('dataObjectValue', id, options);
  }

  /** Query data object history (full audit trail of all writes). */
  async queryDataObjectHistory<F extends DataObjectValueField>(
    options: ListQueryOptions<F, DataObjectValueFilter, DataObjectValueInclude>,
  ): Promise<PaginatedResult<Pick<DataObjectValue, F>>> {
    return this.executeListQuery<DataObjectValue, F, DataObjectValueFilter, DataObjectValueInclude>(
      'dataObjectHistory',
      'DataObjectHistoryEntry',
      options,
    );
  }

  /** Query decision versions with typed field selection, filters, sorting, and pagination. */
  async queryDecisionVersions<F extends DecisionVersionField>(
    options: ListQueryOptions<F, DecisionVersionFilter, Record<string, never>>,
  ): Promise<PaginatedResult<Pick<DecisionVersion, F>>> {
    return this.executeListQuery<DecisionVersion, F, DecisionVersionFilter, Record<string, never>>(
      'decisionVersions',
      'DecisionVersion',
      options,
    );
  }

  /** Query decision definitions with typed field selection, filters, sorting, pagination, and includes. */
  async queryDecisionDefinitions<F extends DecisionDefinitionField>(
    options: ListQueryOptions<F, DecisionDefinitionFilter, DecisionDefinitionInclude>,
  ): Promise<PaginatedResult<Pick<DecisionDefinition, F>>> {
    return this.executeListQuery<DecisionDefinition, F, DecisionDefinitionFilter, DecisionDefinitionInclude>(
      'decisionDefinitions',
      'DecisionDefinition',
      options,
    );
  }

  /**
   * Get a single decision definition by its DMN definitions ID.
   * Uses a filtered list query internally because the AshGraphql endpoint
   * expects the internal UUID, not the string decision definition ID.
   */
  async getDecisionDefinition<F extends DecisionDefinitionField>(
    decisionDefinitionId: string,
    options: GetQueryOptions<F, DecisionDefinitionInclude>,
  ): Promise<Pick<DecisionDefinition, F>> {
    const listOptions: ListQueryOptions<F, DecisionDefinitionFilter, DecisionDefinitionInclude> = {
      fields: options.fields,
      filter: { decisionDefinitionId: { eq: decisionDefinitionId } },
      pagination: { mode: 'offset', limit: 1, offset: 0 },
    };
    if (options.include) {
      listOptions.include = options.include;
    }
    const result = await this.executeListQuery<
      DecisionDefinition,
      F,
      DecisionDefinitionFilter,
      DecisionDefinitionInclude
    >('decisionDefinitions', 'DecisionDefinition', listOptions);
    if (result.data.length === 0) {
      return null as unknown as Pick<DecisionDefinition, F>;
    }
    return result.data[0]!;
  }

  /**
   * Escape hatch for advanced users. Sends a raw GraphQL query string
   * to the engine. Prefer the typed methods above for everyday use.
   * @param query - The GraphQL query string.
   * @param variables - Optional GraphQL variables.
   * @param options.headers - Additional HTTP headers (e.g. operation-tracing, tenancy).
   */
  async raw<T = unknown>(
    query: string,
    variables?: Record<string, unknown>,
    options?: { headers?: Record<string, string> },
  ): Promise<T> {
    const response = await this.transport.post<GraphqlResponse<T>>(
      GRAPHQL_PATH,
      { query, variables },
      options?.headers ? { headers: options.headers } : undefined,
    );
    this.throwOnGraphqlErrors(response);
    return response.data as T;
  }

  private async executeListQuery<Resource, F extends string, Filter, Include>(
    resourceName: string,
    ashTypeName: string,
    options: ListQueryOptions<F, Filter, Include>,
  ): Promise<PaginatedResult<Pick<Resource, F & keyof Resource>>> {
    const { query, variables } = buildListQuery({
      resourceName,
      ashTypeName,
      fields: options.fields,
      filter: options.filter as Record<string, unknown> | undefined,
      sort: options.sort as { field: string; direction: 'asc' | 'desc' }[] | undefined,
      include: options.include as Record<string, { fields: string[] }> | undefined,
      pagination: options.pagination,
    });

    const response = await this.transport.post<GraphqlResponse<Record<string, ConnectionResponse>>>(GRAPHQL_PATH, {
      query,
      variables,
    });
    this.throwOnGraphqlErrors(response);

    const resourceData = response.data?.[resourceName];
    if (!resourceData) {
      const emptyPageInfo: CursorPageInfo | OffsetPageInfo =
        options.pagination?.mode === 'offset'
          ? {
              type: 'offset',
              totalCount: 0,
              offset: (options.pagination as OffsetPagination).offset,
              limit: (options.pagination as OffsetPagination).limit,
              hasNextPage: false,
              hasPreviousPage: false,
              pageNumber: 1,
              lastPage: 1,
            }
          : {
              type: 'cursor',
              totalCount: 0,
              startCursor: null,
              endCursor: null,
              hasNextPage: false,
              hasPreviousPage: false,
            };
      return { data: [], pageInfo: emptyPageInfo };
    }

    const camelizedData = resourceData.results.map((record) => camelizeKeys(record as Record<string, unknown>)) as Pick<
      Resource,
      F & keyof Resource
    >[];
    const pageInfo = this.buildPageInfo(resourceData, options.pagination, camelizedData.length);

    return { data: camelizedData, pageInfo };
  }

  private async executeGetQuery<Resource, F extends string, Include>(
    resourceName: string,
    id: string,
    options: GetQueryOptions<F, Include>,
  ): Promise<Pick<Resource, F & keyof Resource>> {
    const built = buildGetQuery(id, {
      resourceName,
      fields: options.fields,
      include: options.include as Record<string, { fields: string[] }> | undefined,
    });

    const response = await this.transport.post<GraphqlResponse<Record<string, unknown>>>(GRAPHQL_PATH, {
      query: built.query,
      variables: built.variables,
    });
    this.throwOnGraphqlErrors(response);

    const responseKey = built.getFieldName ?? resourceName;
    const resourceData = response.data?.[responseKey];
    if (resourceData === null || resourceData === undefined) {
      return null as unknown as Pick<Resource, F & keyof Resource>;
    }
    return camelizeKeys(resourceData as Record<string, unknown>) as Pick<Resource, F & keyof Resource>;
  }

  private buildPageInfo(
    connectionData: ConnectionResponse,
    pagination: PaginationOptions | undefined,
    resultCount: number,
  ): CursorPageInfo | OffsetPageInfo {
    if (pagination?.mode === 'offset') {
      return {
        type: 'offset',
        totalCount: connectionData.count,
        offset: (pagination as OffsetPagination).offset,
        limit: connectionData.limit ?? (pagination as OffsetPagination).limit,
        hasNextPage: connectionData.hasNextPage ?? false,
        hasPreviousPage: connectionData.hasPreviousPage ?? false,
        pageNumber: connectionData.pageNumber ?? 1,
        lastPage: connectionData.lastPage ?? 1,
      };
    }

    return {
      type: 'cursor',
      totalCount: connectionData.count,
      startCursor: connectionData.startKeyset ?? null,
      endCursor: connectionData.endKeyset ?? null,
      hasNextPage: resultCount < connectionData.count,
      hasPreviousPage: pagination?.mode === 'cursor' && pagination.after != null,
    };
  }

  private throwOnGraphqlErrors(response: GraphqlResponse<unknown>): void {
    if (response.errors && response.errors.length > 0) {
      const firstError = response.errors[0]!;
      const rawCode = firstError.extensions?.['code'] as string | undefined;
      const errorCode = rawCode?.toLowerCase().replace(/ /g, '_');

      if (errorCode) {
        throw mapResponseError(200, {
          error: errorCode,
          message: firstError.message,
          ...firstError.extensions,
        });
      }

      throw new Error(`GraphQL error: ${firstError.message}`);
    }
  }
}

/**
 * Keys whose values are opaque payloads — the key itself is camelCased,
 * but nested keys inside the value are left unchanged. Mirrors the
 * engine's Wire.@opaque_atom_fields list.
 */
const OPAQUE_KEYS = new Set([
  'payload',
  'result',
  'input_token',
  'output_token',
  'started_with_context',
  'started_by',
  'deployer',
  'claims',
  'form_fields',
  'form_actions',
  'type_properties',
  'error_info',
  'payload_contract',
  'result_contract',
  'data_contracts',
  'bpmn_xml',
  'dmn_xml',
  'violations',
  'metadata',
  'deleted_by',
  'data_object_cache',
]);

function camelizeKeys(record: Record<string, unknown>): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(record)) {
    const camelKey = key.replace(/_([a-z])/g, (_, letter: string) => letter.toUpperCase());

    if (OPAQUE_KEYS.has(key)) {
      if (typeof value === 'string') {
        result[camelKey] = tryParseJsonScalar(value);
      } else {
        result[camelKey] = value;
      }
    } else if (Array.isArray(value)) {
      result[camelKey] = value.map((item) =>
        item !== null && typeof item === 'object' ? camelizeKeys(item as Record<string, unknown>) : item,
      );
    } else if (value !== null && typeof value === 'object') {
      result[camelKey] = camelizeKeys(value as Record<string, unknown>);
    } else if (typeof value === 'string') {
      result[camelKey] = tryParseJsonScalar(value);
    } else {
      result[camelKey] = value;
    }
  }
  return result;
}

/**
 * AshGraphql represents Ash `:map` attributes as a `Json` scalar which
 * arrives as a JSON-encoded string on the wire. Attempt to parse string
 * values that look like JSON objects or arrays so the caller gets native
 * objects. Non-JSON strings pass through unchanged.
 */
function tryParseJsonScalar(value: string): unknown {
  const trimmed = value.trimStart();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      return JSON.parse(value);
    } catch {
      return value;
    }
  }
  return value;
}
