#!/bin/zsh
# minutes-cli を release ビルドし、固定の署名を付ける。
# TCC（マイク / システム音声録音）の許可は署名に紐づくため、ad-hoc 署名だとビルドごとにリセットされる（SPEC §11）。
# 使い方: scripts/build-cli.sh（署名 ID は環境変数か .env の CODESIGN_IDENTITY。scripts/codesign-identity.sh）
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="$(scripts/codesign-identity.sh)"
swift build -c release --product minutes-cli
BIN=".build/release/minutes-cli"
if [[ -n "$IDENTITY" ]]; then
  # Hardened Runtime ではマイクの entitlement がないと TCC が拒否する
  codesign --force --sign "$IDENTITY" --identifier jp.pictors.minutes.cli --options runtime --entitlements Sources/minutes-cli/minutes-cli.entitlements "$BIN"
  echo "signed with: $IDENTITY"
else
  codesign --force --sign - --identifier jp.pictors.minutes.cli "$BIN"
  echo "ad-hoc signed (TCC の許可はビルドごとにリセットされます。.env か環境変数で CODESIGN_IDENTITY を設定してください)"
fi
echo "built: $BIN"
"$BIN" version
