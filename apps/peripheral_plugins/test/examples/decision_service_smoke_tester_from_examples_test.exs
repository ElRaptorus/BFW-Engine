example_library_root =
  Path.expand(
    "../../../../examples/plugins/business_rules/decision_service_smoke_tester/lib",
    __DIR__
  )

for library_file_path <- Path.wildcard(Path.join(example_library_root, "**/*.ex")) |> Enum.sort() do
  Code.require_file(library_file_path)
end

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
