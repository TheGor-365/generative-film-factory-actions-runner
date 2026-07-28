#!/usr/bin/env bash
set -euo pipefail

: "${GFF_WAVE_C_WORK_ROOT:?GFF_WAVE_C_WORK_ROOT is required}"

records_path="$GFF_WAVE_C_WORK_ROOT/evidence/gate_state.json"
logs_root="$GFF_WAVE_C_WORK_ROOT/logs"

python3 - "$records_path" "$logs_root" "$GFF_WAVE_C_WORK_ROOT" <<'PY'
from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

records_path = Path(sys.argv[1])
logs_root = Path(sys.argv[2])
work_root = sys.argv[3]

if not records_path.is_file():
    print("BOUNDED_FAILURE_DIAGNOSTICS=STATE_MISSING")
    print("NO_FAKE_GREEN=true")
    raise SystemExit(0)

try:
    state = json.loads(records_path.read_text(encoding="utf-8"))
except Exception:
    print("BOUNDED_FAILURE_DIAGNOSTICS=STATE_INVALID")
    print("NO_FAKE_GREEN=true")
    raise SystemExit(0)

records = [
    item
    for item in state.get("records", [])
    if isinstance(item, dict) and item.get("outcome") != "PASS"
]

log_by_sha: dict[str, Path] = {}
if logs_root.is_dir():
    for path in sorted(logs_root.glob("*.log")):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        log_by_sha[digest] = path

safe_line_patterns = [
    re.compile(r"(?:LoadError|NameError|NoMethodError|ArgumentError|TypeError|RuntimeError|JSON::ParserError|Errno::[A-Z0-9_]+)"),
    re.compile(r"(?:cannot load such file|No such file or directory|uninitialized constant|undefined method)", re.I),
    re.compile(r"\b\d+\s+runs?,\s*\d+\s+assertions?,\s*\d+\s+failures?,\s*\d+\s+errors?\b", re.I),
    re.compile(r"(?:FAILURE_CODE|POLICY_ERROR|VALIDATION_ERROR|MANIFEST_ERROR|REPORT_ERROR|PACKAGE_ERROR|BLOCKER_CODE)=[A-Za-z0-9_.:-]+"),
    re.compile(r"^\s*(?:Failure|Error):\s+[A-Za-z0-9_:]+", re.I),
]

classification_patterns = [
    ("RUBY_LOAD_ERROR", re.compile(r"LoadError|cannot load such file", re.I)),
    ("FILE_NOT_FOUND", re.compile(r"No such file or directory|Errno::ENOENT", re.I)),
    ("RUBY_NAME_ERROR", re.compile(r"NameError|uninitialized constant", re.I)),
    ("RUBY_METHOD_ERROR", re.compile(r"NoMethodError|undefined method", re.I)),
    ("RUBY_ARGUMENT_ERROR", re.compile(r"ArgumentError", re.I)),
    ("RUBY_TYPE_ERROR", re.compile(r"TypeError", re.I)),
    ("JSON_PARSE_ERROR", re.compile(r"JSON::ParserError", re.I)),
    ("MINITEST_FAILURE", re.compile(r"\b\d+\s+runs?,\s*\d+\s+assertions?,\s*[1-9]\d*\s+failures?", re.I)),
    ("MINITEST_ERROR", re.compile(r"\b\d+\s+runs?,\s*\d+\s+assertions?,\s*\d+\s+failures?,\s*[1-9]\d*\s+errors?", re.I)),
]

secret_pattern = re.compile(r"(?i)\b(token|authorization|secret|password)\b\s*[:=]\s*\S+")
url_pattern = re.compile(r"https?://\S+")
control_pattern = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def sanitize(line: str) -> str:
    line = control_pattern.sub("", line)
    line = line.replace(work_root, "<WORK_ROOT>")
    line = re.sub(r"/home/runner/work/[^\s:]+", "<RUNNER_PATH>", line)
    line = secret_pattern.sub(lambda match: f"{match.group(1)}=<REDACTED>", line)
    line = url_pattern.sub("<URL>", line)
    return line[:320]

print(f"BOUNDED_FAILURE_DIAGNOSTICS_RECORD_COUNT={len(records)}")
for record in sorted(records, key=lambda item: (str(item.get("step_id")), str(item.get("command_id")))):
    step_id = str(record.get("step_id", "unknown"))
    command_id = str(record.get("command_id", "unknown"))
    outcome = str(record.get("outcome", "unknown"))
    exit_code = int(record.get("exit_code", -1))
    evidence_sha = str(record.get("evidence_sha256", ""))
    stable_codes = ",".join(sorted(str(code) for code in record.get("stable_codes", []) if code)) or "NONE"
    print(
        "DIAGNOSTIC_RECORD "
        f"step={step_id} command={command_id} outcome={outcome} "
        f"exit_code={exit_code} evidence_sha256={evidence_sha} stable_codes={stable_codes}"
    )

    log_path = log_by_sha.get(evidence_sha)
    if log_path is None:
        print(f"DIAGNOSTIC_CLASS step={step_id} command={command_id} class=NO_MATCHING_LOG")
        continue

    text = log_path.read_text(encoding="utf-8", errors="replace")
    classes = [name for name, pattern in classification_patterns if pattern.search(text)]
    if not classes:
        classes = ["NONZERO_NO_ALLOWLISTED_CLASS"]
    print(
        f"DIAGNOSTIC_CLASS step={step_id} command={command_id} "
        f"class={','.join(classes)} log_sha256={evidence_sha}"
    )

    safe_lines: list[str] = []
    seen: set[str] = set()
    for raw_line in text.splitlines():
        if not any(pattern.search(raw_line) for pattern in safe_line_patterns):
            continue
        line = sanitize(raw_line)
        if not line or line in seen:
            continue
        seen.add(line)
        safe_lines.append(line)
        if len(safe_lines) >= 12:
            break

    print(f"DIAGNOSTIC_SAFE_LINE_COUNT step={step_id} command={command_id} count={len(safe_lines)}")
    for index, line in enumerate(safe_lines, start=1):
        print(f"DIAGNOSTIC_SAFE_LINE step={step_id} command={command_id} index={index} text={line}")

print("BOUNDED_FAILURE_DIAGNOSTICS=COMPLETE")
print("PRIVATE_PAYLOAD_OUTPUT=false")
print("PUBLIC_ARTIFACT_UPLOAD=false")
print("CACHE_CREATED=false")
print("NO_FAKE_GREEN=true")
PY
