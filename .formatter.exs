# Umbrella-wide formatter config.
# Per-app .formatter.exs files import this via `import_deps: [:phoenix, :ash, ...]`
# where appropriate — see apps/*/.formatter.exs.
[
  inputs: [
    "{mix,.formatter,.credo}.exs",
    "config/*.{ex,exs}"
  ],
  subdirectories: ["apps/*"]
]
