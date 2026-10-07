# Minutes

Mac で会議を録音し、話者付きの文字起こしと要約から議事録を作るアプリです。録音とライブ字幕はこの Mac の中で行い、会議が終わったら、選んだサービスで文字起こしと要約を作ります。

[English](#english)

## できること

- **会議アプリの音と自分の声を別々に録音**: Google Meet・Microsoft Teams・Zoom などの音（相手の声）と、マイクの声（自分）を分けて録るので、誰が話したかを分けやすくなります。
- **ライブ字幕**: 録音中の字幕は、この Mac の中（macOS の音声認識）で作ります。
- **議事録**: 会議が終わると、文字起こし・要約・決定事項・アクション・未決の論点を作ります。要約やアクションには、根拠の発言へのリンクが付きます。
- **日本語と英語の会議**: 会議ごとに言語を持ちます。「自動」にしておくと、会議のあとで英語の会議かを判定し、英語で文字起こし・要約します（英語の会議の要約を日本語にすることもできます）。録音中に字幕の言語を切り替えることも、あとから会議の画面で言語を変えることもできます。
- **話者の名前**: 話者を一度選ぶと、同じ話者の発言すべてに名前が付きます。相手のマイクが拾った周りの会話（背景の声）は、話者ごとに外せます。
- **検索と書き出し**: タイトル・参加者・本文・要約を全文検索できます。会議ごとに Markdown と JSON を書き出し、好きなフォルダ（Dropbox などの同期フォルダも可）にコピーできます。
- **自動録音**: カレンダーの予定（Meet・Teams のリンク付き）の時刻に会議アプリから音がすると、録音するかを通知で確かめてから始めます（すぐに始める・自動では録音しない、も選べます）。

## 動作環境

- Apple Silicon の Mac、macOS 26 以降
- 文字起こし（どれか 1 つ）
  - ElevenLabs Scribe v2（おすすめ。API キーが要ります）
  - OpenAI（API キーが要ります）
  - この Mac の中（キー不要。精度は下がり、初回にモデルをダウンロードします）
- 要約（どれか 1 つ）
  - Codex（ChatGPT のログイン）
  - Claude Code（Claude のログイン）
  - Anthropic API（API キー）
  - 要約しない

## 入れ方

[Releases](https://github.com/pictors/minutes/releases) から公証済みの DMG をダウンロードし、開いて Minutes を「アプリケーション」フォルダへドラッグします。公式の版は、新しい版が出ると知らせて、自動で更新できます（Sparkle）。ソースからビルドすることもできます（[ソースからビルドする](#ソースからビルドする)）。

初めて起動すると「初回の案内」が開きます。

1. **許可**: マイク・会議アプリの音（画面収録とシステムオーディオ録音）・カレンダー・通知。会議アプリの音の許可は、テスト音で確かめられます。
2. **会議アプリ**: 会議に使うブラウザとアプリを選び、予定の時刻の自動録音の動きを選びます。
3. **文字起こしと要約**: 使うサービスを選び、必要なら API キーを登録します（キーは Keychain に保存します）。
4. **試しの録音**: 20 秒録って、会議アプリの音・自分の声・ライブ字幕が届くかを確かめます（保存しません）。
5. **準備完了**: 参加者に録音を知らせる文面を確かめます。

あとから 設定 > 診断 の「初回の案内を開く」で、もう一度開けます。

## 会議は専用のブラウザで開く

macOS はアプリ単位で音を録ります。**ブラウザのタブ単位では分けられない**ので、会議に使うブラウザで動画や音楽を流すと、それも録音されます。会議は会議専用のブラウザで開いてください（例: 普段は Safari、会議は Chrome）。録音画面にも、録っているアプリを表示します。

## 使い方

- **メニューバー**: Minutes のアイコンからパネルを開き、録音の開始・停止、録音する予定とプライバシーの選択、今日・今週の会議時間、今日の予定、最近の会議を見られます。録音中はメニューバーに経過時間が出ます。
- **ウィンドウ**（⌘⇧M）: 左に検索とフォルダ（今日・今週・すべて・処理中・失敗・タグ）、中央に会議の一覧、右に議事録（要約 → 決定事項 → アクション → 未決 → メモ → 全文）。時刻を押すとその位置から再生します。
- **ショートカット**: 設定 > 録音 で、どのアプリからでも録音を始めたり止めたりできるショートカットを決められます。
- **後処理**: 録音を止めると、文字起こしと要約は裏で順番に進みます。その間に次の会議を録音できます。失敗した会議は、会議の画面の「後処理をやり直す」でやり直せます。要約や書き出しだけの失敗は、会議を完了にしたまま警告として残します。
- **編集**: 本文の修正、発話ごとの話者の変更、タイトル・参加者・タグ・アクションの編集ができます。編集した本文は、文字起こしをやり直しても保たれます。

## 送信先と送信の条件

会議ごとに「クラウド OK」か「ローカルのみ」を選べます（既定は設定で決め、会議ごとに録音の前に変えられます）。

| | クラウド OK | ローカルのみ |
|---|---|---|
| 録音した音声 | 会議のあと、選んだ文字起こしのサービス（ElevenLabs / OpenAI）へ送る。参加者の名前と用語も、精度を上げるために送る | 送らない（この Mac の中で文字起こし） |
| 文字起こしの本文・会議名・参加者 | 選んだ要約の手段へ送る（Codex は OpenAI、Claude Code と Anthropic API は Anthropic） | 送らない（要約は作らない） |
| 書き出し・同期 | 選んだフォルダへコピーする | しない |

- ライブ字幕は、いつもこの Mac の中で作ります。
- 文字起こしのサービスのキーがなければ、この Mac の中で文字起こしします。
- 初めて使うときに、macOS の音声認識モデル（Apple から）と、話者分離のモデル（Hugging Face から）をダウンロードします。
- 音声と議事録はこの Mac に保存します（`~/Library/Application Support/Minutes/`）。音声は既定で 30 日後に削除します（書き出しが済んだ会議だけ。ローカルのみの会議の音声は残ります。日数は設定で変えられます）。文字起こしと議事録は残ります。
- API キーは Keychain に保存します。利用状況の送信（テレメトリ）はしません。
- 新しい版の確認のため、1 日に 1 回 GitHub から更新の情報を読みます（設定 > 情報 で止められます）。新しい版は、確かめてから入れます。
- 送った先での扱い（保存・学習への利用など）は、それぞれのサービスの規約と設定によります。

## 録音の告知と同意

録音することを参加者に伝え、必要な同意を得るのは、Minutes を使う人の責任です。法律と、所属する組織のルールに従ってください。参加者に知らせる文面は、初回の案内で編集でき、録音画面とメニューからいつでもコピーできます。

## 困ったとき

- **会議アプリの音が録れない**: システム設定 > プライバシーとセキュリティ > 画面収録とシステムオーディオ録音 で Minutes を許可してください。会議アプリが起動していても、まだ音を出していないと録音の対象に見えません。
- **自分の声が録れない**: システム設定 > プライバシーとセキュリティ > マイク で Minutes を許可し、設定 > 録音 のマイクを確かめてください。
- **自動で録音が始まらない**: カレンダーと通知の許可、設定 > 録音 の自動録音、予定に会議のリンクがあるかを確かめてください。
- **問い合わせ**: 設定 > 診断 の「診断情報を書き出す…」で書き出した JSON を、[Issue](https://github.com/pictors/minutes/issues) に添えてください。本文・音声・API キーは入らず、会議名は会議の ID に置き換わります。

## ソースからビルドする

Xcode 26 以降が要ります。

```bash
git clone https://github.com/pictors/minutes.git
cd minutes
scripts/build-app.sh --install   # Minutes.app を組み立てて /Applications に入れる
open /Applications/Minutes.app
```

マイクとシステムオーディオ録音の許可は、アプリの署名に紐づきます。ad-hoc 署名だとビルドごとに許可がリセットされるので、続けて使うなら固定の証明書で署名してください。自分の Mac で使うだけなら、Xcode の Settings > Accounts に Apple ID を登録して作る「Apple Development」証明書で足ります。`security find-identity -v -p codesigning` に出る名前を、`.env` の `CODESIGN_IDENTITY` に書きます（[.env.example](.env.example)）。

- CLI（録音・文字起こし・評価・後処理）: [docs/CLI.md](docs/CLI.md)
- 開発の手順・コマンド・構成: [AGENTS.md](AGENTS.md)
- 設計: [docs/SPEC.md](docs/SPEC.md)
- 貢献の手順: [CONTRIBUTING.md](CONTRIBUTING.md)
- セキュリティ: [SECURITY.md](SECURITY.md)

## ライセンス

[Apache License 2.0](LICENSE)。第三者のソフトウェアとモデルの帰属表示は [NOTICE](NOTICE)（アプリでは 設定 > 情報）。名前「Minutes」とロゴの扱いは [TRADEMARKS.md](TRADEMARKS.md)。

© 2026 Pictors Inc.

---

## English

Minutes is a macOS app that records your meetings and turns them into minutes: a transcript with speakers, a summary, decisions, and action items. Recording and live captions stay on your Mac. After the meeting, Minutes transcribes and summarizes with the services you choose. The app's UI is in Japanese.

**Features**

- Records the meeting app's audio (Meet, Teams, Zoom, …) and your microphone as separate tracks, so speakers are easier to tell apart.
- On-device live captions (macOS speech recognition).
- After the meeting: transcript, summary, decisions, action items, and open questions, each linked to the source utterances.
- Meetings in Japanese or English. In automatic mode, Minutes detects English meetings after the meeting and transcribes and summarizes them in English (or summarizes them in Japanese, if you prefer). You can switch the caption language while recording, or change a meeting's language afterwards.
- Speaker naming, background-voice exclusion, full-text search, and Markdown/JSON export.
- Optional automatic recording for calendar meetings, with a confirmation notification by default.

**Requirements**: Apple Silicon Mac with macOS 26 or later. Transcription with ElevenLabs Scribe v2 (recommended, API key), OpenAI (API key), or on-device (no key). Summaries with Codex (ChatGPT sign-in), Claude Code (Claude sign-in), the Anthropic API (API key), or none.

**Privacy**: Each meeting is either "cloud OK" or "local only". For cloud OK meetings, the recorded audio is sent after the meeting to the transcription service you chose, and the transcript, title, and participants to the summarizer you chose. Local-only meetings never leave your Mac (on-device transcription, no summary, no export). Live captions are always on-device. Audio and minutes are stored in `~/Library/Application Support/Minutes/`; audio is deleted after 30 days by default. API keys are stored in the Keychain. Minutes sends no telemetry; it checks GitHub for updates once a day (you can turn this off in Settings > About).

**Consent**: You are responsible for telling participants that you are recording and for obtaining any consent required by law or your organization. Minutes can copy a notice text for you.

**Install**: Download the notarized DMG from [Releases](https://github.com/pictors/minutes/releases), or build from source with Xcode 26: `scripts/build-app.sh --install`. Official builds update themselves with Sparkle. See [AGENTS.md](AGENTS.md) for development and [docs/CLI.md](docs/CLI.md) for the command-line tool.

**License**: [Apache License 2.0](LICENSE). Third-party notices are in [NOTICE](NOTICE). The name "Minutes" and the logo are covered by [TRADEMARKS.md](TRADEMARKS.md). © 2026 Pictors Inc.
