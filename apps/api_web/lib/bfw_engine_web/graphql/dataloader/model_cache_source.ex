defmodule BfwEngineWeb.Graphql.Dataloader.ModelCacheSource do
  @moduledoc """
  `Dataloader.KV` source wrapping `BfwEngine.BPMN.ModelCache.fetch/1`.

  Registered on the Absinthe schema as `:model_cache` (see `schema.ex`
  `context/1`). Dataloader deduplicates the batch key set before calling
  `load/2`, so within a single request tick `ModelCache.fetch/1` is called
  at most once per distinct `process_version_id`, even if dozens of
  `FlowNodeInstance.flowNode` fields resolve against the same version
  (WP-3.4 / WP-7 test v).
  """

  alias BfwEngine.BPMN.ModelCache

  @spec data() :: Dataloader.Source.t()
  def data do
    Dataloader.KV.new(&load/2)
  end

  @spec load(:definitions, [String.t()]) :: %{String.t() => {:ok, term()} | {:error, term()}}
  defp load(:definitions, process_version_ids) do
    Map.new(process_version_ids, fn process_version_id ->
      {process_version_id, ModelCache.fetch(process_version_id)}
    end)
  end
end
