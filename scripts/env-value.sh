#!/bin/zsh
# 環境変数か .env から値を読む（環境変数が優先）。使い方: scripts/env-value.sh NAME
# .env の書き方は DotEnv.parse と同じ（`NAME=値`、`export NAME=値`、前後の同じクォートは外す）。
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="$1"
VALUE="${(P)NAME:-}"
if [[ -z "$VALUE" && -f .env ]]; then
  VALUE="$(sed -n -E "s/^(export[[:space:]]+)?${NAME}[[:space:]]*=[[:space:]]*//p" .env | tail -n 1)"
  if [[ "$VALUE" == \"*\" || "$VALUE" == \'*\' ]]; then VALUE="${VALUE:1:-1}"; fi
fi
print -r -- "$VALUE"
