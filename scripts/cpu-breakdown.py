#!/usr/bin/env python3
"""録音フォルダの capture_stats.jsonl から、録音中の CPU を画面の状態とスレッドごとに集計する（G7 の診断）。

使い方: python3 scripts/cpu-breakdown.py <録音フォルダ>
  アプリの録音は ~/Library/Application Support/Minutes/audio/<会議 id>/
  CPU は 1 コアを 100% とした値。ui と threads は 2026-09-30 以降の録音にだけある。
"""
import json
import sys
from collections import defaultdict
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip())
        return 64
    path = Path(sys.argv[1]) / "capture_stats.jsonl"
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not rows:
        print("統計がありません")
        return 1
    groups = defaultdict(list)
    for row in rows:
        groups[row.get("ui") or "記録なし"].append(row)
    interval = rows[-1]["elapsed_seconds"] / max(len(rows), 1)
    print("画面の状態ごとの CPU（平均）")
    for ui, members in sorted(groups.items(), key=lambda item: -len(item[1])):
        cpu = sum(row["cpu_percent"] for row in members) / len(members)
        print(f"  {ui:14} {cpu:5.1f}%  （約 {len(members) * interval / 60:.0f} 分）")
        totals = defaultdict(float)
        for row in members:
            for name, value in (row.get("threads") or {}).items():
                totals[name] += value
        for name, value in sorted(totals.items(), key=lambda item: -item[1])[:6]:
            print(f"      {name:40} {value / len(members):5.1f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
