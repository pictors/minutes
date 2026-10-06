#!/usr/bin/env python3
"""既存の文字起こし（ほかのサービスの書き出しなど）から、切り出した区間の参照テキストを作る。

入力形式:
  - JSON: セグメント配列（または {"segments": [...]} / {"transcript": [...]}）。
          キーは startTimestamp/endTimestamp/speaker/words または start/end/speaker/text
  - テキスト: "[hh:mm:ss] 話者: 本文" または "hh:mm:ss 話者: 本文" の行

使い方:
  reference-from-transcript.py <transcript.json|txt> --start 600 --end 900 --out reference.txt
  → reference.txt（"話者: 本文" 行）と reference.speakers.json（切り出し開始を 0 とした話者区間）を書く

注意: 機械生成の文字起こしを参照にすると CER は「一致率」であって正解率ではない。
      短い区間なら人手で reference.txt を直してから eval する。
"""
import argparse
import json
import re
import sys

LINE_RE = re.compile(r"^\s*\[?(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?\]?\s*(?:([^:：]{1,40})[:：])?\s*(.+)$")


def parse_time(raw):
    parts = raw.split(":")
    seconds = 0.0
    for part in parts:
        seconds = seconds * 60 + float(part)
    return seconds


def load_segments(path):
    text = open(path, encoding="utf-8").read()
    stripped = text.lstrip()
    if stripped.startswith("[") or stripped.startswith("{"):
        data = json.loads(text)
        if isinstance(data, dict):
            for key in ("segments", "transcript", "utterances", "items"):
                if key in data:
                    data = data[key]
                    break
        if isinstance(data, dict) and "transcripts" in data:
            data = data["transcripts"]
        if isinstance(data, list) and data and isinstance(data[0], dict) and "segments" in data[0]:
            data = data[0]["segments"]
        segments = []
        for item in data:
            start = item.get("startTimestamp", item.get("start", item.get("t_start")))
            end = item.get("endTimestamp", item.get("end", item.get("t_end", start)))
            speaker = item.get("speaker") or "?"
            words = item.get("words", item.get("text", ""))
            if start is None:
                continue
            segments.append({"start": float(start), "end": float(end), "speaker": speaker, "text": str(words).strip()})
        return segments
    segments = []
    for line in text.splitlines():
        match = LINE_RE.match(line)
        if not match:
            continue
        hours, minutes, secs, speaker, body = match.groups()
        if speaker:
            speaker = speaker.replace("*", "").strip()  # Markdown の太字（書き出しによっては付く）を外す
        body = body.replace("**", "").strip()
        if secs is None:
            start = int(hours) * 60 + int(minutes)
        else:
            start = int(hours) * 3600 + int(minutes) * 60 + int(secs)
        segments.append({"start": float(start), "end": float(start), "speaker": (speaker or "?").strip(), "text": body.strip()})
    for index in range(len(segments) - 1):
        segments[index]["end"] = max(segments[index]["end"], segments[index + 1]["start"])
    return segments


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("transcript")
    parser.add_argument("--start", required=True, help="区間の開始（秒 または mm:ss / hh:mm:ss）")
    parser.add_argument("--end", required=True, help="区間の終了（秒 または mm:ss / hh:mm:ss）")
    parser.add_argument("--out", default="reference.txt")
    args = parser.parse_args()
    start = parse_time(args.start)
    end = parse_time(args.end)
    segments = [s for s in load_segments(args.transcript) if s["start"] >= start and s["start"] < end]
    if not segments:
        print("該当する区間のセグメントがありません", file=sys.stderr)
        sys.exit(1)
    with open(args.out, "w", encoding="utf-8") as f:
        for segment in segments:
            f.write(f"{segment['speaker']}: {segment['text']}\n")
    speakers_path = re.sub(r"\.txt$", "", args.out) + ".speakers.json"
    with open(speakers_path, "w", encoding="utf-8") as f:
        json.dump(
            [{"speaker": s["speaker"], "start": round(s["start"] - start, 3), "end": round(max(s["end"], s["start"]) - start, 3)} for s in segments],
            f, ensure_ascii=False, indent=2,
        )
    names = sorted({s["speaker"] for s in segments})
    print(f"wrote {args.out} ({len(segments)} segments, speakers: {', '.join(names)}) and {speakers_path}")


if __name__ == "__main__":
    main()
