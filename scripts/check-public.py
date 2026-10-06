#!/usr/bin/env python3
"""公開してよいかの検査（禁止語の検査）。個人環境・実会議の情報・秘密情報がリポジトリに残っていないかを調べる。

使い方:
  python3 scripts/check-public.py                  # 作業ツリーの追跡ファイル（ファイル名も見る）
  python3 scripts/check-public.py --rev HEAD       # 指定した版のファイルと、その版までのコミットメッセージ
  python3 scripts/check-public.py --all-history    # すべてのコミットのファイルとコミットメッセージ（公開する履歴を確かめる）

禁止語の出どころ:
  --terms <file>   1 行 1 語（# から行末はコメント）。既定は $MINUTES_PRIVATE_TERMS か ~/.config/minutes/private-terms.txt。
                   一覧そのものが個人の情報なので、リポジトリには入れない。「!語」の行は、DB 由来でも禁止語にしない語（一般的な語）。
  --db <file>      Minutes の DB から会議名・カレンダーの件名・参加者・人物・話者の名前・タグ・用語を読む（読み取りのみ）。
                   既定は ~/Library/Application Support/Minutes/minutes.sqlite（なければ使わない）。--no-db で使わない。
  ほかに、このマシンのホームフォルダのパスと、API キーや秘密鍵の形をした文字列を見る。

  --exclude <glob> 公開しないファイル（検査しない）。複数指定できる。
  --show           見つけた語をそのまま出す（既定では DB 由来の語と秘密情報は伏せる）。

終了コード: 見つからなければ 0、見つかれば 1、使い方の誤りは 64。
"""
import argparse
import fnmatch
import json
import os
import re
import sqlite3
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

DEFAULT_TERMS = Path(os.environ.get("MINUTES_PRIVATE_TERMS", "~/.config/minutes/private-terms.txt")).expanduser()
DEFAULT_DB = Path("~/Library/Application Support/Minutes/minutes.sqlite").expanduser()

# 会議名として使われるが、それだけでは何も特定しない語（会議名がこれだけのときは禁止語にしない）
GENERIC_TITLES = {"会議", "新しい会議", "試しの録音", "定例", "ミーティング", "打ち合わせ", "mtg", "meeting", "自分", "相手", "会議の音声"}
# 録音の既定の名前（「Google Chrome 10月5日 13:55」）は実会議を特定しない
DEFAULT_TITLE = re.compile(r".* \d{1,2}月\d{1,2}日 \d{1,2}:\d{2}$")

SECRET_PATTERNS = [
    ("API キー（sk-）", re.compile(r"sk-[A-Za-z0-9_\-]{20,}")),
    ("API キー（sk_）", re.compile(r"sk_[A-Za-z0-9]{32,}")),
    ("GitHub トークン", re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}")),
    ("Slack トークン", re.compile(r"xox[abprs]-[A-Za-z0-9\-]{10,}")),
    ("AWS アクセスキー", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("秘密鍵", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("キーの値", re.compile(r"(?i)(api[_-]?key|secret|token)[\"']?\s*[:=]\s*[\"'][A-Za-z0-9_\-]{24,}[\"']")),
]

BINARY_SNIFF = 8192
MAX_BYTES = 5 * 1024 * 1024


@dataclass(frozen=True)
class Term:
    text: str
    category: str
    masked: bool

    def pattern(self) -> re.Pattern:
        escaped = re.escape(self.text)
        # 英数字だけの語は単語の途中に当たらないようにする（CJK は区切りがないので部分一致）
        if self.text.isascii():
            return re.compile(rf"(?<![A-Za-z0-9]){escaped}(?![A-Za-z0-9])", re.IGNORECASE)
        return re.compile(escaped)

    def display(self, show: bool) -> str:
        if show or not self.masked:
            return self.text
        return f"{self.text[0]}…（{len(self.text)} 文字）"


def usable(text: str) -> bool:
    text = text.strip()
    if not text or text.lower() in GENERIC_TITLES or DEFAULT_TITLE.match(text) or text.isdigit():
        return False
    # 英数字だけの短い語（「AI」など）は誤検出が多い
    return len(text) >= 4 if text.isascii() else len(text) >= 2


def load_list(path: Path) -> tuple[list[Term], set[str]]:
    """禁止語と、禁止語にしない語（「!」で始まる行）。"""
    if not path.exists():
        return [], set()
    terms, allowed = [], set()
    for line in path.read_text(encoding="utf-8").splitlines():
        text = line.split("#", 1)[0].strip()
        if text.startswith("!"):
            allowed.add(text[1:].strip().lower())
        elif text:
            terms.append(Term(text, "一覧", masked=False))
    return terms, allowed


def load_db(path: Path) -> list[Term]:
    if not path.exists():
        return []
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    terms: list[Term] = []

    def add(value, category):
        if isinstance(value, str) and usable(value):
            terms.append(Term(value.strip(), category, masked=True))

    try:
        for title, calendar_title, attendees, tags in connection.execute("SELECT title, calendar_title, attendees_json, tags_json FROM meetings"):
            add(title, "会議名")
            add(calendar_title, "会議名")
            for attendee in json.loads(attendees or "[]"):
                if isinstance(attendee, dict):
                    add(attendee.get("name"), "参加者")
                    add(attendee.get("email"), "参加者")
            for tag in json.loads(tags or "[]"):
                add(tag, "タグ")
        for name, email, aliases in connection.execute("SELECT name, email, aliases_json FROM people"):
            add(name, "人物")
            add(email, "人物")
            for alias in json.loads(aliases or "[]"):
                add(alias, "人物")
        for (name,) in connection.execute("SELECT display_name FROM speakers"):
            add(name, "話者")
        for (term,) in connection.execute("SELECT term FROM keyterms"):
            add(term, "用語")
    finally:
        connection.close()
    return terms


def load_settings_name() -> list[Term]:
    path = DEFAULT_DB.parent / "settings.json"
    try:
        name = json.loads(path.read_text(encoding="utf-8")).get("self_name")
    except (OSError, ValueError):
        return []
    return [Term(name.strip(), "自分の名前", masked=True)] if isinstance(name, str) and usable(name) else []


def unique(terms: list[Term]) -> list[Term]:
    seen: dict[str, Term] = {}
    for term in terms:
        seen.setdefault(term.text.lower(), term)
    # 長い語から当てる（同じ場所で短い語を重ねて数えない）
    return sorted(seen.values(), key=lambda term: -len(term.text))


def git(*args: str, input: bytes | None = None) -> bytes:
    return subprocess.run(["git", *args], check=True, capture_output=True, input=input).stdout


def tracked_files() -> list[tuple[str, bytes]]:
    names = [name for name in git("ls-files", "-z").decode().split("\0") if name]
    files = []
    for name in names:
        path = Path(name)
        if path.is_file() and path.stat().st_size <= MAX_BYTES:
            files.append((name, path.read_bytes()))
        else:
            files.append((name, b""))
    return files


def blobs(revs: list[str]) -> list[tuple[str, bytes]]:
    """版に含まれるファイル（同じ中身は 1 回だけ）。"""
    listing = git("rev-list", "--objects", *revs).decode().splitlines()
    entries = [line.split(" ", 1) for line in listing if " " in line]
    if not entries:
        return []
    checks = git("cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)", input="\n".join(sha for sha, _ in entries).encode()).decode().splitlines()
    files = []
    for (sha, name), check in zip(entries, checks):
        _, kind, size = check.split(" ")
        if kind != "blob":
            continue
        content = git("cat-file", "blob", sha) if int(size) <= MAX_BYTES else b""
        files.append((name, content))
    return files


def commit_messages(revs: list[str]) -> list[tuple[str, bytes]]:
    output = git("log", "--format=%H%x00%B%x1e", *revs).decode()
    messages = []
    for record in output.split("\x1e"):
        record = record.strip("\n")
        if "\x00" in record:
            sha, body = record.split("\x00", 1)
            messages.append((f"コミット {sha[:7]} のメッセージ", body.encode()))
    return messages


def scan(name: str, content: bytes, terms: list[tuple[Term, re.Pattern]], show: bool) -> list[str]:
    findings = []
    for term, pattern in terms:
        if pattern.search(name):
            findings.append(f"{name}: ファイル名に{term.category}「{term.display(show)}」")
    if b"\0" in content[:BINARY_SNIFF]:
        return findings
    text = content.decode("utf-8", errors="replace")
    for number, line in enumerate(text.splitlines(), start=1):
        for term, pattern in terms:
            if pattern.search(line):
                findings.append(f"{name}:{number}: {term.category}「{term.display(show)}」")
        for label, pattern in SECRET_PATTERNS:
            if pattern.search(line):
                findings.append(f"{name}:{number}: {label}")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(add_help=True, description="公開してよいかの検査（禁止語の検査）")
    parser.add_argument("--terms", type=Path, default=DEFAULT_TERMS)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--no-db", action="store_true")
    parser.add_argument("--rev", action="append", default=[])
    parser.add_argument("--all-history", action="store_true")
    parser.add_argument("--exclude", action="append", default=[])
    parser.add_argument("--show", action="store_true")
    try:
        args = parser.parse_args()
    except SystemExit as error:
        return 0 if error.code == 0 else 64

    root = Path(git("rev-parse", "--show-toplevel").decode().strip())
    os.chdir(root)
    home = Path.home().as_posix()
    terms, allowed = load_list(args.terms)
    if not home.endswith("/example"):
        terms.append(Term(home, "ホームフォルダ", masked=False))
    if not args.no_db:
        terms += [term for term in load_db(args.db) + load_settings_name() if term.text.lower() not in allowed]
    compiled = [(term, term.pattern()) for term in unique(terms)]

    if args.all_history:
        sources = blobs(["--all"]) + commit_messages(["--all"])
        scope = "すべてのコミット"
    elif args.rev:
        sources = blobs(args.rev) + commit_messages(args.rev)
        scope = "、".join(args.rev)
    else:
        sources = tracked_files()
        scope = "作業ツリーの追跡ファイル"
    sources = [(name, content) for name, content in sources if not any(fnmatch.fnmatch(name, glob) for glob in args.exclude)]

    findings: list[str] = []
    for name, content in sources:
        findings += scan(name, content, compiled, args.show)
    counts = {category: sum(1 for term, _ in compiled if term.category == category) for category in dict.fromkeys(term.category for term, _ in compiled)}
    print(f"検査: {scope}（{len(sources)} 件）。禁止語 {len(compiled)} 語: " + "、".join(f"{key} {value}" for key, value in counts.items()))
    if not args.terms.exists():
        print(f"注意: 禁止語の一覧 {args.terms} がありません")
    for finding in dict.fromkeys(findings):
        print(finding)
    print(f"{len(set(findings))} 件")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
