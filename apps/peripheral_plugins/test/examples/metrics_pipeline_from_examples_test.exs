example_library_root =
  Path.expand(
    "../../../../examples/plugins/combined/metrics_pipeline/lib",
    __DIR__
  )

for library_file_path <- Path.wildcard(Path.join(example_library_root, "**/*.ex")) |> Enum.sort() do
  Code.require_file(library_file_path)
end

example_test_path =
  Path.expand(
    "../../../../examples/plugins/combined/metrics_pipeline/test/metrics_pipeline_test.exs",
    __DIR__
  )

Code.require_file(example_test_path)
