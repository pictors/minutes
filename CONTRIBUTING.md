# 貢献の手順

Minutes への貢献を歓迎します。Issue と Pull Request は日本語でも英語でもかまいません。

## 始める前に

- 大きな変更は、先に Issue で相談してください。設計は [docs/SPEC.md](docs/SPEC.md)、開発の手順・コマンド・構成は [AGENTS.md](AGENTS.md) にあります。
- 不具合の報告には、設定 > 診断 の「診断情報を書き出す…」で書き出した JSON を添えてください（本文・音声・API キーは入らず、会議名は会議の ID に置き換わります）。
- セキュリティの問題は Issue に書かず、[SECURITY.md](SECURITY.md) の方法で知らせてください。

## Pull Request の前に

```bash
swift build
swift test
python3 scripts/check-public.py
```

- テストは実 API・録音デバイス・TCC の許可に頼らないようにします（実 API を使う任意のテストは環境変数で有効にするもので、架空の会議だけを送ります）。
- 実会議の音声・会議名・参加者名・発言を、コード・テスト・文書・コミットメッセージに入れないでください。テストの会議と人名は架空のものにします。
- API キーなどの秘密情報は入れないでください（`.env` は `.gitignore` 済み）。
- コードは周りの書き方に合わせます。識別子・ファイル名は英語、コメント・文書・コミットメッセージは日本語でかまいません。
- UI の動きを性能のために削らず、同じ見た目のまま軽い方法に置き換えてください（[AGENTS.md](AGENTS.md) の「ルール」）。

## Developer Certificate of Origin（DCO）

コミットには `Signed-off-by` の行を付けてください。`git commit -s` で付きます。

```
Signed-off-by: Your Name <you@example.com>
```

この行を付けることで、そのコミットについて [Developer Certificate of Origin 1.1](https://developercertificate.org/) に同意したことになります。要点は、自分で書いた（または公開してよいライセンスのもとで受け取った）コードを、このプロジェクトのライセンス（[Apache License 2.0](LICENSE)）で提供する権利があると表明することです。

## ライセンス

貢献したコードは [Apache License 2.0](LICENSE) で公開されます。名前「Minutes」とロゴの扱いは [TRADEMARKS.md](TRADEMARKS.md) を見てください。

---

## Contributing (English)

Contributions are welcome. Issues and pull requests may be written in English or Japanese.

- Discuss large changes in an issue first. See [docs/SPEC.md](docs/SPEC.md) for the design and [AGENTS.md](AGENTS.md) for commands and layout.
- Before opening a pull request, run `swift build`, `swift test`, and `python3 scripts/check-public.py`.
- Never include real meeting audio, meeting titles, participant names, transcripts, or API keys in code, tests, docs, or commit messages. Use fictional meetings and names in tests.
- Sign off your commits (`git commit -s`) to certify the [Developer Certificate of Origin 1.1](https://developercertificate.org/).
- Contributions are licensed under the [Apache License 2.0](LICENSE). Report security issues as described in [SECURITY.md](SECURITY.md).
