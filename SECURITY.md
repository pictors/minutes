# セキュリティ

## 脆弱性の知らせ方

脆弱性は、公開の Issue には書かず、GitHub の [非公開の報告（Report a vulnerability）](https://github.com/pictors/minutes/security/advisories/new) で知らせてください。

- 再現の手順、影響する版（設定 > 情報 の版の番号）、macOS の版を書いてください。
- 実会議の音声・本文・会議名・参加者名・API キーは添えないでください。必要なら架空の会議で再現してください。
- 受け取ったら、できるだけ早く返事します。直した版を出すまで、内容は公開しないでください。

## 対象

- 最新の公式の版と、`main` ブランチのソースコード。
- 例: 会議の音声・本文・API キーが意図せず外へ送られる・読まれる、ローカルの書き出しや同期が `local_only`（ローカルのみ）の会議を外に出す、ディープリンク（`minutes://`）や後処理の入力から任意の操作ができる、など。
- 文字起こし・要約に使う外部のサービス（ElevenLabs、OpenAI、Anthropic、Codex、Claude Code）そのものの問題は、それぞれの提供元に知らせてください。

## Minutes がデータを扱う方法

送信先と送信の条件は [README](README.md#送信先と送信の条件) にあります。API キーは Keychain に保存し、ログには API キー・音声・本文を出しません。利用状況の送信（テレメトリ）はしません。

---

## Security (English)

Please report vulnerabilities privately through GitHub's [Report a vulnerability](https://github.com/pictors/minutes/security/advisories/new), not in public issues. Include reproduction steps, the Minutes version (Settings > About), and your macOS version. Do not attach real meeting audio, transcripts, meeting titles, participant names, or API keys. We will respond as soon as we can; please keep the report private until a fix is released.
