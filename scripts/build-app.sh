#!/bin/zsh
# Minutes.app を SwiftPM のビルド成果物から組み立てて署名する。
# 使い方: scripts/build-app.sh [debug|release] [--install | --dist]（既定 release）
#   署名 ID は環境変数か .env の CODESIGN_IDENTITY（scripts/codesign-identity.sh）。固定 ID で署名すると TCC の許可が持続する。
#   --install: 組み立てた .app を /Applications/Minutes.app へ移す（MINUTES_INSTALL_DIR で変更可）。Minutes の起動中は中止する。
#   --dist: 配布用（scripts/release.sh が使う）。.build/dist/Minutes.app に組み立て、MINUTES_DIST_IDENTITY の ID で
#           Hardened Runtime・--timestamp を付けて署名する。空なら ad-hoc。
#   開発用（--dist なし）は自動更新を使わないよう Info.plist から SUFeedURL を外す（署名の違う公式の版に置き換えない）。
#   署名は内側（Sparkle.framework の中）から順に行い、--deep に頼らない（Sparkle の説明どおり）。
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=release
INSTALL=0
DIST=0
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --install) INSTALL=1 ;;
    --dist) DIST=1 ;;
    *) echo "使い方: scripts/build-app.sh [debug|release] [--install | --dist]" >&2; exit 64 ;;
  esac
done
if (( INSTALL && DIST )); then
  echo "--install と --dist は同時に使えません" >&2
  exit 64
fi
INSTALL_DIR="${MINUTES_INSTALL_DIR:-/Applications}"
if (( INSTALL )); then
  # 録音中に止めないよう自動では終了させない（起動中に差し替えても古い版が動き続ける）
  if pgrep -x Minutes >/dev/null; then
    echo "Minutes が起動中です。録音中でないことを確かめて終了してから、もう一度実行してください。" >&2
    exit 1
  fi
  if [[ ! -w "$INSTALL_DIR" ]]; then
    echo "$INSTALL_DIR に書き込めません（MINUTES_INSTALL_DIR で入れ先を変えられます）。" >&2
    exit 1
  fi
fi
if (( DIST )); then
  IDENTITY="${MINUTES_DIST_IDENTITY:-}"
  APP=".build/dist/Minutes.app"
else
  IDENTITY="$(scripts/codesign-identity.sh)"
  APP=".build/Minutes.app"
fi
swift build -c "$CONFIG" --product MinutesApp
scripts/build-icons.sh
BUILD_DIR=".build/$CONFIG"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/MinutesApp" "$APP/Contents/MacOS/Minutes"
cp Sources/MinutesApp/Info.plist "$APP/Contents/Info.plist"
cp .build/brand/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# ライセンスと帰属表示（設定 > 情報 の「全文」で表示する）
cp LICENSE NOTICE "$APP/Contents/Resources/"
# SwiftPM のリソースバンドル（MinutesCore のプロンプトなど）
for bundle in "$BUILD_DIR"/*.bundle; do
  [[ -d "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done
# 自動更新（Sparkle）。サンドボックスを使わないので XPC サービスは要らない（Sparkle の説明に従って外す）
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BUILD_DIR/Sparkle.framework" "$SPARKLE"
rm -rf "$SPARKLE/XPCServices" "$SPARKLE/Versions/B/XPCServices"
if (( ! DIST )); then
  plutil -remove SUFeedURL "$APP/Contents/Info.plist"
fi
# 配布先の Mac にはビルドディレクトリがない。アプリが使うリソースが .app の中にあることを確かめる
for required in \
  "$APP/Contents/Resources/minutes_MinutesCore.bundle/Resources/Prompts/summarize_ja.md" \
  "$APP/Contents/Resources/minutes_MinutesApp.bundle/Resources/Brand/MinutesLogo.png" \
  "$APP/Contents/Resources/LICENSE" \
  "$APP/Contents/Resources/NOTICE" \
  "$SPARKLE/Versions/B/Sparkle" \
  "$SPARKLE/Versions/B/Autoupdate"; do
  if [[ ! -f "$required" ]]; then
    echo "リソースが .app に入っていません: ${required#$APP/}" >&2
    exit 1
  fi
done
# 署名。固定 ID なら Hardened Runtime、配布用はさらに --timestamp。ad-hoc は Hardened Runtime なし
sign() {
  local -a args=(--force)
  if [[ -n "$IDENTITY" ]]; then
    args+=(--sign "$IDENTITY" --options runtime)
    (( DIST )) && args+=(--timestamp)
  else
    args+=(--sign -)
  fi
  codesign "${args[@]}" "$@"
}
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --entitlements Sources/MinutesApp/Minutes.entitlements --identifier jp.pictors.minutes "$APP"
codesign --verify --strict --deep --verbose=1 "$APP"
if [[ -n "$IDENTITY" ]]; then
  echo "signed with: $IDENTITY"
elif (( DIST )); then
  echo "ad-hoc signed（配布には使えません）"
else
  echo "ad-hoc signed（TCC の許可はビルドごとにリセットされます。.env か環境変数で CODESIGN_IDENTITY を設定してください）"
fi
if (( INSTALL )); then
  # 同じ bundle id の複製を .build に残さないよう移す。差し替えは入れ先での名前変更にして、途中で失敗しても前の版を残す
  TARGET="$INSTALL_DIR/Minutes.app"
  STAGING="$INSTALL_DIR/.Minutes.app.installing"
  rm -rf "$STAGING"
  mv "$APP" "$STAGING"
  rm -rf "$TARGET"
  mv "$STAGING" "$TARGET"
  echo "installed: $TARGET"
  echo "run:       open $TARGET"
else
  echo "built: $APP"
  echo "run:   open $APP"
fi
