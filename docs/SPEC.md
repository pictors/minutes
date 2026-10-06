# Minutes — 設計

- 対象: Minutes を開発する人（コーディングエージェントを含む）
- 状態: v0.3（2026-10-05）
- 開発の手順・コマンド・構成は `AGENTS.md`

---

## 0. 開発の進め方

- この文書が「何を・なぜ・どの順で」作るかの基準。迷ったらここに戻る。
- 外部 API（Apple Speech / ElevenLabs / OpenAI / Anthropic / Codex app server / Claude Code）の正確なシグネチャやパラメータ名は、**実装前に必ず公式ドキュメント（§16）で確認する。** この文書の API 記述は方向性であり、細部はドキュメントが正。
- 秘密情報（API キー）はコードにもリポジトリにも入れない。Keychain または `.env`（`.gitignore` 済み）から読む。
- 実会議の音声・会議名・参加者名・発言はリポジトリに入れない。公開する前に `scripts/check-public.py`（禁止語の検査）を通す。
- 識別子・ファイル名は英語。コメント・文書・コミットメッセージは日本語でよい。
- 設計を変えたら、この文書を合わせて直す。

---

## 1. 目的とゴール

### 1.1 目的

Google Meet・Microsoft Teams・Zoom などのオンライン会議を Mac 上でローカルに録音し、話者付きの文字起こしと要約を Notes 風の UI で検索できるようにする。会議の記録は Markdown と JSON で書き出し、ほかのツールに渡せる（§7.3、§9）。

2026-09-30 に、OSS（Apache-2.0）として公開し、公式ビルドを配ることを決めた（§17、Phase 1.5）。

### 1.2 成功条件（測れる目標）

| # | 目標 | 判定方法 |
|---|---|---|
| G1 | 60 分の会議を音切れ・クラッシュなしで録音できる | 実会議 3 本、サンプル数で dropout 検証 |
| G2 | 会議中のライブ字幕が発話から 2 秒以内に追従する | ログの遅延計測（中央値） |
| G3 | 確定版の文字起こしと要約が会議終了から 5 分以内に完成する | pipeline_runs のタイムスタンプ |
| G4 | 話者ラベルは「自分」が 100%、相手側は手動修正 1〜2 クリックで全員名前付きになる | 実会議 3 本 |
| G5 | 全文検索が過去 100 会議分でも 100 ms 以内に返る | ベンチマーク |
| G6 | 会議終了から 10 分以内に、連携先にアクション候補が根拠リンク付きで届く | Phase 2 で確認 |
| G7 | 録音中の CPU 使用率が平均 20% 未満（Apple Silicon） | ログ（`scripts/cpu-breakdown.py`）/ Activity Monitor |

### 1.3 非目標（今は作らない）

- 会議に Bot を参加させる方式（Recall.ai 型）
- リアルタイムの話者分離（ライブ字幕は話者なしで良い）
- iOS / Windows 版、Mac App Store 配布
- 会議アプリ自体の制御（ミュート等）
- 自前の LLM 推論基盤

---

## 2. 前提・制約

- 録音する Mac: Apple Silicon、**macOS 26 以降**（SpeechAnalyzer 使用のため）。Xcode 26 以降。
- 会議は日本語が主。英語混在は Phase 3 の課題。
- 会議アプリ: Google Meet（ブラウザ）、Microsoft Teams（デスクトップ版またはブラウザ）、Zoom などのデスクトップアプリ。
- 言語: Swift 6 / SwiftUI。UI 以外のロジックは `MinutesCore`（SwiftPM ライブラリ）に置き、CLI と App の両方から使う。
- App Sandbox: 無効（Process Tap、外部 CLI の起動、柔軟なファイル書き出しのため）。配布は Developer ID 署名 + 公証（Phase 1.5）。
- 依存パッケージは最小限: GRDB.swift（SQLite）、FluidAudio（ローカル話者分離）。HTTP は URLSession。Phase 1.5 で Sparkle（自動更新）を加える。

---

## 3. アーキテクチャ

### 3.1 全体像

```
[Minutes.app]
  MeetingDetector ─┐
  CalendarService ─┼→ Session（会議 1 回分の状態機械）
  AudioCapture ────┘   ├ system track（会議アプリの音 / Core Audio Process Tap）
                       ├ mic track（自分の声 / AVAudioEngine）
                       ├ LiveTranscriber（SpeechAnalyzer）→ segments(source=live)
                       └ 終了 → PostProcessingQueue → PostProcessPipeline
                              ├ BatchTranscriber（Scribe v2 | OpenAI diarize | Local）
                              ├ SpeakerResolver（参加者リスト / 声の登録 / 背景の声の候補）
                              ├ Summarizer（Codex | Claude Code | Anthropic API）→ summary / decisions / action_items
                              ├ Store（SQLite + FTS5）
                              └ Exporter → 会議フォルダ → SyncTarget
[連携先（Phase 2、このリポジトリの外）]
  Webhook の受け口 → タスク管理やエージェント
```

### 3.2 コンポーネントと責務

| コンポーネント | 責務 | 着手 |
|---|---|---|
| AudioCapture | 2 トラック取得。16 kHz mono Float32 のリングバッファ供給と AAC ファイル保存 | Phase 0 |
| LiveTranscriber | SpeechAnalyzer / SpeechTranscriber の progressive 結果を segment に変換 | Phase 0 |
| BatchTranscriber | プロトコル + 3 実装（ElevenLabs / OpenAI / Local） | Phase 0（CLI）→ Phase 1（App） |
| MeetingDetector | 会議アプリの起動・音声レベル・カレンダーから「会議中らしさ」を判定 | Phase 1 |
| CalendarService | EventKit。候補イベント提示、参加者取得、会議 URL 抽出 | Phase 1 |
| Session | 状態機械 `idle → armed → recording → finalizing → done / failed` | Phase 1 |
| PostProcessingQueue | 録音と独立した、永続・直列の後処理ジョブ | Phase 1 |
| SpeakerResolver | クラスタ → 人の対応付け、背景の声の候補 | Phase 1（手動）→ Phase 3（自動） |
| Summarizer | Codex app server / Claude Code / Anthropic API で構造化要約 | Phase 1 |
| Store | GRDB、マイグレーション、FTS | Phase 1 |
| Exporter / SyncTarget | 会議フォルダの生成と転送 | Phase 1（LocalDirectory）→ Phase 2（Webhook / S3） |
| UI | メニューバー + 3 ペインウィンドウ + 初回の案内 | Phase 1 → Phase 1.5 |
| Chrome Extension | tabCapture + 発話者 DOM 監視 | Phase 3 |

### 3.3 設計原則

- **ローカル優先**: 生音声とライブ字幕は端末外に出ない。クラウドに出るのは会議ごとの `privacy_mode` が `cloud_ok` のときだけ。
- **二段構え**: live は速さ、final は精度。両方を同じ `segments` テーブルに `source` で区別して持つ。
- **差し替え可能**: STT / 要約 / 同期先はすべてプロトコル経由。
- **根拠を残す**: 要約・決定・アクションは必ず segment id を参照する。
- **再開可能**: 後処理の各ステップは冪等。途中失敗は状態を保存し、再実行で続きから走る。

---

## 4. 音声取得（AudioCapture）

### 4.1 会議アプリの音（system track）

- **Core Audio Process Tap**（macOS 14.2+）を使う。参照実装: `insidegui/AudioCap`（§16）。
- 手順: 対象プロセスの PID → `kAudioHardwarePropertyTranslatePIDToProcessObject` で AudioObjectID → `CATapDescription(stereoMixdownOfProcesses:)` → `AudioHardwareCreateProcessTap` → tap を含む aggregate device を `AudioHardwareCreateAggregateDevice`（`kAudioAggregateDeviceTapListKey`）で作成 → `AudioDeviceCreateIOProcIDWithBlock` で読み出し。
- 対象プロセスは bundle id で選ぶ。既定: `com.google.Chrome`、`com.microsoft.teams2`、`com.apple.Safari`、`company.thebrowser.Browser`（Arc）。初回の案内と設定で選び直せる。複数プロセスを同時に tap してよい（mixdown）。
- **タブ単位の切り出しは OS では不可。** 運用ルール「会議は専用ブラウザで開く」を、初回の案内・録音画面・README で説明する。真のタブ限定は Phase 3 の Chrome 拡張で実現する。
- 権限: `Info.plist` に `NSAudioCaptureUsageDescription`（「システムオーディオ録音」）。事前に許可の状態を調べる API はないので、初回の案内では Minutes 自身が鳴らすテスト音を録れるかで確かめる。
- フォールバック: ScreenCaptureKit の audio-only capture（Phase 3）。
- CLI から使う場合の注意: TCC の許可は実行バイナリに紐づく。`minutes-cli` には Info.plist を埋め込む（`-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker <path>`）。

### 4.2 自分の声（mic track）

- `AVAudioEngine` の inputNode。`NSMicrophoneUsageDescription`。入力デバイスは設定で選べる。
- AirPods 等の切替に追従するため `AVAudioEngineConfigurationChange` を監視して再起動する。

### 4.3 共通

- 内部形式: 16 kHz mono Float32（STT 用）。保存は AAC 64 kbps mono、トラック別ファイル（`system.m4a`、`mic.m4a`）。
- 時刻合わせ: 録音開始時の host time を基準に、両トラックのサンプル位置を同一タイムラインに乗せる。許容ずれ 50 ms。
- 無音検知（RMS ベース）を両トラックで持ち、MeetingDetector と終了判定に使う。
- 片方のトラックが途切れても録音を続ける。途切れた区間は無音で埋めて復帰を待ち、両方が途切れたときだけ止める。
- 保持ポリシー: 音声ファイルは既定 30 日で削除（設定可、export 完了後のみ）。文字起こしは永続。

---

## 5. 文字起こしと話者分離

### 5.1 二段構え

- **Live**: SpeechAnalyzer + SpeechTranscriber（`ja-JP`）。mic と system で別々の transcriber を持ち、mic 側は `speaker = "me"` 固定。話者分離なし・語彙指定なし（SpeechTranscriber は contextual strings 非対応）。
- **Final**: 会議終了後、system track を話者分離付きの BatchTranscriber に掛け、mic track は話者固定で文字起こしし、時刻でマージする。final が完成したら UI は final を表示。live は差分検証用に保持。

### 5.2 プロトコル

```swift
protocol BatchTranscriber {
    var id: String { get }              // "elevenlabs.scribe_v2" / "openai.gpt-4o-transcribe-diarize" / "local.speechanalyzer+fluidaudio"
    var runsLocally: Bool { get }
    func transcribe(_ req: TranscriptionRequest) async throws -> TranscriptionResult
}

struct TranscriptionRequest {
    let audioURL: URL                   // 16 kHz mono
    let language: String                // "ja"
    let diarize: Bool
    let keyterms: [String]              // 参加者名・業界用語
    let knownSpeakers: [KnownSpeaker]   // name + 2〜10 秒の参照音声（対応プロバイダのみ）
}

struct TranscriptionResult {
    let segments: [Segment]             // start, end, text, speakerLabel（"spk_0" 等）, confidence?
    let words: [Word]?                  // 任意
    let providerMeta: [String: String]  // モデル名、リクエスト id など
}

protocol LiveTranscriber {
    func start(audio: AsyncStream<AudioChunk>, locale: Locale) -> AsyncThrowingStream<LiveSegment, Error>
    // LiveSegment: text, isFinal, timeRange
}
```

### 5.3 各プロバイダの実装メモ（細部は docs で確認）

- **ElevenLabs Scribe v2（final の既定）**: `POST /v1/speech-to-text`（multipart）。`model_id=scribe_v2`、`language_code=ja`、`diarize=true`、`timestamps_granularity=word`、keyterms。話者は最大 32 人。マルチチャネルと diarize は排他なので、system track は話者分離付き、mic track は話者固定で別々に送る（同時に送る）。送る音声は FLAC に可逆圧縮する。レスポンスの `words[]`（`speaker_id`, `start`, `end`, `type`）を segment に畳む。送信と処理の時間を分けて記録する（G3）。
- **OpenAI gpt-4o-transcribe-diarize**: `POST /v1/audio/transcriptions`。`model=gpt-4o-transcribe-diarize`、`response_format=diarized_json`、`chunking_strategy=auto`（30 秒超は必須）、`language=ja`、`known_speaker_names[]` + `known_speaker_references[]`（data URL、各 2〜10 秒、最大 4 人）。ファイル上限 25 MB → 送信用に再エンコード。それでも超える場合は無音位置で分割し、known_speaker_references で話者 id を揃える。
- **Local（privacy_mode = local_only の会議、キーがないとき、および失敗時のフォールバック）**: SpeechAnalyzer をファイルモードで（`attributeOptions: [.audioTimeRange]`、volatile なし）+ FluidAudio の `performCompleteDiarization` → 時間重なり最大の話者を割り当てる。精度は粗い前提（手動割当で補う）。
- **Live（SpeechAnalyzer）**: `SpeechTranscriber.supportedLocale(equivalentTo:)` でロケール正規化、`AssetInventory.assetInstallationRequest(supporting:)` でモデルを事前ダウンロード（初回の案内でも行う）、`SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` の形式へ `AVAudioConverter` で変換、`reportingOptions: [.volatileResults]` で途中結果を表示し `isFinal` で確定。

### 5.4 話者名の解決（SpeakerResolver）

入力: final segments（`speakerLabel` クラスタ）、カレンダー参加者、`people` テーブルの声登録、（Phase 3）Chrome 拡張からの発話者タイムライン。

優先順位:

1. **DOM 発話者タイムライン**（Phase 3、あれば）: クラスタと発話者名の時間重なりで割当。Teams デスクトップ版では取れないので 2 以降に落ちる。
2. **knownSpeakers による名前付き結果**（OpenAI）。
3. **人間による割当**: UI で未解決クラスタに参加者候補をドロップダウンで割当。割当時に、そのクラスタから最もクリーンな 5〜8 秒を切り出して `people.voice_samples` に保存し、次回の knownSpeakers に流す。

mic track は常に `"me"`。

**背景の声**: 相手のマイクが拾った周りの会話は、話者分離で別の話者に分かれる。後処理（resolve_speakers）で相手側の話者ごとの音量を測り、いちばん長く話した相手側の話者より 10 dB 以上小さい話者を候補として示す（自動では隠さない）。除外した話者の発言は全文で折りたたみ、要約・書き出し・検索から外す（DB には残す）。発話単位で話者を変えた発話は、変えた先の話者で判定する。

---

## 6. 会議の検知とカレンダー連携

### 6.1 CalendarService（EventKit）

- `EKEventStore.requestFullAccessToEvents()`。`Info.plist` に `NSCalendarsFullAccessUsageDescription`。
- 前提: Google カレンダーは macOS のカレンダー（インターネットアカウント）に追加済み。アプリ側で OAuth は持たない。
- 「今の会議」候補: `now − 10 min` 〜 `now + 10 min` に開始し、`url` / `notes` / `location` に Meet（`meet.google.com/...`）または Teams（`teams.microsoft.com/l/meetup-join/...`）のリンクを含むイベント。複数あれば UI で選択。
- 取得項目: `title`、`startDate` / `endDate`、`attendees`（name, email）、organizer、会議 URL、`calendarIdentifier`、`eventIdentifier`。
- 参加者名は keyterms と話者候補に流す。

### 6.2 MeetingDetector

シグナル: (a) 対象 bundle id のプロセス起動（`NSWorkspace`）、(b) system track の音声レベルが閾値超え、(c) カレンダーのイベント開始 5 分前。

- (c) かつ (a) → 「録音準備」通知（`armed`）。初回の案内を終えるまでは準備しない。
- (b) を検知 → 録音開始。設定で、通知とボタンで確かめてから始めるようにできる（新しく入れた人の既定は確かめてから）。
- 終了: system・mic 両トラックが 3 分無音、または対象プロセス終了、またはイベント終了時刻 + 15 分。終了時はまず `finalizing` に入り、1 分以内に音声が再開したら `recording` に戻す（休憩・再接続対策）。
- 手動開始／停止は常に可能（メニューバー、グローバルショートカット）。
- 録音中は録音対象アプリ名を UI に明示する（誤録音防止）。

### 6.3 Session 状態機械

```
idle ──(armed 条件)──▶ armed ──(音声検知 or 手動)──▶ recording
recording ──(無音 3 分 / プロセス終了 / 手動)──▶ finalizing
finalizing ──(1 分以内に音声再開)──▶ recording
finalizing ──(PostProcessPipeline 完了)──▶ done
finalizing ──(失敗)──▶ failed（音声は保持、再実行可）
```

---

## 7. データモデルと保存

### 7.1 SQLite（GRDB、`~/Library/Application Support/Minutes/minutes.sqlite`）

初期のスキーマ。以後の列とテーブルの追加（録音開始時刻、タグ、話者の音量と除外、用語、本文の版、自動録音の記録、後処理ジョブなど）は `Sources/MinutesCore/Store/StoreSchema.swift` のマイグレーションが正。

```sql
CREATE TABLE meetings (
  id TEXT PRIMARY KEY,               -- ULID
  title TEXT NOT NULL,
  started_at TEXT NOT NULL,          -- ISO 8601
  ended_at TEXT,
  platform TEXT,                     -- 'meet' | 'teams' | 'other'
  calendar_event_id TEXT,
  calendar_title TEXT,
  attendees_json TEXT,               -- [{name, email}]
  privacy_mode TEXT NOT NULL CHECK (privacy_mode IN ('cloud_ok','local_only')),
  status TEXT NOT NULL,              -- 'recording' | 'finalizing' | 'done' | 'failed'
  audio_dir TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE segments (
  id INTEGER PRIMARY KEY,
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  source TEXT NOT NULL CHECK (source IN ('live','final')),
  t_start REAL NOT NULL,             -- 会議開始からの秒
  t_end REAL NOT NULL,
  speaker_id TEXT,                   -- speakers.id（未解決なら NULL）
  cluster_label TEXT,                -- プロバイダの話者ラベル（spk_0 等）/ 'me'
  text TEXT NOT NULL,
  confidence REAL
);

CREATE TABLE speakers (
  id TEXT PRIMARY KEY,
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  cluster_label TEXT NOT NULL,
  person_id TEXT REFERENCES people(id),
  display_name TEXT
);

CREATE TABLE people (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT,
  aliases_json TEXT,
  voice_samples_json TEXT,           -- [{path, duration, meeting_id}]
  created_at TEXT NOT NULL
);

CREATE TABLE notes (
  meeting_id TEXT PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
  summary_md TEXT,
  decisions_json TEXT,
  action_items_json TEXT,
  open_questions_json TEXT,
  user_notes_md TEXT,
  model TEXT,                        -- 'codex/<model> / prompt v2' など
  generated_at TEXT
);

CREATE TABLE pipeline_runs (
  id INTEGER PRIMARY KEY,
  meeting_id TEXT NOT NULL,
  step TEXT NOT NULL,                -- finalize_audio | transcribe_final | ...
  status TEXT NOT NULL,              -- running | ok | failed
  provider TEXT,
  started_at TEXT, finished_at TEXT,
  error TEXT
);

CREATE TABLE export_log (
  meeting_id TEXT NOT NULL,
  target TEXT NOT NULL,
  exported_at TEXT NOT NULL,
  checksum TEXT,
  status TEXT NOT NULL
);
```

マイグレーションは GRDB の `DatabaseMigrator` で管理する。

### 7.2 全文検索

- `segments_fts`（`content='segments'`）と `notes_fts` を FTS5 で作成。**`tokenize='trigram'`** を使う（既定の unicode61 は日本語を分かち書きしないため検索が効かない）。
- trigram は 3 文字未満のクエリにヒットしないので、2 文字以下は `LIKE '%q%'` にフォールバック。
- 検索結果は meeting 単位に集約し、ヒット segment の前後 1 件を snippet として返す。
- Phase 3: GRDB の custom FTS5 tokenizer で `NLTokenizer`（日本語の単語単位）+ bigram に置換。`sqlite-vec` で意味検索。

### 7.3 書き出しフォーマット（1 会議 = 1 フォルダ）

フォルダ名: `YYYY-MM-DD_HHmm_<slug>_<id8>/`

- `meeting.md` — frontmatter + 本文

```markdown
---
id: 01J...
title: 週次定例
started_at: 2026-09-16T10:00:00+09:00
ended_at: 2026-09-16T11:02:00+09:00
platform: meet
calendar_event_id: ...
attendees:
  - {name: 田中, email: tanaka@example.com}
speakers:
  - {label: spk_0, name: 田中}
privacy_mode: cloud_ok
transcript_sha256: ...
generated_by: minutes/0.1 (elevenlabs.scribe_v2, codex/<model>, prompt v2)
---

## 要約
## 決定事項
## アクション
（owner / kind / due / evidence: seg#）
## 未決・論点
## 全文（話者付き）
[00:12:30] 田中: ...
```

- `transcript.json` — `{ meeting, speakers, segments: [{id, t_start, t_end, speaker, text}] }`
- `summary.json` — Summarizer の構造化出力そのまま（§8.1）
- `manifest.json` — `schema_version`、ファイル一覧と sha256
- `audio/` — 任意。既定では書き出さない

---

## 8. 後処理パイプライン（PostProcessPipeline）

順序（各ステップは冪等。`pipeline_runs` に記録し、失敗ステップから再開できる。後処理は録音と独立した永続の待ち行列で一件ずつ実行する）:

1. `finalize_audio` — 両トラックを閉じ、STT 用 16 kHz WAV と送信用の音声を生成
2. `transcribe_final` — `privacy_mode` に従ってプロバイダ選択。クラウド失敗時は Local にフォールバック
3. `merge_tracks` — mic の結果（`me`）と system の結果を時刻でマージ。重なりは両方残す
4. `resolve_speakers` — §5.4
5. `summarize` — §8.1（`local_only` の会議ではスキップ）
6. `store` — `segments(final)` / `notes` を保存、FTS 更新
7. `export` — §7.3 のフォルダを生成し SyncTarget へ
8. `notify` — macOS 通知「議事録ができました」

要約・書き出し・通知の失敗は会議を failed にせず、警告として残して会議は完了扱いにする（画面からやり直せる）。文字起こし以前と保存の失敗だけが failed。

### 8.1 Summarizer

- 要約の手段は設定で選ぶ。
  - **Codex app server**（既定）: 利用者の Codex のログインを使う。Minutes 専用の `codex app-server --listen stdio://` を起動し、一時 thread・読み取り専用サンドボックス・構造化出力で実行する。shell・MCP などの操作は無効にする。認証情報は Codex が管理し、Minutes はコピーしない。
  - **Claude Code**: 利用者の Claude Code のログインを使う（`claude -p`、ツール・個人設定・セッション保存なし）。
  - **Anthropic API**: 利用者の API キーで Messages API を呼び、tool use（`record_minutes`）で構造化出力を受け取る。
  - **要約しない**: 文字起こしまでの議事録を作る。
- **モデル ID・パラメータ・プロトコルの仕様は実装前に docs（§16）で確認する。**
- 入力: 会議メタ（title, attendees）、話者付き全文（segment id 付き。除外した背景の声は含めない）、（Phase 3）同シリーズ前回の要約。
- 出力スキーマ:

```json
{
  "summary_md": "...",
  "decisions": [{ "text": "...", "evidence": [123, 130] }],
  "action_items": [{
    "text": "...",
    "owner": "me | <参加者名> | agent",
    "kind": "own_commitment | their_task | delegable",
    "due": "2026-09-20 | null",
    "evidence": [141]
  }],
  "open_questions": [{ "text": "...", "evidence": [150] }],
  "keyterms_learned": ["..."]
}
```

- `kind` の意味:
  - `own_commitment` — 自分が「やる」と言ったもの → 自分のタスク
  - `their_task` — 相手の宿題 → 追跡のみ
  - `delegable` — エージェントに任せられるもの（メール下書き、調査など）→ 提案として作成、実行は承認
- 90 分を超える会議はセグメントを分割し、部分要約 → 統合の 2 段で処理する。
- プロンプトは `Sources/MinutesCore/Summarize/Resources/Prompts/summarize_ja.md` に外出しし、バージョンを `notes.model` に一緒に記録する。
- `keyterms_learned` は次回以降の keyterms に自動追加（設定で無効化可）。

---

## 9. 書き出しと連携

### 9.1 SyncTarget

```swift
protocol SyncTarget {
    var id: String { get }
    func upload(folder: URL, manifest: Manifest) async throws -> SyncReceipt
}
```

- `LocalDirectory`（Phase 1）: 任意のフォルダにコピー。Google Drive / Dropbox の同期フォルダを指定すれば、ほかの機器にも届く。
- `Webhook`（Phase 2）: 任意の受け口に会議フォルダを multipart で POST する（共有トークン）。受け口は manifest の sha256 で改ざんを検知できる。
- `S3Compatible`（Phase 2/3）: R2 / S3 に PUT（SigV4）。バックアップや、正本をクラウドに置きたい場合。
- 失敗時はローカルキュー（`export_log.status = 'pending'`）に残し、起動時と 10 分ごとに再送。

### 9.2 受け側

- 受け側（Webhook の受け口や、タスク管理につなぐエージェント）はこのリポジトリの外で作る。
- 受け側は `meeting.md` と `summary.json` を読み、`action_items` を `kind` ごとに扱う（§8.1）。`transcript.json` は根拠の確認が必要なときだけ読む。
- 根拠へは `minutes://meeting/<id>?seg=<segment_id>` のディープリンクで戻れる。`minutes://` は Minutes.app が登録し（`CFBundleURLTypes`）、該当の発言にジャンプして再生する。

---

## 10. UI

### 10.1 メニューバー

- 状態アイコン: `idle` / `armed` / `recording`（赤、経過時間つき）/ `finalizing`。
- パネル: 開始／停止、今の会議（カレンダー候補）、プライバシーモード切替、今日・今週の会議時間、今日の予定、最近の会議、設定。

### 10.2 メインウィンドウ（`NavigationSplitView` 3 ペイン）

- **左**: スマートフォルダ（今日 / 今週 / すべて / 処理中 / 失敗 / タグ）+ 検索欄。
- **中央**: 会議リスト（タイトル、日時、参加者、処理状態）。
- **右**: 議事録ビュー。上から 要約 → 決定事項 → アクション（チェックボックス）→ 全文（話者ごとに色分け、時刻クリックで再生、テキストは編集可）。録音中はライブ字幕 + 自分用メモ欄になる。
- 話者割当: 全文の話者チップをクリック → 参加者候補から選択 → 同クラスタ全体に反映。
- 検索: 入力ごとに FTS、ハイライト付き snippet。

### 10.3 設定

録音対象アプリ、マイク、既定プロバイダ（live / final / 要約）、API キー（Keychain）、`privacy_mode` の既定、音声保持日数、同期先、対象カレンダー、ショートカット、外観、人物と用語、診断（診断情報の書き出し、初回の案内を開く）。

### 10.4 初回の案内

最初の起動で専用のウィンドウを開く（会議がすでにある環境では出さない）。ようこそ → 許可（マイク・会議アプリの音・カレンダー・通知）→ 会議アプリ（会議専用ブラウザの説明、自動録音の選び方）→ 文字起こしと要約 → 試しの録音（20 秒、保存しない。「議事録まで試す」だけ会議として保存）→ 準備完了（参加者への告知文）。

---

## 11. リポジトリ構成とビルド

```
minutes/
  AGENTS.md                    # 開発の手順（ビルド・テスト・実行コマンド、構成、決まり）。コーディングエージェントも読む
  README.md                    # 使い方と運用ルール（会議専用ブラウザ等）
  docs/SPEC.md                 # この文書
  Package.swift
  Sources/MinutesCore/         # 音声・STT・DB・パイプライン・要約・書き出し（UI 非依存）
  Sources/minutes-cli/         # 評価・検証用の CLI
  Sources/MinutesApp/          # SwiftUI アプリ
  Tests/MinutesCoreTests/
  fixtures/                    # TTS で作る模擬会議（実会議の音声は入れない）
  scripts/                     # ビルド・署名、評価、禁止語の検査
```

- ビルド: `swift build`（Core / CLI / App）。App は `scripts/build-app.sh` で .app に組み立てて署名する。実際のコマンドは `AGENTS.md`。
- 署名: 開発中も固定の証明書で署名する（ad-hoc 署名だとビルドごとに TCC 権限がリセットされる）。
- `Info.plist`: mic / audio capture / calendars の UsageDescription、`CFBundleURLTypes`（`minutes`）。
- ログ: `os.Logger`。本文・音声・キーは出さない（§14）。

---

## 12. 開発の段階

### Phase 0 — spike と STT 比較（完了）

- `minutes-cli record` / `live` / `transcribe` / `eval` で、2 トラック録音・ライブ字幕の遅延・3 プロバイダの CER と話者分離を比べた。
- 結果: final の既定は ElevenLabs Scribe v2。Local は速く品質も近いが、短い発話の話者分離が弱い。

### Phase 1 — アプリ MVP（2026-09-30 完了）

- MinutesCore: Store（スキーマ・マイグレーション・FTS）、Session 状態機械、PostProcessPipeline、Summarizer、Exporter（LocalDirectory）
- MinutesApp: メニューバー、CalendarService、MeetingDetector、3 ペイン UI、話者割当 UI、設定、`minutes://` scheme

完了条件: G1〜G5 を実会議で満たす（G5 は会議がたまるまで保留）。`meeting.md` / `transcript.json` が同期フォルダに出る。アプリがクラッシュしても録音済み音声と live segments が失われない。

### Phase 1.5 — 公開準備

目的: OSS（Apache-2.0）のリポジトリと、無料の公式ビルド（公証済み、自動更新つき）を公開する。開発環境のない人が、ターミナルを使わずに録音から議事録まで使えるようにする。

タスク:

- 公開する中身を分ける: 個人環境・実会議の情報・ローカルの絶対パスを含めない。禁止語の検査（`scripts/check-public.py`）を通す。
- 権利の文書: LICENSE（Apache-2.0）、NOTICE（GRDB、FluidAudio、話者分離モデルの CC-BY-4.0 の帰属表示、Sparkle）、TRADEMARKS（名前とロゴの扱い）、CONTRIBUTING（DCO）、SECURITY（脆弱性の連絡先）。アプリの「謝辞」にも帰属表示を出す。
- 利用者向けの README: 動作環境、入れ方、許可、プロバイダの選び方、送信先と送信の条件（`privacy_mode`）、録音の告知と同意は利用者が行うこと。日本語と英語の概要で書く。UI は日本語のみ。
- 配布: Developer ID で署名し（`--timestamp` を付け、`--deep` に頼らない）、`notarytool` で公証、`stapler` で添付して DMG にする。自動更新に Sparkle 2 を加える（EdDSA 署名、appcast）。リリースの手順を `scripts/` にまとめる。
- 初めての人の導線: 初回の案内（§10.4）、会議専用ブラウザの説明、参加者への告知文のコピー、診断情報の書き出し（本文・音声・キーは含めない）。利用状況の送信（テレメトリ）は入れない。
- Phase 1 の残り: G3（送信と処理の時間の記録、送る音声の圧縮）、G7（録音中の CPU。2026-10-05 に実会議で平均 10.6%）、片方のトラックが途切れても録音を続ける（§4.3）。

完了条件:

- 開発環境のない別の Mac に公開ビルド（公証済みの DMG）を入れ、初回の案内だけで録音から議事録まで通る。キーなし（ローカル）と自分のキー（ElevenLabs）の両方で確かめる。
- 自動更新で旧版から新版に上がる。
- 公開リポジトリ（履歴を含む）に個人環境と実会議の情報がない（禁止語の検査が 0 件）。
- LICENSE・NOTICE・TRADEMARKS・CONTRIBUTING・SECURITY・README がそろい、アプリの謝辞に帰属表示がある。
- G3 を 60 分前後の実会議 2 本で満たす。

### Phase 2 — Webhook 連携

- `Webhook` の SyncTarget（§9.1）。受け側に会議フォルダとアクション候補を渡す。

完了条件: G6。

### Phase 3 — 精度と体験（着手時に完了条件を追記）

- Chrome 拡張: `chrome.tabCapture` でタブ音声、Meet / Teams の発話者 DOM 監視、localhost WebSocket で App へ
- 声の登録による自動話者解決、シリーズ会議での前回要約参照
- 日本語トークナイザ、意味検索（`sqlite-vec`）
- 英語混在対応
- ScreenCaptureKit フォールバックの本実装

---

## 13. テスト・評価

- fixtures: 2 トラックの短い日本語会話（TTS で生成）と参照テキスト。長尺は実会議（リポジトリ外）。
- 単体テスト: トラックのマージ（時刻整合）、話者割当（重なり計算）、FTS（日本語クエリ、2 文字フォールバック）、カレンダー候補抽出（URL 正規表現）、フォルダ書き出し（manifest 検証）、Session 状態遷移、背景の声、診断情報（会議名を伏せる）。
- プロバイダ: レスポンス JSON の golden ファイルでパーサをテスト。実 API は環境変数で有効にする手動テストのみ（`MINUTES_CODEX_LIVE=1` など、架空の会議だけを送る）。
- 回帰: `minutes-cli eval` は手動実行（音声は git に入れない）。
- パフォーマンス: 録音中の CPU を画面の状態とスレッドごとに記録し（`capture_stats.jsonl`）、`scripts/cpu-breakdown.py` で G7 を確認する。

---

## 14. セキュリティ・プライバシー

- API キーは Keychain。CLI は `.env`（`.gitignore`）。
- ログにキー・音声・本文を出さない（debug でも本文は先頭 40 文字まで）。
- `privacy_mode = local_only` の会議は、いかなるステップでも外部送信しない。Summarizer も呼ばない（要約は空。人間が後で `cloud_ok` に切り替えたときに実行）。書き出し・同期もしない。
- 音声ファイルは既定 30 日で削除。削除は export 済みを確認してから。
- Webhook（Phase 2）は共有トークンで認証し、manifest の sha256 で改ざんを検知できるようにする。
- 診断情報の書き出しには本文・音声・キーを入れず、会議名とカレンダーの件名は会議の ID に置き換える。利用状況の送信（テレメトリ）は入れない。
- 録音中は録音対象アプリ名を UI に明示する。録音の告知と同意は利用者が行う（告知文をコピーできる）。

---

## 15. 未決事項

| # | 事項 | 案 |
|---|---|---|
| 1 | 会議専用ブラウザの運用ルール | 会議用のブラウザを 1 つ決める（初回の案内で選ぶ）。タブ単位の録音は Phase 3 |
| 2 | live の代替（Apple の日本語品質が不十分な場合） | Scribe v2 Realtime に差し替え可能な構造にしておく |
| 3 | 英語・多言語の会議 | ライブ字幕の言語の切り替え（Phase 3） |

---

## 16. 参考リンク（実装前に確認）

- Apple SpeechAnalyzer: https://developer.apple.com/documentation/speech/speechanalyzer
- Apple SpeechTranscriber: https://developer.apple.com/documentation/speech/speechtranscriber
- Process Tap 参照実装（AudioCap）: https://github.com/insidegui/AudioCap
- FluidAudio: https://github.com/FluidInference/FluidAudio（参考アプリ: https://github.com/FluidInference/swift-scribe）
- SpeechAnalyzer + FluidAudio の構成例: https://github.com/yrocaz/mac-transcriber
- GRDB.swift: https://github.com/groue/GRDB.swift
- ElevenLabs Speech to Text: https://elevenlabs.io/docs/overview/capabilities/speech-to-text
- OpenAI Speech to Text（gpt-4o-transcribe-diarize）: https://developers.openai.com/api/docs/guides/speech-to-text
- Codex App Server: https://learn.chatgpt.com/docs/app-server
- Claude API: https://docs.claude.com/en/api/overview
- Claude Code（headless）: https://code.claude.com/docs/en/headless
- Sparkle: https://sparkle-project.org/documentation/
- Chrome tabCapture（Phase 3）: https://developer.chrome.com/docs/extensions/reference/api/tabCapture

---

## 17. 公開と配布

- OSS（Apache-2.0）で公開する。クライアント（MinutesCore / minutes-cli / MinutesApp）はすべて公開する。
- 公式ビルドは Developer ID で署名・公証し、Sparkle で自動更新する。
- Mac App Store は対象外（§1.3）。サンドボックスでは外部の CLI（Codex / Claude Code）を起動できず、独自の更新も使えない。
- 名前は Minutes。名前とロゴの扱いは TRADEMARKS に書く。
