# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,examples}/**/*.{ex,exs}"],
  plugins: [Spark.Formatter, Phoenix.LiveView.HTMLFormatter],
  import_deps: [:ash, :ash_authentication, :plug, :phoenix],
  # Library-owned custom entity; do not export a consumer resource DSL.
  locals_without_parens: [tailscale: 1]
]
