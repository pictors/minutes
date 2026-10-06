# fixtures

テスト用の短い音声と参照テキスト。**実会議の音声は入れない。**

- `sample_meeting/` — `scripts/make-fixtures.py` が macOS の TTS（`say`）で生成する 2 トラックの模擬会議（約 1 分）。
  - `system_16k.wav`（相手側 2 名）、`mic_16k.wav`（自分）、`reference.txt`、`script.json`
  - WAV は `.gitignore` 対象。必要なときに再生成する:

```bash
python3 scripts/make-fixtures.py
```

使い方（Local プロバイダの動作確認）:

```bash
swift run -c release minutes-cli transcribe fixtures/sample_meeting --provider local
swift run -c release minutes-cli eval fixtures/sample_meeting/transcript.local.json fixtures/sample_meeting/reference.txt --strip-speaker-prefix
```
