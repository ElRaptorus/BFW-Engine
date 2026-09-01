example_library_root =
  Path.expand(
    "../../../../examples/plugins/business_rules/decision_service_smoke_tester/lib",
    __DIR__
  )

Code.require_file(Path.expand("../../../../examples/plugins/shared/example_compiler.ex", __DIR__))

Examples.Shared.ExampleCompiler.compile_files(
  Path.wildcard(Path.join(example_library_root, "**/*.ex"))
)

for test_file_path <-
      Path.wildcard(
        Path.expand(
          "../../../../examples/plugins/business_rules/decision_service_smoke_tester/test/*_test.exs",
          __DIR__
        )
      )
      |> Enum.sort() do
  Code.require_file(test_file_path)
end
