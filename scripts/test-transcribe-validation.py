#!/usr/bin/env python3
"""合成 WAV だけで CLI の品質検証順を確認する。外部プロバイダは作成しない。"""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import wave


def main() -> None:
    cli = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/minutes-cli").resolve()
    # 必ず未知のプロバイダを指定する。品質検証後も API の作成・送信へ進ませない。
    provider = "validation-probe"
    stats = {
        "name": "system", "source_sample_rate": 16000, "source_channels": 1,
        "archive_sample_rate": 16000, "received_frames": 16000,
        "received_seconds": 1, "written_seconds": 1,
        "first_chunk_offset_seconds": 0, "gap_count": 0, "gap_seconds": 0,
        "overlap_count": 0, "overlap_seconds": 0, "format_changes": 0,
        "last_rms_db": -20, "interval_peak_rms_db": -20, "active_seconds": 1,
        "last_chunk_timeline_end": 1,
    }
    base = {
        "schema_version": 1, "id": "synthetic-cli-test",
        "started_at": "2026-09-22T00:00:00Z", "duration_seconds": 1,
        "target_bundle_identifiers": [], "all_system_audio": False,
        "tapped_processes": [], "files": {"system_stt": "system_16k.wav"},
        "tracks": {"system": stats}, "events": [],
    }

    with tempfile.TemporaryDirectory(prefix="minutes-cli-validation-") as temporary:
        root = Path(temporary)

        def check(name: str, manifest: dict | None, expected: str, *, frames: int = 16000, malformed: bool = False) -> None:
            directory = root / name
            directory.mkdir()
            audio = directory / "system_16k.wav"
            with wave.open(str(audio), "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(16000)
                wav.writeframes(b"\x01\x00" * frames)
            if manifest is not None:
                (directory / "recording.json").write_text("{" if malformed else json.dumps(manifest), encoding="utf-8")
            result = subprocess.run(
                [str(cli), "transcribe", str(directory), "--provider", provider],
                cwd=root, capture_output=True, text=True, timeout=10,
            )
            output = result.stdout + result.stderr
            assert result.returncode != 0, f"{name}: unexpected success"
            assert expected in output, f"{name}: {output}"
            if expected != provider:
                assert provider not in output, f"{name}: reached provider before validation"
            assert not list(directory.glob("transcript.*")), f"{name}: unexpected transcript"
            print(f"PASS {name}")

        check("valid-recording", base, provider)
        check("import-without-manifest", None, provider)
        check("empty-audio", base, "音声ファイルが空です", frames=0)

        mismatch = copy.deepcopy(base)
        mismatch["duration_seconds"] = 10
        mismatch["tracks"]["system"].update(written_seconds=10, last_chunk_timeline_end=10)
        check("duration-mismatch", mismatch, "録音品質の検証")

        failed = copy.deepcopy(base)
        failed["tracks"]["system"]["failure"] = {
            "track": "system", "operation": "fixture failure", "message": "synthetic capture failure",
        }
        check("capture-failure", failed, "synthetic capture failure")

        missing = copy.deepcopy(base)
        missing["tracks"]["mic"] = {**stats, "name": "mic"}
        check("missing-track", missing, "mic の音声ファイルがありません")
        check("malformed-manifest", base, "error:", malformed=True)


if __name__ == "__main__":
    main()
