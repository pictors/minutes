# minutes-cli

録音・ライブ字幕・文字起こし・評価・後処理を、アプリを使わずに試すための CLI。アプリと同じ `MinutesCore` を使う。

## ビルドと署名

```bash
swift build -c release --product minutes-cli
.build/release/minutes-cli help
```

マイクと「システムオーディオ録音」の許可は、実行するバイナリの署名に紐づく（ターミナルから起動した場合はターミナルアプリにも）。ad-hoc 署名はビルドごとに許可がリセットされるので、続けて使うなら固定の証明書で署名する。自分の Mac で使うだけなら、Xcode の Settings > Accounts に Apple ID を登録して作る「Apple Development」証明書でよい。

```bash
security find-identity -v -p codesigning   # 出てきた名前を .env の CODESIGN_IDENTITY に書く（環境変数が優先）
scripts/build-cli.sh                       # release ビルド + その ID で署名
```

証明書があるのに 0 件と出る場合は、中間証明書「Worldwide Developer Relations - G3」を https://www.apple.com/certificateauthority/ から入れる（キーチェーンアクセスで -25294 になるときは `security import AppleWWDRCAG3.cer -k ~/Library/Keychains/login.keychain-db`）。

API キーは `.env.example` を `.env` にコピーして書く（`.env` はコミットしない）。

## 録音とライブ字幕

```bash
CLI=.build/release/minutes-cli

# 録音対象の確認（* が --app にマッチしたプロセス）。マイクは devices
$CLI processes --app com.google.Chrome
$CLI devices

# 2 トラック録音。Ctrl-C で停止。--duration 3600 で 60 分の dropout 検証、--mic-device <uid> でマイクを選ぶ
$CLI record --app com.google.Chrome --out recordings/2026-09-16_weekly

# ライブ字幕（初回は日本語モデルのダウンロード）。--mic で自分の声も
$CLI assets --install
$CLI live --app com.google.Chrome --out recordings/live-test
$CLI live --file recordings/2026-09-16_weekly/system_16k.wav   # 録音済みの音声で live 経路を再現（--fast-results で確定を速く）
```

録音フォルダの中身:

| ファイル | 内容 |
|---|---|
| `system.m4a` / `mic.m4a` | AAC 64 kbps mono（アーカイブ、ソースのサンプルレート） |
| `system_16k.wav` / `mic_16k.wav` | 16 kHz mono 16-bit（STT 用） |
| `recording.json` | 開始時刻、対象プロセス、トラック統計（gap / drift / CPU） |
| `record_log.jsonl` | 統計ログ（既定 10 秒ごと） |
| `transcript.<provider>.json` | 統一フォーマットの文字起こし（`segments[]` に `track` / `speaker` / `t_start`） |

## 文字起こしと評価

```bash
# final 文字起こし → transcript.<provider>.json / .txt
$CLI transcribe recordings/2026-09-16_weekly --provider elevenlabs
$CLI transcribe recordings/2026-09-16_weekly --provider openai
$CLI transcribe recordings/2026-09-16_weekly --provider local --num-speakers 3   # SpeechAnalyzer + FluidAudio、端末外に出ない

# 評価（参照テキストは人手で作る。話者プレフィックス付きなら --strip-speaker-prefix）
$CLI eval recordings/2026-09-16_weekly/transcript.elevenlabs.json reference.txt --json
```

実会議を使わない動作確認には、TTS の模擬会議を使う（[fixtures/README.md](../fixtures/README.md)）。

既存の録音（ほかのサービスで録った録音ファイルなど）から評価する場合:

```bash
# 10:00 から 10 分を切り出し（入力は m4a / mp4 / wav など AVFoundation が読める形式）
$CLI cut meeting.m4a cut/system_16k.wav --start 10:00 --duration 600
# 既存の文字起こし（JSON か "[hh:mm:ss] 話者: 本文" のテキスト）から同じ区間の参照テキストを作る
python3 scripts/reference-from-transcript.py meeting.transcript.json --start 10:00 --end 20:00 --out cut/reference.txt
$CLI transcribe cut --provider elevenlabs --num-speakers 3
$CLI eval cut/transcript.elevenlabs.json cut/reference.txt --strip-speaker-prefix
```

機械生成の文字起こしを参照にした CER は「一致率」であって正解率ではない。短い区間なら `reference.txt` を人手で直してから評価する。話者分離の一致率は `scripts/speaker-agreement.py transcript.json reference.speakers.json` で出す。`eval --track system|mic` は参照テキストが全会話の場合は意味を持たない（比較は `--track all`）。

## 後処理（アプリと同じパイプライン）

```bash
$CLI process recordings/2026-09-16_weekly --provider elevenlabs --title "週次定例"
# 保存済みの本文から要約だけやり直す（編集・根拠 ID を保持。STT の API キーは不要）
$CLI process recordings/2026-09-16_weekly --summary-only
$CLI process recordings/2026-10-07_english --language en            # 英語の会議として文字起こし・要約（--summary-language ja で要約だけ日本語）
# 要約の手段: codex（既定）/ claude-code / anthropic / none。モデルと実行ファイルも指定できる
$CLI process recordings/2026-09-16_weekly --summary-only --summary-provider claude-code --summary-model <alias>
$CLI process recordings/2026-09-16_weekly --summary-only --summary-model <model-id> --codex-path /absolute/path/to/codex
```

`--db` で別の DB を使える。CLI の `record` / `live` は録音の失敗を受けたら停止・ファイルの終了処理をして、0 以外で終わる。`transcribe` は送信前に、空の音声と、manifest がある場合の録音失敗・時間の不一致・欠けたトラックを確かめる。

## MCP サーバー（Claude などから会議を読む）

会議のあとに Claude Code・Claude Desktop などへ「直前の会議を議事録にして」「アクションを Backlog のチケットにして」と頼めるよう、会議を MCP（stdio）で読めるようにする。読み取りだけで、DB には書かない（SQLite を読み取り専用で開き、マイグレーションも回復処理もしない）。アプリが動いていても使える。

```bash
scripts/build-cli.sh                                   # release ビルド（バイナリは .build/release/minutes-cli）
claude mcp add --scope user minutes -- "$PWD/.build/release/minutes-cli" mcp   # Claude Code に登録（パスは絶対パスで）
```

Claude Desktop は `claude_desktop_config.json` の `mcpServers` に `{"minutes": {"command": "<minutes-cli の絶対パス>", "args": ["mcp"]}}` を足す。`--db <path>` で別の DB、`--export-dir <dir>` で meeting.md の場所の案内に使う書き出し先を変えられる。

| ツール | 中身 |
|---|---|
| `list_meetings` | 会議の一覧（新しい順）。`since` / `until`（YYYY-MM-DD か ISO 8601）・`tag`・`limit` |
| `get_meeting` | 要約・決定事項・アクション（担当・種別・期限・ID・根拠の発言 ID）・未決の論点・メモ・参加者。`meeting_id` を省くと直前の会議（録音中の会議より、終わった直後の会議を優先）。`include_transcript` で全文も |
| `get_transcript` | 全文（`[時刻] #発言 ID 話者: 本文`）。`start` / `limit` で分けて読む |
| `search_meetings` | 本文・要約・メモ・タイトル・参加者・タグの検索（アプリの検索と同じ） |

プロンプト（Claude Code では `/mcp__minutes__minutes`・`/mcp__minutes__tasks`）: `minutes` は議事録にまとめて置き場所を聞く、`tasks` はアクションをチケットの案にして、利用者が OK したものだけを作る。どちらも `meeting_id` と `destination`（例: Backlog のプロジェクト）を省ける。

- `privacy_mode = local_only` の会議は、一覧・検索・読み取りのどれにも出さない（SPEC §14）。
- 背景の声として除外した話者の発言は出さない（書き出しと同じ）。
- 後処理中の会議は、どのステップかを返す。モデルはそれを見て待つ。
- stdout には JSON-RPC だけを書く。stderr には起動の 1 行だけを出し、本文は出さない。
