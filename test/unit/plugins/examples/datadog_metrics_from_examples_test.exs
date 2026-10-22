example_root =
  Path.expand(
    "../../../../examples/plugins/event_sinks/datadog_metrics",
    __DIR__
  )

Code.require_file(Path.expand("../../../../examples/plugins/shared/example_compiler.ex", __DIR__))

Examples.Shared.ExampleCompiler.compile_files(
  Path.wildcard(Path.join(example_root, "lib/**/*.ex"))
)

for test_file_path <-
      example_root
      |> Path.join("test/**/*_test.exs")
      |> Path.wildcard()
      |> Enum.sort() do
  Code.require_file(test_file_path)
end
