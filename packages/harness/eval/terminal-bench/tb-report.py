#!/usr/bin/env python3
"""Summarize a Harbor job directory (pass rate + per-task status)."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _load_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def summarize(job_dir: Path) -> int:
    trials = sorted(job_dir.glob("trials/*"))
    if not trials:
        print(f"No trials under {job_dir}/trials", file=sys.stderr)
        return 1

    passed = 0
    failed = 0
    rows: list[tuple[str, str, str]] = []

    for trial in trials:
        task_id = trial.name
        result_path = trial / "result.json"
        data = _load_json(result_path) if result_path.is_file() else None
        status = "unknown"
        detail = ""
        if data:
            status = str(data.get("status") or data.get("verifier_result") or "unknown")
            detail = str(data.get("message") or data.get("error") or "")[:80]
        if status in {"pass", "passed", "success", "ok"}:
            passed += 1
        elif status in {"fail", "failed", "error"}:
            failed += 1
        rows.append((task_id, status, detail))

    total = len(rows)
    print(f"job: {job_dir}")
    print(f"trials: {total}  passed: {passed}  failed: {failed}  other: {total - passed - failed}")
    if total:
        print(f"pass@1: {100.0 * passed / total:.1f}%")
    print()
    print("task_id\tstatus\tdetail")
    for task_id, status, detail in rows:
        print(f"{task_id}\t{status}\t{detail}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "job_dir",
        type=Path,
        help="Harbor job output directory (contains trials/)",
    )
    args = parser.parse_args()
    return summarize(args.job_dir.resolve())


if __name__ == "__main__":
    raise SystemExit(main())
