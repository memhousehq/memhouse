# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0
#
# `mix format` configuration. CI runs `mix format --check-formatted`, so an
# unformatted file fails the build.

[
  # These libraries export macros that read better without parentheses
  # (`attribute :name, :string`, `plug :fetch_session`). Importing their
  # formatter rules stops the formatter from adding parens back and creating
  # churn on every DSL block.
  import_deps: [:ash, :ash_postgres, :ecto, :ecto_sql, :phoenix],
  # Generated migrations ship their own .formatter.exs; let it win there.
  subdirectories: ["priv/*/migrations"],
  inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}", "priv/*/seeds.exs"]
]
