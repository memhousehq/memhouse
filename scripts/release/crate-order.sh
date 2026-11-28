#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Print the workspace's publishable crates, one per line, in the order crates.io accepts them:
# each after every workspace crate it depends on, dev-dependencies included (cargo keeps a
# dev-dependency that has a version, and crates.io must already have that version). Crates
# that are ready at the same time come in name order. A dependency cycle stops here.
#
#   scripts/release/crate-order.sh
set -eu
cd "$(dirname "$0")/../.."
cargo metadata --format-version 1 --no-deps --locked | jq -r '
  [.packages[] | select(.publish != []) | {name, deps: ([.dependencies[] | select(.path != null) | .name] | unique)}] as $crates
  | ($crates | map(.name)) as $names
  | def order($done; $rest):
      if ($rest | length) == 0 then $done
      else
        [$rest[] | select(all(.deps[]; IN($done[]) or (IN($names[]) | not)))] as $ready
        | if ($ready | length) == 0 then error("dependency cycle among \($rest | map(.name))")
          else order($done + ($ready | map(.name) | sort); [$rest[] | select(.name | IN($ready[].name) | not)])
          end
      end;
    order([]; $crates) | .[]'
