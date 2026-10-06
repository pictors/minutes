#!/bin/zsh
# 配布用の DMG を作る（SPEC §12 Phase 1.5）。Developer ID で署名した Minutes.app を公証して添付し、DMG に入れて、DMG も署名・公証・添付する。
# 使い方: scripts/release.sh [--dry-run]
#   版は Sources/MinutesApp/Info.plist の CFBundleShortVersionString（版）と CFBundleVersion（ビルド番号）。上げるときは先にそこを直してコミットする。
#   署名 ID: 環境変数か .env の DEVELOPER_ID_IDENTITY（"Developer ID Application: <名前> (<チーム ID>)"）
#   公証: 環境変数か .env の NOTARY_PROFILE（`xcrun notarytool store-credentials <名前>` で作ったキーチェーンのプロファイル名）
#   --dry-run: 公証をせず、CODESIGN_IDENTITY（なければ ad-hoc）で署名して、組み立てと DMG の形だけを確かめる
#   自動更新（Sparkle）: DMG に EdDSA で署名し（鍵はキーチェーンのアカウント jp.pictors.minutes。generate_keys で作る）、
#   appcast.xml を作る。公開は GitHub のリリース v<版> に DMG と appcast.xml を載せる（SUFeedURL は最新のリリースの appcast.xml）。
#   出力: .build/dist/Minutes-<版>.dmg、.sha256、Minutes.dmg（公開ページ用の同じ中身の写し）、appcast.xml（同じ bundle id のアプリは .build に残さない）
set -euo pipefail
cd "$(dirname "$0")/.."
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "使い方: scripts/release.sh [--dry-run]" >&2; exit 64 ;;
  esac
done
PLIST=Sources/MinutesApp/Info.plist
REPO_URL=https://github.com/pictors/minutes
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw "$PLIST")"
DIST=.build/dist
APP="$DIST/Minutes.app"
DMG="$DIST/Minutes-$VERSION.dmg"
NOTARY_PROFILE=""
if (( DRY_RUN )); then
  IDENTITY="$(scripts/codesign-identity.sh)"
else
  IDENTITY="$(scripts/codesign-identity.sh DEVELOPER_ID_IDENTITY)"
  if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
    echo "DEVELOPER_ID_IDENTITY に Developer ID Application の証明書を設定してください（security find-identity -v -p codesigning に出る名前）。" >&2
    exit 1
  fi
  NOTARY_PROFILE="$(scripts/env-value.sh NOTARY_PROFILE)"
  if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "NOTARY_PROFILE に公証のプロファイル名を設定してください（xcrun notarytool store-credentials で作る）。" >&2
    exit 1
  fi
  # 配ったものとソースを一致させる
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "未コミットの変更があります。コミットしてから実行してください。" >&2
    exit 1
  fi
fi
echo "Minutes $VERSION ($BUILD)$( (( DRY_RUN )) && echo '（dry run: 公証しない）')"
rm -rf "$DIST"
MINUTES_DIST_IDENTITY="$IDENTITY" scripts/build-app.sh release --dist

# 配布するアプリの中身を確かめる: Apple Silicon 向けで、デバッガを許す entitlement がない
lipo -archs "$APP/Contents/MacOS/Minutes"
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  echo "get-task-allow の entitlement が入っています（配布できません）" >&2
  exit 1
fi

notarize() {  # $1: 送るファイル（zip か dmg）
  local log="$DIST/notary-${1:t}.json"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$log"
  local result
  result="$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d.get("status", ""), d.get("id", ""))' "$log")"
  if [[ "${result%% *}" != "Accepted" ]]; then
    echo "公証に通りませんでした（${result%% *}）: $1" >&2
    [[ -n "${result#* }" ]] && xcrun notarytool log "${result#* }" --keychain-profile "$NOTARY_PROFILE" >&2
    exit 1
  fi
  echo "notarized: ${1:t}"
}

if (( ! DRY_RUN )); then
  # アプリにも公証の証明を添付する（DMG から移したあと、オフラインでも Gatekeeper を通る）
  ditto -c -k --keepParent "$APP" "$DIST/Minutes-notarize.zip"
  notarize "$DIST/Minutes-notarize.zip"
  rm "$DIST/Minutes-notarize.zip"
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

# DMG: アプリと /Applications への別名を並べる
STAGE="$DIST/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Minutes.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Minutes $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi
if (( ! DRY_RUN )); then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
rm -rf "$APP"
(cd "$DIST" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256" && cat "${DMG:t}.sha256")
# 公開ページの「ダウンロード」は最新のリリースの Minutes.dmg を指す（名前に版を入れない写し）
cp "$DMG" "$DIST/Minutes.dmg"

# 自動更新の情報。キーチェーンの鍵を初めて使うとき、macOS が sign_update に使ってよいかを尋ねる
ENCLOSURE="$("$SPARKLE_BIN/sign_update" --account jp.pictors.minutes "$DMG")"
if [[ "$ENCLOSURE" != *"sparkle:edSignature="* ]]; then
  echo "DMG に EdDSA で署名できませんでした（$SPARKLE_BIN/generate_keys --account jp.pictors.minutes で鍵を確かめてください）" >&2
  exit 1
fi
MIN_OS="$(plutil -extract LSMinimumSystemVersion raw "$PLIST")"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
cat > "$DIST/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Minutes</title>
    <link>$REPO_URL</link>
    <item>
      <title>Minutes $VERSION</title>
      <link>$REPO_URL/releases/tag/v$VERSION</link>
      <description><![CDATA[<p>変更点は <a href="$REPO_URL/releases/tag/v$VERSION">リリースノート</a> を見てください。</p>]]></description>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <enclosure url="$REPO_URL/releases/download/v$VERSION/${DMG:t}" type="application/octet-stream" $ENCLOSURE />
    </item>
  </channel>
</rss>
XML
xmllint --noout "$DIST/appcast.xml"
echo "built: $DMG"
echo "       $DIST/appcast.xml・$DIST/Minutes.dmg（GitHub のリリース v$VERSION に、版つきの DMG と一緒に載せる）"
