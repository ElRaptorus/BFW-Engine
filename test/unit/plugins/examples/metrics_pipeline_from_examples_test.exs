example_library_root =
  Path.expand(
    "../../../../examples/plugins/combined/metrics_pipeline/lib",
    __DIR__
  )

Code.require_file(Path.expand("../../../../examples/plugins/shared/example_compiler.ex", __DIR__))

Examples.Shared.ExampleCompiler.compile_files(
  Path.wildcard(Path.join(example_library_root, "**/*.ex"))
)

example_test_path =
  Path.expand(
    "../../../../examples/plugins/combined/metrics_pipeline/test/metrics_pipeline_test.exs",
    __DIR__
  )

Code.require_file(example_test_path)
