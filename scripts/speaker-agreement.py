#!/usr/bin/env python3
"""話者分離の一致度を測る（DER の簡易版）。

transcript.json の segments（t_start / t_end / speaker）と、参照の話者区間
（reference.speakers.json: [{speaker, start, end}]）の時間重なりから、
プロバイダのラベル → 参照話者 の最尤対応を作り、対応どおりに割り当てられた時間の割合を出す。

使い方: speaker-agreement.py transcript.json reference.speakers.json [--track system]
"""
import argparse
import json
from collections import defaultdict


def overlap(a0, a1, b0, b1):
    return max(0.0, min(a1, b1) - max(a0, b0))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("transcript")
    parser.add_argument("reference")
    parser.add_argument("--track", default=None)
    args = parser.parse_args()

    doc = json.load(open(args.transcript, encoding="utf-8"))
    segments = [s for s in doc["segments"] if not args.track or s["track"] == args.track]
    reference = json.load(open(args.reference, encoding="utf-8"))

    matrix = defaultdict(lambda: defaultdict(float))
    total = 0.0
    for seg in segments:
        label = seg.get("speaker") or "?"
        for ref in reference:
            o = overlap(seg["t_start"], seg["t_end"], ref["start"], ref["end"])
            if o > 0:
                matrix[label][ref["speaker"]] += o
                total += o

    # 最尤対応（重なりの大きい順に貪欲に 1 対 1 で対応付け）
    pairs = sorted(((v, label, ref) for label, row in matrix.items() for ref, v in row.items()), reverse=True)
    mapping, used = {}, set()
    for v, label, ref in pairs:
        if label in mapping or ref in used:
            continue
        mapping[label] = ref
        used.add(ref)
    correct = sum(matrix[label][ref] for label, ref in mapping.items())

    print(f"provider: {doc['provider']}")
    print(f"labels: {len(matrix)}  reference speakers: {len({r['speaker'] for r in reference})}")
    for label, row in sorted(matrix.items(), key=lambda kv: -sum(kv[1].values())):
        dist = ", ".join(f"{ref}={v:.0f}s" for ref, v in sorted(row.items(), key=lambda kv: -kv[1]))
        print(f"  {label} → {mapping.get(label, '(unmapped)')}   [{dist}]")
    print(f"speaker agreement: {100 * correct / total:.1f}% of {total:.0f}s overlapped speech")


if __name__ == "__main__":
    main()
