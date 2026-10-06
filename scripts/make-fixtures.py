#!/usr/bin/env python3
"""TTS（macOS `say`）で 2 トラックの短い日本語会話 fixture を作る（SPEC §13）。

出力: fixtures/sample_meeting/
  system_16k.wav  相手側 2 名（A: Kyoko, B: Reed）
  mic_16k.wav     自分（me: Eddy）
  reference.txt   参照テキスト（発話順、話者プレフィックス付き）
  script.json     発話ごとの話者・時刻（話者分離の評価用）

実会議の音声は入れない。生成物は .gitignore 対象（*.wav）。
"""
import json
import os
import struct
import subprocess
import sys
import tempfile
import wave

RATE = 16000
OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "fixtures", "sample_meeting")

VOICES = {
    "A": "Kyoko",
    "B": "Reed (Japanese (Japan))",
    "me": "Eddy (Japanese (Japan))",
}

# (話者, テキスト)。A/B は system トラック、me は mic トラック。
SCRIPT = [
    ("A", "おはようございます。今日の定例を始めます。"),
    ("me", "おはようございます。よろしくお願いします。"),
    ("A", "まず、新機能のリリース日について確認したいです。"),
    ("B", "開発は来週の水曜日に完了する予定です。テストに二日ほど見ておきたいです。"),
    ("me", "それなら、リリースは来週の金曜日でどうでしょうか。"),
    ("A", "問題ありません。金曜日で決定しましょう。"),
    ("B", "了解しました。リリースノートの下書きは私が担当します。"),
    ("me", "ありがとうございます。私は顧客への案内メールを木曜日までに用意します。"),
    ("A", "次に、先週問い合わせのあった請求書の件です。"),
    ("B", "経理に確認したところ、来月の初めに再発行できるそうです。"),
    ("me", "では、その内容を田中さんに伝えておきます。"),
    ("A", "お願いします。他に議題はありますか。"),
    ("me", "特にありません。"),
    ("B", "私もありません。"),
    ("A", "それでは、本日はここまでにします。ありがとうございました。"),
]

GAP_SECONDS = 0.7


def say_to_wav(voice, text, path):
    subprocess.run(
        ["say", "-v", voice, "-o", path, "--file-format=WAVE", f"--data-format=LEI16@{RATE}", text],
        check=True,
    )


def read_wav(path):
    with wave.open(path, "rb") as w:
        assert w.getframerate() == RATE, w.getframerate()
        assert w.getsampwidth() == 2
        frames = w.readframes(w.getnframes())
        channels = w.getnchannels()
    if channels > 1:
        samples = struct.unpack("<%dh" % (len(frames) // 2), frames)
        mono = samples[0::channels]
        frames = struct.pack("<%dh" % len(mono), *mono)
    return frames


def write_wav(path, frames):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(frames)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    system = bytearray()
    mic = bytearray()
    script_out = []
    cursor = 0.0
    with tempfile.TemporaryDirectory() as tmp:
        for index, (speaker, text) in enumerate(SCRIPT):
            path = os.path.join(tmp, f"utt_{index:02d}.wav")
            say_to_wav(VOICES[speaker], text, path)
            frames = read_wav(path)
            duration = len(frames) / 2 / RATE
            silence = b"\x00\x00" * (len(frames) // 2)  # frames はバイト列（16-bit）
            if speaker == "me":
                mic.extend(frames)
                system.extend(silence)
            else:
                system.extend(frames)
                mic.extend(silence)
            script_out.append({"speaker": speaker, "text": text, "start": round(cursor, 3), "end": round(cursor + duration, 3)})
            cursor += duration
            gap = b"\x00\x00" * int(GAP_SECONDS * RATE)
            system.extend(gap)
            mic.extend(gap)
            cursor += GAP_SECONDS
    write_wav(os.path.join(OUT_DIR, "system_16k.wav"), bytes(system))
    write_wav(os.path.join(OUT_DIR, "mic_16k.wav"), bytes(mic))
    with open(os.path.join(OUT_DIR, "reference.txt"), "w", encoding="utf-8") as f:
        for speaker, text in SCRIPT:
            f.write(f"{speaker}: {text}\n")
    with open(os.path.join(OUT_DIR, "script.json"), "w", encoding="utf-8") as f:
        json.dump({"sample_rate": RATE, "utterances": script_out}, f, ensure_ascii=False, indent=2)
    print(f"wrote {OUT_DIR} ({cursor:.1f} s, {len(SCRIPT)} utterances)")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(f"say failed: {error}", file=sys.stderr)
        sys.exit(1)
