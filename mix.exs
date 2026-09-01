defmodule EvilEngine.Umbrella.MixProject do
  @moduledoc """
  Umbrella root for the Evil Engine — a BPMN 2.0 workflow engine.

  Each subsystem lives under `apps/` as its own OTP application, per the
  Domain-Driven layout described in `docs/ImplementationPlan.md` §2.

  This root project only carries:
    * cross-app tooling (credo, dialyxir, ex_doc, sobelow, mix_audit,
      excoveralls)
    * release configuration (`mix release`)
    * aliases that fan the usual commands out to every app

  External runtime deps are declared per-app so each application remains
  independently buildable and the domain boundaries stay honest.
  """

  use Mix.Project

  @version "0.0.1"

  def project do
    [
      apps_path: "apps",
      version: @version,
      name: "Evil Engine",
      source_url: "https://github.com/ElRaptorus/ThomasTheDaemonEngine",
      homepage_url: "https://github.com/ElRaptorus/ThomasTheDaemonEngine",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      test_coverage: [tool: ExCoveralls, threshold: 0],
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

          # Specification
          "docs/ImplementationPlan.md",
          "docs/ImplementationPhases.md",

          # Reference
          "docs/Architecture.md",
          "docs/Schema.md",
          "docs/Glossary.md",
          "docs/Philosophy.md",

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
          "docs/architecture/common-pitfalls.md",
          "docs/architecture/dmn.md",
          "docs/architecture/sdk-client.md",
          "docs/architecture/timers.md",
          "docs/architecture/persistence.md"
        ],
        groups_for_extras: [
          "Getting Started": ~r{docs/guides/getting-started/},
          "User Handbook": ~r{docs/guides/handbook/},
          "API Reference": ~r{docs/guides/api/},
          "Plugin Development": ~r{docs/guides/plugins/},
          "Operations Guide": ~r{docs/guides/operations/},
          Cheatsheets: ~r{docs/guides/cheatsheets/},
          Specification: ~r{docs/Implementation},
          Reference: ~r{docs/(Architecture|Schema|Glossary|Philosophy)\.md},
          "Architecture (Detailed)": ~r{docs/architecture/}
        ],
        groups_for_modules: [
          "Core — Types": ~r{EvilEngine\.Types\.},
          "Core — Execution": ~r{EvilEngine\.Execution\.},
          "Core — Expressions": ~r{EvilEngine\.Expressions},
          "Core — BPMN": ~r{EvilEngine\.BPMN\.},
          "Core — DMN": ~r{EvilEngine\.DMN\.},
          "Core — Timers": ~r{EvilEngine\.Timers\.},
          "Core — Events": ~r{EvilEngine\.Events\.},
          "Peripheral — Persistence": ~r{EvilEngine\.Persistence\.},
          "Peripheral — Telemetry": ~r{EvilEngine\.Telemetry\.},
          "Peripheral — Plugins": ~r{EvilEngine\.Plugins\.},
          "API — HTTP": ~r{EvilEngineWeb\.Http\.},
          "API — GraphQL": ~r{EvilEngineWeb\.Graphql\.},
          "API — WebSocket": ~r{EvilEngineWeb\.WebSocket\.},
          "API — Auth": ~r{EvilEngine\.Auth\.},
          SDK: ~r{EvilEngine\.(SDK|Plugin\.|EngineFacade)}
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
        "test.cookbook": :test,
        "test.conformance": :test,
        "test.coverdata": :test,
        "test.full": :test,
        quality: :test
      ]
    ]
  end

  defp deps do
    [
      {:logger_json, "~> 7.0", only: :prod},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "deps.patch", "deps.compile.sat"],
      "deps.patch": &apply_dep_patches/1,
      "deps.compile.sat": ["deps.compile simple_sat", "deps.compile crux --force"],
      "ecto.setup": ["do --app peripheral_persistence ecto.setup"],
      "ecto.reset": ["do --app peripheral_persistence ecto.reset"],

      # --- Test aliases -----------------------------------------------------
      "test.unit": ["test --exclude integration"],
      "test.examples": ["test apps/peripheral_plugins/test/examples/"],
      "test.integration": ["run test/integration_runner.exs"],
      "test.cookbook": ["run test/integration_runner.exs -- integration/plugins"],
      "test.load": ["run test/load_runner.exs"],
      "test.conformance": ["run test/conformance_runner.exs"],
      # Integration + conformance under one :cover session; exports
      # cover/umbrella.coverdata (and copies it into each apps/*/cover/).
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
      # coveralls.* --import-cover step runs per-app unit tests and merges
      # that coverdata. CI uses the same pair with `coveralls` (terminal)
      # instead of `coveralls.html`.
      quality: [
        "compile --warnings-as-errors",
        "evil.gen.extension_manifest --check",
        "credo --strict",
        "dialyzer",
        "sobelow",
        "docs --warnings-as-errors",
        "test.coverdata",
        "coveralls.html --umbrella --import-cover cover"
      ],

      # --- CI pipeline ------------------------------------------------------
      "lint.ci": [
        "format --check-formatted",
        "credo --strict",
        "deps.audit"
      ],
      lint: ["format", "credo"],
      sobelow: [
        "sobelow --root apps/api_web --router apps/api_web/lib/evil_engine_web/http/router.ex --skip Config.HTTPS --threshold medium"
      ]
    ]
  end

  defp apply_dep_patches(_args) do
    target = "deps/ex_doc/lib/mix/tasks/docs.ex"

    if File.exists?(target) do
      content = File.read!(target)

      patched =
        String.replace(
          content,
          "Code.prepend_path(source_beams)",
          "Code.prepend_paths(source_beams)"
        )

      if patched != content do
        File.write!(target, patched)
        Mix.shell().info("Patched ex_doc: Code.prepend_path → Code.prepend_paths (umbrella fix)")
        Mix.Task.run("deps.compile", ["ex_doc", "--force"])
      end
    end
  end

  defp releases do
    [
      evil_engine: [
        version: @version,
        applications: [
          # Logging (root dep, must be explicit for umbrella releases)
          logger_json: :permanent,
          # Core
          core_types: :permanent,
          core_expressions: :permanent,
          core_timers: :permanent,
          core_events: :permanent,
          core_bpmn: :permanent,
          core_dmn: :permanent,
          core_execution: :permanent,
          # Peripheral
          peripheral_persistence: :permanent,
          peripheral_telemetry: :permanent,
          peripheral_plugins: :permanent,
          # Public SDK (no supervision tree of its own, but consumed by
          # peripheral_plugins, so it must start with the rest of the
          # release).
          engine_sdk: :permanent,
          # API (started last so the engine is fully hot before opening ports)
          api_auth: :permanent,
          api_facade: :permanent,
          api_web: :permanent
        ],
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ]
    ]
  end
end
