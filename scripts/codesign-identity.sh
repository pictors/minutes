#!/bin/zsh
# 署名 ID を出力する（未設定なら何も出力せず、呼び出し側は ad-hoc 署名にする）。
# 使い方: scripts/codesign-identity.sh [変数名]（既定 CODESIGN_IDENTITY。配布用は DEVELOPER_ID_IDENTITY）
# 優先順位: 環境変数 > .env。固定 ID で署名すると TCC の許可がビルドをまたいで残る（SPEC §11）。無効な ID は ad-hoc に落とさず止める。
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="${1:-CODESIGN_IDENTITY}"
IDENTITY="$(scripts/env-value.sh "$NAME")"
if [[ -z "$IDENTITY" ]]; then
  exit 0
fi
VALID="$(security find-identity -v -p codesigning)"
if [[ "$VALID" != *"$IDENTITY"* ]]; then
  echo "署名 ID が見つからないか無効です（$NAME）: $IDENTITY" >&2
  echo "security find-identity -v -p codesigning で確認してください（Apple Development / Developer ID には中間証明書 WWDR G3 などが必要）。" >&2
  exit 1
fi
print -r -- "$IDENTITY"
