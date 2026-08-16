#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

for src in *.mmd; do
  out="${src%.mmd}.png"
  echo "$src -> $out"
  npx -y @mermaid-js/mermaid-cli -i "$src" -o "$out" -b white -s 2
done
