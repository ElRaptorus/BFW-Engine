defmodule Examples.Shared.ExampleCompiler do
  @moduledoc false

  @compiled_paths_key {__MODULE__, :compiled_paths}

  @doc """
  Compiles cookbook `*.ex` files as one Mix-style batch.

  `Code.require_file/1` compiles each path in isolation, so a plugin module
  that calls a sibling defined in another file warns `is yet to be defined`.
  `Kernel.ParallelCompiler.compile/2` resolves those cross-file references
  the same way `mix compile` does. Already-compiled paths are skipped so
  boot tests and unit wrappers can share a VM.
  """
  @spec compile_files([Path.t()]) :: :ok
  def compile_files(file_paths) when is_list(file_paths) do
    with_compile_lock(fn ->
      pending_paths =
        file_paths
        |> Enum.map(&Path.expand/1)
        |> Enum.uniq()
        |> Enum.reject(&already_compiled?/1)

      case pending_paths do
        [] ->
          :ok

        pending_paths ->
          {:ok, _modules, _warnings} =
            Kernel.ParallelCompiler.compile(pending_paths, return_diagnostics: true)

          remember_compiled_paths(pending_paths)
          :ok
      end
    end)
  end

  defp with_compile_lock(function) do
    lock_id = {@compiled_paths_key, :compile_lock}

    true = :global.set_lock(lock_id, [node()], :infinity)

    try do
      function.()
    after
      :global.del_lock(lock_id, [node()])
    end
  end

  defp already_compiled?(file_path) do
    MapSet.member?(compiled_paths(), file_path)
  end

  defp compiled_paths do
    :persistent_term.get(@compiled_paths_key, MapSet.new())
  end

  defp remember_compiled_paths(file_paths) do
    updated_paths = MapSet.union(compiled_paths(), MapSet.new(file_paths))
    :persistent_term.put(@compiled_paths_key, updated_paths)
  end
end
