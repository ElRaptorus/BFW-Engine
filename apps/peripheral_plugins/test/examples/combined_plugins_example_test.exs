defmodule EvilEngine.Plugins.Examples.CombinedPluginsExampleTest do
  @moduledoc false
  use ExUnit.Case, async: false

  @examples_root Path.expand("../../../../examples/plugins/combined", __DIR__)

  setup_all do
    paths =
      @examples_root
      |> Path.join("**/lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "metrics_pipeline"))
      |> Enum.sort()

    {:ok, _modules, _warnings} =
      Kernel.ParallelCompiler.compile(paths, return_diagnostics: true)

    :ok
  end

  test "combined plugin examples compile and export expected modules" do
    assert {:module, Examples.Plugins.Combined.RabbitmqToEngine.RabbitmqOrchestratorPlugin} =
             Code.ensure_loaded(
               Examples.Plugins.Combined.RabbitmqToEngine.RabbitmqOrchestratorPlugin
             )

    assert {:module, Examples.Plugins.Combined.MetricsPipeline.MetricsPipelinePlugin} =
             Code.ensure_loaded(Examples.Plugins.Combined.MetricsPipeline.MetricsPipelinePlugin)
  end
end
