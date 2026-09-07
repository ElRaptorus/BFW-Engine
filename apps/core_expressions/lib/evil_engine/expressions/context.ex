defmodule EvilEngine.Expressions.Context do
  @moduledoc """
  Runtime context for FEEL expression evaluation.

  Encapsulates the seven root bindings defined in
  `docs/architecture/expressions.md` plus the optional `loop` overlay for
  Multi-Instance / standard-loop iterations.

  ## String-key requirement

  The Rust FEEL NIF decodes maps as `HashMap<String, Term>`. Atom-keyed
  maps silently become `null`. Every map stored in this struct **must**
  use string keys at all nesting levels. Use `from_handler_context/2` to
  build a correctly-keyed context from runtime data.
  """

  @type t :: %__MODULE__{
          token: map(),
          this: map(),
          context: map(),
          data_objects: map(),
          process: map(),
          process_instance: map(),
          identity: map(),
          loop: map() | nil,
          gateway: map() | nil
        }

  @enforce_keys [:token, :this, :context, :data_objects, :process, :process_instance, :identity]
  defstruct [
    :token,
    :this,
    :context,
    :data_objects,
    :process,
    :process_instance,
    :identity,
    loop: nil,
    gateway: nil
  ]

  @doc """
  Builds a complete FEEL context from a `HandlerContext` and a token payload.

  Converts all atom-keyed runtime maps (`process`, `process_instance`,
  `identity`) to string-keyed maps with camelCase field names matching
  the FEEL binding spec. This is the **canonical** way to assemble a
  FEEL context — handlers must not build `%Context{}` manually.

  Accepts any map with the standard handler context keys (`flow_node_this`,
  `context`, `data_objects`, `process`, `process_instance`, `identity`).
  Typed as `map()` to avoid a cyclic compile dependency on `core_execution`.
  """
  @spec from_handler_context(map(), map()) :: t()
  def from_handler_context(handler_context, token_payload) when is_map(handler_context) do
    %__MODULE__{
      token: token_payload || %{},
      this: handler_context.flow_node_this || %{},
      context: handler_context.context || %{},
      data_objects: ensure_string_keys(handler_context.data_objects || %{}),
      process: stringify_process(handler_context.process),
      process_instance: stringify_process_instance(handler_context.process_instance),
      identity: stringify_identity(handler_context.identity),
      loop: Map.get(handler_context, :loop)
    }
  end

  @doc """
  Builds the `this` binding from a BPMN flow node struct.

  Returns a string-keyed map with `"id"`, `"name"`, and `"type"` — the
  flow node metadata that FEEL expressions access via `this.id`,
  `this.name`, and `this.type`.
  """
  @spec flow_node_this(%{
          required(:id) => String.t(),
          required(:name) => String.t() | nil,
          required(:type) => atom(),
          optional(any()) => any()
        }) :: map()
  def flow_node_this(%{id: id, name: name, type: type}) do
    %{
      "id" => id,
      "name" => name || "",
      "type" => to_string(type)
    }
  end

  @doc """
  Converts the context struct into the flat string-keyed map shape that
  the FEEL NIF expects. FEEL uses `camelCase` names per the spec, so
  `data_objects` maps to `"dataObjects"` and `process_instance` maps
  to `"processInstance"`.

  The `loop` overlay is only included when non-nil. The `gateway` overlay
  (Complex Gateway join bindings `activatedCount` / `incomingCount`) is
  merged at the **top level** so expressions reference them directly
  (e.g. `activatedCount >= 2`), and is only included when non-nil.
  """
  @spec to_feel_scope(t()) :: %{String.t() => term()}
  def to_feel_scope(%__MODULE__{} = context) do
    base = %{
      "token" => context.token,
      "this" => context.this,
      "context" => context.context,
      "dataObjects" => context.data_objects,
      "process" => context.process,
      "processInstance" => context.process_instance,
      "identity" => context.identity
    }

    base
    |> merge_loop(context.loop)
    |> merge_gateway(context.gateway)
  end

  @doc """
  Injects the Multi-Instance / Standard Loop overlay bindings into a context.

  Sets the `loop` binding with per-iteration metadata: `index` (0-based),
  `total` (collection length or nil for Standard Loops), `completed`
  (iterations finished so far), `results` (aggregated outputs), and `item`
  (current collection element or nil for Standard Loops).
  """
  @spec put_loop_bindings(
          t(),
          non_neg_integer(),
          non_neg_integer() | nil,
          non_neg_integer(),
          list(),
          term()
        ) :: t()
  def put_loop_bindings(%__MODULE__{} = context, index, total, completed, results, item) do
    %{
      context
      | loop: %{
          "index" => index,
          "total" => total,
          "completed" => completed,
          "results" => results || [],
          "item" => item
        }
    }
  end

  @doc """
  Injects the Complex Gateway join bindings into a context.

  Adds `activatedCount` (number of distinct incoming branches that have
  delivered a token) and `incomingCount` (total incoming branch count) as
  **top-level** FEEL bindings, used to evaluate a Complex Join's
  `activationCondition` (e.g. `activatedCount >= 2`).
  """
  @spec put_gateway_bindings(t(), non_neg_integer(), non_neg_integer()) :: t()
  def put_gateway_bindings(%__MODULE__{} = context, activated_count, incoming_count)
      when is_integer(activated_count) and is_integer(incoming_count) do
    %{
      context
      | gateway: %{"activatedCount" => activated_count, "incomingCount" => incoming_count}
    }
  end

  defp merge_loop(scope, nil), do: scope
  defp merge_loop(scope, loop) when is_map(loop), do: Map.put(scope, "loop", loop)

  defp merge_gateway(scope, nil), do: scope
  defp merge_gateway(scope, gateway) when is_map(gateway), do: Map.merge(scope, gateway)

  # -- Private: string-key conversion for FEEL NIF compatibility -----------

  defp stringify_process(process) when is_map(process) and map_size(process) > 0 do
    %{
      "id" => get_field(process, :id, "id", ""),
      "name" => get_field(process, :name, "name", ""),
      "version" => get_field(process, :version, "version", "")
    }
  end

  defp stringify_process(_), do: %{}

  defp stringify_process_instance(process_instance)
       when is_map(process_instance) and map_size(process_instance) > 0 do
    started_at = get_field(process_instance, :started_at, "startedAt", nil)

    %{
      "id" => get_field(process_instance, :id, "id", ""),
      "startedAt" => format_datetime(started_at),
      "startedBy" => get_field(process_instance, :started_by, "startedBy", nil)
    }
  end

  defp stringify_process_instance(_), do: %{}

  defp stringify_identity(identity) when is_map(identity) and map_size(identity) > 0 do
    %{
      "id" => get_field(identity, :id, "id", ""),
      "roles" => get_field(identity, :roles, "roles", []),
      "groups" => get_field(identity, :groups, "groups", []),
      "claims" => get_field(identity, :claims, "claims", %{})
    }
  end

  defp stringify_identity(_), do: %{}

  defp get_field(map, atom_key, string_key, default) do
    Map.get(map, atom_key) || Map.get(map, string_key) || default
  end

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(other), do: other

  defp ensure_string_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp ensure_string_keys(other), do: other
end
