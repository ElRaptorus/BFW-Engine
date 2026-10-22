defmodule BfwEngine.MixProject do
  @moduledoc """
  Mix project for the Bifrost Forge World Engine — a BPMN 2.0 workflow engine.

  The Engine is one OTP application, `:bfw_engine`. Its layers (Core,
  Peripheral, Plugins, API) are top-level namespaces under `lib/`; the
  `boundary` compiler enforces which namespace may call which. See
  `docs/Architecture.md`.

  The OTP release is built by `host/mix.exs`. `mix release` from this
  root delegates there.
  """

  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :bfw_engine,
      version: @version,
      elixir: "~> 1.20",
      name: "Bifrost Forge World Engine",
      source_url: "https://github.com/ElRaptorus/BFW-Engine",
      homepage_url: "https://github.com/ElRaptorus/BFW-Engine",
      start_permanent: Mix.env() == :prod,
      compilers: [:boundary] ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: ["test/unit"],
      deps: deps(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts",
        plt_add_apps: [:mix, :ex_unit, :eex],
        flags: [:unmatched_returns, :error_handling, :underspecs]
      ],
      docs: [
        main: "overview",
        output: "manual",
        extras: [
          "README.md",

          # Getting Started
          "docs/guides/getting-started/overview.md",
          "docs/guides/getting-started/quickstart.md",
          "docs/guides/getting-started/concepts.md",

          # User Handbook
          "docs/guides/handbook/deploying-processes.md",
          "docs/guides/handbook/starting-instances.md",
          "docs/guides/handbook/user-tasks.md",
          "docs/guides/handbook/service-tasks.md",
          "docs/guides/handbook/script-tasks.md",
          "docs/guides/handbook/business-rule-tasks.md",
          "docs/guides/handbook/dmn-decisions.md",
          "docs/guides/handbook/manual-tasks.md",
          "docs/guides/handbook/exclusive-gateways.md",
          "docs/guides/handbook/parallel-gateways.md",
          "docs/guides/handbook/inclusive-gateways.md",
          "docs/guides/handbook/event-based-gateways.md",
          "docs/guides/handbook/complex-gateways.md",
          "docs/guides/handbook/call-activities.md",
          "docs/guides/handbook/embedded-subprocesses.md",
          "docs/guides/handbook/event-subprocesses.md",
          "docs/guides/handbook/adhoc-subprocesses.md",
          "docs/guides/handbook/transactions.md",
          "docs/guides/handbook/multi-instance.md",
          "docs/guides/handbook/standard-loops.md",
          "docs/guides/handbook/error-boundary-events.md",
          "docs/guides/handbook/error-end-events.md",
          "docs/guides/handbook/timer-events.md",
          "docs/guides/handbook/message-events.md",
          "docs/guides/handbook/signal-events.md",
          "docs/guides/handbook/conditional-events.md",
          "docs/guides/handbook/escalation-events.md",
          "docs/guides/handbook/expressions.md",
          "docs/guides/handbook/data-objects.md",
          "docs/guides/handbook/link-events.md",
          "docs/guides/handbook/compensation.md",
          "docs/guides/handbook/retry.md",
          "docs/guides/handbook/error-handling.md",
          "docs/guides/handbook/monitoring.md",

          # API Reference
          "docs/guides/api/rest-reference.md",
          "docs/guides/api/graphql-reference.md",
          "docs/guides/api/authentication.md",
          "docs/guides/api/websocket.md",

          # Plugin Development
          "docs/guides/plugins/getting-started.md",
          "docs/guides/plugins/engine-facade.md",
          "docs/guides/plugins/service-task-handler.md",
          "docs/guides/plugins/event-sink.md",
          "docs/guides/plugins/api-extension.md",
          "docs/guides/plugins/other-behaviours.md",
          "docs/guides/plugins/builtin-plugins.md",

          # Operations Guide
          "docs/guides/operations/deployment.md",
          "docs/guides/operations/database.md",
          "docs/guides/operations/security.md",
          "docs/guides/operations/observability.md",
          "docs/guides/operations/backpressure.md",
          "docs/guides/operations/troubleshooting.md",

          # Cheatsheets
          "docs/guides/cheatsheets/env-vars.cheatmd",
          "docs/guides/cheatsheets/api-endpoints.cheatmd",
          "docs/guides/cheatsheets/plugin-behaviours.cheatmd",

          # Reference
          "docs/Architecture.md",
          "docs/SupportedElements.md",
          "docs/Schema.md",
          "docs/Glossary.md",
          "docs/Philosophy.md",
          "docs/post-v1-ideas.md",

          # Architecture (detailed)
          "docs/architecture/index.md",
          "docs/architecture/execution.md",
          "docs/architecture/expressions.md",
          "docs/architecture/event-system.md",
          "docs/architecture/routing.md",
          "docs/architecture/data-model.md",
          "docs/architecture/authorization.md",
          "docs/architecture/plugins.md",
          "docs/architecture/api.md",
          "docs/architecture/configuration.md",
          "docs/architecture/shipping.md",
          "docs/architecture/observability.md",
          "docs/architecture/security.md",
          "docs/architecture/testing.md",
          "docs/architecture/dmn.md",
          "docs/architecture/sdk-client.md",
          "docs/architecture/timers.md",
          "docs/architecture/persistence.md",
          "docs/architecture/common-pitfalls.md"
        ],
        groups_for_extras: [
          "Getting Started": ~r{docs/guides/getting-started/},
          "User Handbook": ~r{docs/guides/handbook/},
          "API Reference": ~r{docs/guides/api/},
          "Plugin Development": ~r{docs/guides/plugins/},
          "Operations Guide": ~r{docs/guides/operations/},
          Cheatsheets: ~r{docs/guides/cheatsheets/},
          Reference: ~r{docs/(Architecture|Schema|Glossary|Philosophy|post-v1-ideas)\.md},
          "Architecture (Detailed)": ~r{docs/architecture/}
        ],
        groups_for_modules: [
          "Core — Types": ~r{BfwEngine\.Types\.},
          "Core — Execution": ~r{BfwEngine\.Execution\.},
          "Core — Expressions": ~r{BfwEngine\.Expressions},
          "Core — BPMN": ~r{BfwEngine\.BPMN\.},
          "Core — DMN": ~r{BfwEngine\.DMN\.},
          "Core — Timers": ~r{BfwEngine\.Timers\.},
          "Core — Events": ~r{BfwEngine\.Events\.},
          "Peripheral — Persistence": ~r{BfwEngine\.Persistence\.},
          "Peripheral — Telemetry": ~r{BfwEngine\.Telemetry\.},
          "Plugins — Loader and Registry": ~r{BfwEngine\.Plugins\.},
          "API — HTTP": ~r{BfwEngineWeb\.Http\.},
          "API — GraphQL": ~r{BfwEngineWeb\.Graphql\.},
          "API — WebSocket": ~r{BfwEngineWeb\.WebSocket\.},
          "API — Auth": ~r{BfwEngine\.Auth\.},
          "Plugins — Contracts": ~r{^BfwEngine\.(Plugin(\.|$)|EngineFacade)}
        ]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        # Local coverage only. `coveralls.github` / `coveralls.post` POST to
        # coveralls.io and are intentionally omitted (ExCoveralls 0.18 has no
        # skip_upload switch — not invoking those tasks is the kill switch).
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "test.unit": :test,
        "test.examples": :test,
        "test.integration": :test,
        "test.release": :test,
        "test.cookbook": :test,
        "test.conformance": :test,
        "test.coverdata": :test,
        "test.full": :test,
        "test.load": :test,
        "test.load.durability": :test,
        "test.load.hardening": :test,
        "test.load.all": :test,
        quality: :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :public_key, :runtime_tools],
      mod: {BfwEngine.Application, []}
    ]
  end

  # Root `test/support` is not compiled: the integration, conformance and load
  # runners load it with `Code.require_file/1`.
  defp elixirc_paths(:test), do: ["lib" | Path.wildcard("test/unit/*/support")]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core
      {:saxy, "~> 1.6"},
      {:ex_json_schema, "~> 0.11"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.4"},
      {:phoenix_pubsub, "~> 2.2"},
      {:rustler, "~> 0.37.3", runtime: false},

      # Peripheral
      {:ash, "~> 3.24"},
      {:ash_graphql, "~> 1.9"},
      {:ash_postgres, "~> 2.9"},
      {:simple_sat, "~> 0.1"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_metrics_prometheus_core, "~> 1.1"},
      {:telemetry_poller, "~> 1.1"},

      # Plugins
      {:req, "~> 0.5"},

      # API
      {:jose, "~> 1.11"},
      {:plug, "~> 1.16"},
      {:phoenix, "~> 1.8"},
      {:bandit, "~> 1.10"},
      {:open_api_spex, "~> 3.21"},
      {:yaml_elixir, "~> 2.11"},
      {:absinthe, "~> 1.7"},
      {:absinthe_plug, "~> 1.5"},
      {:dataloader, "~> 2.0"},

      # Tooling
      {:boundary, "~> 0.11", runtime: false},
      {:logger_json, "~> 7.0", only: :prod},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.8", runtime: false},
      {:bfw_engine_client, path: "packages/elixir/bfw_engine_client", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "deps.compile.sat", &run_client_deps_get/1],
      release: &run_host_release/1,
      "deps.compile.sat": ["deps.compile simple_sat", "deps.compile crux --force"],
      "ecto.setup": ["ash.setup"],
      "ecto.reset": ["ash.reset", "ash.setup"],

      # --- Test aliases -----------------------------------------------------
      "test.unit": ["test --exclude integration"],
      "test.examples": ["test test/unit/plugins/examples/"],
      "test.integration": ["run test/integration_runner.exs"],
      "test.release": &run_release_test/1,
      "test.cookbook": ["run test/integration_runner.exs -- integration/plugins"],
      # Sets BFE_LOAD_TEST_POOL=1 (real ConnectionPool). See P89.
      "test.load": &run_load_tests/1,
      "test.load.durability": &run_load_durability_tests/1,
      "test.load.hardening": &run_load_hardening_tests/1,
      "test.load.all": &run_load_all_tests/1,
      "test.conformance": ["run test/conformance_runner.exs"],
      # Integration + conformance under one :cover session; exports
      # cover/integration.coverdata.
      # Named test.coverdata so it does not shadow Mix's built-in
      # `mix test.coverage` (aggregates exported reports).
      "test.coverdata": ["run test/coverage_runner.exs"],
      "test.full": [
        "compile --warnings-as-errors",
        "test",
        "run test/integration_runner.exs",
        "run test/conformance_runner.exs"
      ],

      # --- Quality gate (compile + lint + analysis + docs + test + coverage) -
      # test.coverdata runs integration + conformance under :cover; the
      # coveralls.* --import-cover step runs the unit tests and merges
      # that coverdata. CI uses the same pair with `coveralls` (terminal)
      # instead of `coveralls.html`.
      quality: [
        "compile --warnings-as-errors",
        "bfw.gen.extension_manifest --check",
        "bfw.gen.contracts --check",
        "format",
        "credo --strict",
        "dialyzer",
        "sobelow --config",
        "docs --warnings-as-errors",
        &run_client_quality/1,
        "test.coverdata",
        "coveralls.html --import-cover cover"
      ],

      # --- CI pipeline ------------------------------------------------------
      "lint.ci": [
        "format --check-formatted",
        "credo --strict",
        "deps.audit"
      ],
      lint: ["format", "credo"]
    ]
  end

  defp run_load_tests(args) do
    run_load_suite(args, %{})
  end

  defp run_load_durability_tests(args) do
    run_load_suite(args, %{"BFE_LOAD_DURABILITY" => "1"})
  end

  defp run_load_hardening_tests(args) do
    run_load_suite(args, %{"BFE_LOAD_HARDENING" => "1"})
  end

  defp run_load_all_tests(args) do
    run_load_suite(args, %{
      "BFE_LOAD_DURABILITY" => "all",
      "BFE_LOAD_HARDENING" => "all"
    })
  end

  defp run_load_suite(args, extra_environment) do
    run_argv =
      case args do
        [] -> ["test/load_runner.exs"]
        extra -> ["test/load_runner.exs", "--" | extra]
      end

    Enum.each(extra_environment, fn {key, value} ->
      System.put_env(key, value)
    end)

    pool_ready? = System.get_env("BFE_LOAD_TEST_POOL") in ["1", "true"]

    if pool_ready? do
      Mix.Task.run("run", run_argv)
    else
      # config/test.exs is evaluated when Mix starts. Setting the env var in
      # this already-booted VM is too late — re-exec so Repo uses a real pool.
      environment =
        System.get_env()
        |> Map.put("BFE_LOAD_TEST_POOL", "1")
        |> Map.put("MIX_ENV", "test")
        |> Map.merge(extra_environment)

      {_output, exit_code} =
        System.cmd("mix", ["run" | run_argv],
          env: environment,
          into: IO.stream(:stdio, :line)
        )

      if exit_code != 0 do
        Mix.raise("mix test.load failed with exit code #{exit_code}")
      end
    end
  end

  # The client package is a standalone Mix project, so its own deps.get /
  # _build must be driven with a nested `mix` invocation rather than
  # `Mix.Task.run/2` (which would resolve deps into the Engine's own
  # `_build`/`deps` trees).
  @client_package_path "packages/elixir/bfw_engine_client"

  defp run_client_deps_get(_args) do
    {_output, exit_code} =
      System.cmd("mix", ["deps.get"], cd: @client_package_path, into: IO.stream(:stdio, :line))

    if exit_code != 0 do
      Mix.raise("mix deps.get (client package) failed with exit code #{exit_code}")
    end
  end

  defp run_client_quality(_args) do
    {_output, exit_code} =
      System.cmd("mix", ["quality"],
        cd: @client_package_path,
        env: [{"MIX_ENV", "test"}],
        into: IO.stream(:stdio, :line)
      )

    if exit_code != 0 do
      Mix.raise("mix quality (client package) failed with exit code #{exit_code}")
    end
  end

  defp run_release_test(_arguments) do
    System.put_env("BFE_TEST_RELEASE", "1")

    try do
      Mix.Task.rerun("run", [
        "test/integration_runner.exs",
        "--",
        "integration/plugins/plugin_release_test.exs"
      ])
    after
      System.delete_env("BFE_TEST_RELEASE")
    end
  end

  defp run_host_release(arguments) do
    case System.cmd("mix", ["release" | arguments], cd: Path.expand("host"), into: IO.stream()) do
      {_, 0} -> :ok
      {_, exit_code} -> Mix.raise("Release failed with exit code #{exit_code}")
    end
  end
end
