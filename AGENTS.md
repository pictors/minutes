# Minutes — 開発メモ

このリポジトリで作業する人とコーディングエージェント（Claude Code、Codex など）向けの手順・構成・決まり。設計は `docs/SPEC.md`。迷ったらそこに戻る。

## 現在の段階

**Phase 1.5 — 公開準備**。段階と完了条件は SPEC §12。Phase 1（アプリ MVP）は 2026-09-30 に完了した。final の既定プロバイダは ElevenLabs Scribe v2、要約の既定は Codex app server。

## 環境

- macOS 26 以降（SpeechAnalyzer）、Xcode 26 以降、Swift 6（言語モード 6）。Apple Silicon。
- 依存: GRDB.swift、FluidAudio（ローカル話者分離）。それ以外は Apple フレームワークのみ。swift-argument-parser は使わず `Sources/MinutesCore/Support/ArgumentParser.swift` の最小実装を使う。
- 秘密情報: `.env`（`.gitignore` 済み、`.env.example` を参照）または環境変数。`ELEVENLABS_API_KEY` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY`。コードにもリポジトリにも入れない。アプリは 設定 > プロバイダ で Keychain に登録する。

## コマンド

```bash
swift build                                  # Core + CLI + App（debug）
swift test                                   # 単体テスト（TCC / ネットワーク / 実 API に依存しない）
swift build -c release --product minutes-cli # 60 分録音や CER 計算は release で
scripts/build-cli.sh                         # CLI の release ビルド + 署名（.env / 環境変数の CODESIGN_IDENTITY で固定 ID 署名すると TCC 許可が持続する）
scripts/build-app.sh                         # Minutes.app を組み立てて署名 → open .build/Minutes.app
scripts/build-app.sh --install               # 組み立てて /Applications/Minutes.app へ移す（Minutes の起動中は中止。API キーは Keychain から読む）
python3 scripts/check-public.py              # 禁止語の検査（個人環境・実会議の情報・秘密情報）。--all-history で全履歴とコミットメッセージ
(cd site && npm ci && npm run build)        # 公開ページの CSS（Tailwind CSS）を site/assets/site.css に作る。直しながら見るときは npm run dev
python3 -m http.server 8787 --directory site   # 公開ページを手元で見る（外部のフォント・解析は読み込まない。画面の写真は架空の会議で撮る）
python3 scripts/site-en.py                   # 日本語のページ（site/index.html）から英語のページを作り直す。日本語の文を変えたら先にスクリプトの対応する行を直す
scripts/release.sh                           # 配布用の DMG と appcast.xml: Developer ID で署名 → アプリを公証・添付 → DMG を署名・公証・添付 → Sparkle の EdDSA 署名（.env の DEVELOPER_ID_IDENTITY と NOTARY_PROFILE。版は Info.plist）
scripts/release.sh --dry-run                 # 公証せず、組み立てと DMG の形だけを確かめる（CODESIGN_IDENTITY か ad-hoc で署名）
.build/release/minutes-cli bench --seconds 120   # 録音中の書き出し処理の CPU を合成音声で測る（デバイス・許可は不要）
python3 scripts/cpu-breakdown.py ~/Library/Application\ Support/Minutes/audio/<会議 id>   # 録音中の CPU を画面の状態・スレッドごとに集計（G7）
```

App のデータ: `~/Library/Application Support/Minutes/`（`minutes.sqlite`、`settings.json`、`audio/<meeting id>/`、`export/`、`voices/`）。API キーは Keychain（設定画面）か `.env`。

CLI の実行例（release ビルド後、バイナリは `.build/release/minutes-cli`）:

```bash
# 録音（Ctrl-C で停止）。録音対象は `processes`、マイクは `devices` で確認できる
.build/release/minutes-cli processes --app com.google.Chrome
.build/release/minutes-cli devices                       # マイク入力デバイスの uid（record --mic-device <uid>）
.build/release/minutes-cli record --app com.google.Chrome --out recordings/2026-09-16_weekly
.build/release/minutes-cli record --app com.google.Chrome --duration 3600 --out recordings/soak   # 60 分 dropout 検証

# ライブ字幕（遅延計測）
.build/release/minutes-cli assets --install
.build/release/minutes-cli live --app com.google.Chrome --out recordings/live-test
.build/release/minutes-cli live --file fixtures/sample_meeting/system_16k.wav   # 録音なしで live 経路を評価（--fast で最速）

# final 文字起こしと評価
.build/release/minutes-cli transcribe recordings/2026-09-16_weekly --provider elevenlabs
.build/release/minutes-cli transcribe recordings/2026-09-16_weekly --provider openai
.build/release/minutes-cli transcribe recordings/2026-09-16_weekly --provider local
.build/release/minutes-cli eval recordings/2026-09-16_weekly/transcript.elevenlabs.json reference.txt --json

# アプリと同じ後処理パイプラインを録音フォルダに掛ける（--db で別 DB も可）
.build/release/minutes-cli process recordings/2026-09-16_weekly --provider elevenlabs --title "週次定例"
.build/release/minutes-cli process recordings/2026-09-16_weekly --summary-only   # 保存済み本文から要約だけやり直す（編集・根拠 ID を保持）
.build/release/minutes-cli process recordings/2026-09-16_weekly --summary-provider claude-code   # 要約の手段: codex（既定）/ claude-code / anthropic / none

# 既存の録音（ほかのサービスで録ったものなど）から評価区間を切り出して 3 プロバイダを比較する
.build/release/minutes-cli cut recordings/external/meeting.m4a recordings/external/cut/system_16k.wav --start 10:00 --duration 600
python3 scripts/reference-from-transcript.py recordings/external/meeting.transcript.json --start 10:00 --end 20:00 --out recordings/external/cut/reference.txt
for p in elevenlabs openai local; do .build/release/minutes-cli transcribe recordings/external/cut --provider $p --num-speakers 3; done
for p in elevenlabs openai local; do .build/release/minutes-cli eval recordings/external/cut/transcript.$p.json recordings/external/cut/reference.txt --strip-speaker-prefix --json; done
for p in elevenlabs openai local; do python3 scripts/speaker-agreement.py recordings/external/cut/transcript.$p.json recordings/external/cut/reference.speakers.json; done

# TTS fixture（実会議を使わない動作確認）
python3 scripts/make-fixtures.py
.build/release/minutes-cli transcribe fixtures/sample_meeting --provider local --num-speakers 2
.build/release/minutes-cli eval fixtures/sample_meeting/transcript.local.json fixtures/sample_meeting/reference.txt --strip-speaker-prefix
```

`eval --track system|mic` は参照テキストが全会話の場合は意味を持たない（トラック別の参照が必要）。比較は `--track all` で行う。

## レイアウト

```
Sources/MinutesCore/         UI 非依存のロジック（CLI と App の両方から使う）
  Audio/                     ProcessTap, MicCapture（入力デバイス指定・一覧）, TrackPipeline（整合・欠落補完・AAC/WAV）, RecordingSession, AudioProcessList
  Transcription/             BatchTranscriber 実装（ElevenLabs / OpenAI / Local）, SpeechAnalyzer ラッパ（録音中の言語の切り替え）, MeetingLanguage（会議の言語と自動判定）, TrackMerger, TranscriptDocument
  Eval/                      CER
  Support/                   ArgumentParser, DotEnv, Multipart, HostClock, JSON, Log, AppSettings, Diagnostics（診断情報の書き出し）
  Store/                     GRDB レコード・スキーマ・Store・音声保持
  Session/                   SessionStateMachine、MeetingSessionController、VoiceSampleExtractor
  Pipeline/                  PostProcessPipeline（8 ステップ、pipeline_runs で再開）、PostProcessingQueue
  Library/                   MeetingDetailModel（会議詳細のデータ・操作。DB を監視して画面へ反映）、BackgroundVoices（背景の声の音量・候補・除外）
  Summarize/                 MinutesSummary、CodexSummarizer、ClaudeCodeSummarizer（claude -p）、ClaudeSummarizer（API）、Resources/Prompts/summarize_ja.md
  Export/                    MeetingExporter、ExportManifest、SyncTarget（LocalDirectory）
Sources/minutes-cli/         評価・検証用の CLI（Info.plist をリンカで埋め込む）
Sources/MinutesApp/          SwiftUI アプリ（AppModel、OnboardingModel・SetupChecks（初回の案内）、CalendarService、MeetingDetector、GlobalHotKey、Views/）。Info.plist と entitlements は build-app.sh が使う
Tests/MinutesCoreTests/      単体テスト（golden JSON は Fixtures/）
fixtures/                    TTS 生成の模擬会議（実会議の音声は入れない）
scripts/                     ビルド・署名、配布（release.sh）、評価、禁止語の検査（check-public.py）
docs/                        SPEC.md、CLI.md
site/                        公開ページ（minutes.tools、日本語と英語。CSS は Tailwind CSS（src/site.css → assets/site.css）。.github/workflows/pages.yml が CSS を作って GitHub Pages に出す）
```

## ルール

- 外部 API のシグネチャは実装前に公式ドキュメント / SDK の swiftinterface で確認する（確認済みの内容は各ファイル冒頭のコメントに記す）。
- 識別子・ファイル名は英語、コメント・文書・コミットメッセージは日本語でよい。
- ログに API キー・音声・本文を出さない（本文は `Log.preview` で先頭 40 文字まで）。
- 実会議の音声・会議名・参加者名・発言を、コード・テスト・文書・コミットメッセージに入れない。テストの会議と人名は架空のものにする。コミットやプッシュの前に `python3 scripts/check-public.py` を通す（語の一覧はリポジトリの外、`~/.config/minutes/private-terms.txt`。会議名などは Minutes の DB から読む）。
- コミットメッセージに AI の関与を示す表記を入れない。
- 性能のために UI の動きを削らない。止まらないアニメーションは、同じ見た目のまま AppKit / Core Animation で描く（`AnimatedSymbol`・`LevelMeter`・`RollingTimerView`）。SwiftUI の状態は表示が変わるときだけ替える（`LevelFeed`）。

## 実行時の注意

- TCC: `record` / `live` はマイクと「システムオーディオ録音」の許可が必要。ターミナルから起動した場合、許可はターミナルアプリ（責任プロセス）に紐づく。ad-hoc 署名のバイナリはビルドごとに許可がリセットされるので、継続利用は `CODESIGN_IDENTITY`（`.env` か環境変数。Apple Development 証明書で可）を設定した `scripts/build-cli.sh` / `scripts/build-app.sh` で。無効な ID はビルド前に止まる（`scripts/codesign-identity.sh`）。
- Process Tap は「タブ単位」の切り出しができない。会議は専用ブラウザで開く運用（初回の案内と README）。
- SpeechAnalyzer の日本語モデルと FluidAudio のモデルは初回にダウンロードされる（`assets --install`、`transcribe --provider local` の初回、アプリの初回の案内）。
- 最初の起動では初回の案内（`OnboardingView`）が開き、終えるまで自動録音を準備しない。会議がすでにある環境では出さない。設定 > 診断 から開き直せる。
- 会議の言語（日本語・英語、SPEC §5.5）: 会議ごとに `meetings.language` を持ち、ライブ字幕・確定の文字起こし・要約・書き出しが従う。自動は日本語のライブ字幕で始め、後処理の文字起こしの前に字幕の文字の種類で判定する（`MeetingLanguageDetector`）。録音中の切り替えは `LiveLocaleControl` で認識器を開き直す。日本語は後処理の指紋と要約の入力に値を足さない（足すと既存の会議がすべて文字起こしし直しになる）。英語のライブ字幕のモデルは初めて英語を選んだときにダウンロードする。
- 自動更新は Sparkle（`Updates.swift`）。配布用のビルド（`build-app.sh --dist`）だけが SUFeedURL を持ち、開発用のビルドと `swift run` では動かさない。Sparkle.framework は XPC サービスを外して内側から署名する。更新の DMG は EdDSA で署名する（鍵はキーチェーンのアカウント `jp.pictors.minutes`。公開鍵は Info.plist の SUPublicEDKey）。版を上げるときは Info.plist の CFBundleShortVersionString と CFBundleVersion（数字、毎回増やす）を直す。

## 要約（Codex / Claude Code / Anthropic）

- 要約の既定は Codex app server。`codex login` と設定の「接続を確認」を使う。Claude Code（`claude -p`、Claude Code のログイン）と Anthropic API（キー）も選べる。「要約しない」なら文字起こしまで。
- GUI 起動時も実行ファイルを探せるよう、デスクトップアプリ同梱 CLI / PATH / ~/.local/bin / Homebrew を確認する。設定の実行ファイルはポップアップ（自動検出 / 見つかった CLI（版つき）/ その他…）で選ぶ（`ExecutablePickerRow`。候補は `SummaryCLI.candidates()` で自動検出と同じ順）。
- モデルは設定のピッカーで選ぶ。Codex は app-server の `model/list`（非表示を除く）、Claude Code は接続確認で `claude -p --input-format stream-json` に制御要求（`initialize` の `models`、`get_context_usage` の `model`）だけを送って読む（推論・送信なし）。未選択はそれぞれの CLI の設定に従う。
- 要約・書き出しの失敗は会議を failed にせず警告（`PipelineOutcome.warnings`）として残す。録音準備（armed）中の mic 音声は `meetings.recording_started_at` と `started_at` の差で後処理から除外する。
- 通常の `swift test` は実 API を呼ばない。次の任意テストは架空の会議だけを送る（一覧の読み取りは送信なし）:
  - `MINUTES_CODEX_LIVE=1 swift test --filter CodexSummarizerTests.liveSmoke`（`MINUTES_CODEX_MODEL=<id>`）
  - `MINUTES_CLAUDE_CODE_LIVE=1 swift test --filter ClaudeCodeSummarizerTests.liveSmoke`（`MINUTES_CLAUDE_CODE_MODEL=<alias>`）
  - `MINUTES_CLAUDE_CODE_LIVE=1 swift test --filter ClaudeCodeSummarizerTests.liveModels`
- CLI の品質検証は `python3 scripts/test-transcribe-validation.py .build/debug/minutes-cli`。
- `MINUTES_SPEECH_LIVE=1 swift test --filter LiveLocaleRestartTests` は、実際の SpeechAnalyzer で録音中の言語の切り替え（認識器の開き直し）を確かめる任意テスト（fixtures/sample_meeting の音声を使う。送信なし、新しいモデルも落とさない）。
