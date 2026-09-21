defmodule BfwEngine.SDK.BPMN do
  @moduledoc """
  Re-exported BPMN parsing and model-cache surface for out-of-tree Elixir
  tooling (Phase 6.1, WP-4).

  `engine_sdk` depends on `core_bpmn` directly (see `mix.exs`), so every
  `BfwEngine.BPMN.Model.*` struct — `Definitions`, `Process`, `FlowNode`,
  the 21 `FlowNodeData.*` variants, the 11 `EventDefinition.*` variants,
  and the supporting types (`SequenceFlow`, `Lane`, `DataObject`, `Mapping`,
  `MultiInstance`, `StandardLoop`, …) — is already reachable by any plugin
  or Hex consumer of `bfw_engine_sdk` under its real `BfwEngine.BPMN.*`
  name; there is nothing to alias.

  This module exists to give the **functions** — parsing and cache lookup
  — a documented, discoverable entry point under the `BfwEngine.SDK`
  namespace, mirroring the read-only projection the GraphQL Model graph
  (`BfwEngineWeb.Graphql.ModelResolvers`) exposes over the wire. Same
  semantics, same source of truth (`ModelCache`), no HTTP round-trip.

  ## Parsing undeployed XML

      {:ok, %BfwEngine.BPMN.Model.Definitions{} = definitions} =
        BfwEngine.SDK.BPMN.parse(xml)

  ## Reading a deployed model

      {:ok, %BfwEngine.BPMN.Model.Definitions{} = definitions} =
        BfwEngine.SDK.BPMN.fetch_definitions(process_version_id)

  `fetch_definitions/1` reads through `BfwEngine.BPMN.ModelCache`: a warm
  cache hit is a pure ETS lookup, a cold miss triggers a database read and
  a full re-parse (see `docs/architecture/common-pitfalls.md`).
  """

  alias BfwEngine.BPMN.Model
  alias BfwEngine.BPMN.ModelCache
  alias BfwEngine.BPMN.Parser

  @doc """
  Parses BPMN 2.0 XML into a `%BfwEngine.BPMN.Model.Definitions{}` tree.
  Does not consult or populate `ModelCache` — use this for undeployed XML
  (authoring-time tooling, linters, one-off scripts).
  """
  @spec parse(binary()) :: {:ok, Model.Definitions.t()} | {:error, term()}
  defdelegate parse(xml), to: Parser

  @doc """
  Reads the parsed model for a deployed process version, going through
  `ModelCache`. Returns `{:error, :not_found}` if the version does not
  exist or its source is unavailable for re-parsing on a cold miss.
  """
  @spec fetch_definitions(String.t()) ::
          {:ok, Model.Definitions.t()} | {:error, :not_found | term()}
  defdelegate fetch_definitions(process_version_id), to: ModelCache, as: :fetch

  @doc "Same as `fetch_definitions/1`, but returns the struct directly (or `nil`) instead of a result tuple."
  @spec get_definitions(String.t()) :: Model.Definitions.t() | nil
  defdelegate get_definitions(process_version_id), to: ModelCache, as: :get

  @doc """
  Reads the parsed model for a nested subprocess scope (embedded, event,
  ad-hoc, or transaction subprocess), given the shell's flow node ID.
  """
  @spec fetch_subprocess_model(String.t(), String.t()) ::
          {:ok, Model.Process.t(), Model.Definitions.t()} | {:error, term()}
  defdelegate fetch_subprocess_model(process_version_id, subprocess_node_id), to: ModelCache

  @doc "Indexes deployed top-level processes with a Message Start Event matching `message_name`."
  defdelegate find_message_start_events(message_name), to: ModelCache

  @doc "Indexes deployed top-level processes with a Signal Start Event matching `signal_name`."
  defdelegate find_signal_start_events(signal_name), to: ModelCache
end
