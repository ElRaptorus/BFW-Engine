defmodule BfwEngine.Plugins.Examples.CombinedPluginsExampleTest do
  @moduledoc false
  use ExUnit.Case, async: false

  @compile {:no_warn_undefined, Examples.Shared.ExampleCompiler}

  alias Examples.Shared.ExampleCompiler

  @examples_root Path.expand("../../../../examples/plugins/combined", __DIR__)
  @compiler_path Path.expand("../../../../examples/plugins/shared/example_compiler.ex", __DIR__)

  setup_all do
    Code.require_file(@compiler_path)

    library_files =
      @examples_root
      |> Path.join("**/lib/**/*.ex")
      |> Path.wildcard()

    ExampleCompiler.compile_files(library_files)

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
