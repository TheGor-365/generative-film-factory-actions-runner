#!/usr/bin/env python3
"""Strict immutable contracts for PilotRunner report evidence."""
from __future__ import annotations

import hashlib
import json
import os
import re
import stat
from pathlib import Path
from typing import Any

PILOT_SCHEMA = "factory_120s_pilot_report_v02"
PILOT_ID = "GFF-PILOT-120S-001"
PILOT_PROFILE = "original_story_private_120s_v01"
MANIFEST_SCHEMA = "media_delivery_manifest_v02"
RUN_CONTEXT_SCHEMA = "factory_120s_run_context_v02"
BINDING_SCHEMA = "gff_wave_c_pilot_report_binding_v01"
TWO_RUN_SCHEMA = "gff_wave_c_two_run_binding_v01"
SHA40 = re.compile(r"^[0-9a-f]{40}$")
SHA64 = re.compile(r"^[0-9a-f]{64}$")
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", re.I)


class EvidenceError(RuntimeError):
    def __init__(self, code: str, detail: str = "") -> None:
        super().__init__(detail or code)
        self.code = code
        self.detail = detail


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def self_hash(payload: dict[str, Any], field: str) -> str:
    return hashlib.sha256(canonical_bytes({key: value for key, value in payload.items() if key != field})).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_object(path: Path, code: str) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(code, str(error)) from error
    if not isinstance(payload, dict):
        raise EvidenceError(code, "JSON root must be an object")
    return payload


def parse_single_cli_object(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise EvidenceError("CLI_JSON_MISSING", str(error)) from error
    if not raw.strip():
        raise EvidenceError("CLI_JSON_MISSING")
    stripped = raw.lstrip()
    decoder = json.JSONDecoder()
    try:
        payload, end = decoder.raw_decode(stripped)
    except json.JSONDecodeError as error:
        raise EvidenceError("CLI_JSON_MALFORMED", str(error)) from error
    if stripped[end:].strip():
        raise EvidenceError("CLI_JSON_AMBIGUOUS")
    if not isinstance(payload, dict):
        raise EvidenceError("CLI_JSON_NOT_OBJECT")
    return payload


def require_string(payload: dict[str, Any], key: str, code: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value:
        raise EvidenceError(code, key)
    return value


def require_equal(payload: dict[str, Any], key: str, expected: Any, code: str) -> None:
    if payload.get(key) != expected:
        raise EvidenceError(code, f"{key}: {payload.get(key)!r} != {expected!r}")


def exact_root(value: str, expected: Path, code: str) -> Path:
    candidate = Path(value)
    if not candidate.is_absolute():
        raise EvidenceError(code, "root must be absolute")
    if expected.is_symlink() or not expected.is_dir():
        raise EvidenceError(code, "expected root is missing or symlinked")
    try:
        candidate_resolved = candidate.resolve(strict=True)
        expected_resolved = expected.resolve(strict=True)
    except OSError as error:
        raise EvidenceError(code, str(error)) from error
    if candidate_resolved != expected_resolved or os.path.normpath(value) != os.path.normpath(str(expected)):
        raise EvidenceError(code)
    return expected_resolved


def lexical_child(root: Path, candidate: Path, code: str) -> Path:
    if not candidate.is_absolute():
        raise EvidenceError(code, "path must be absolute")
    try:
        relative = candidate.relative_to(root)
    except ValueError as error:
        raise EvidenceError(code, "lexical escape") from error
    if not relative.parts:
        raise EvidenceError(code, "path must be a child")
    return relative


def reject_symlink_components(root: Path, candidate: Path, code: str) -> None:
    relative = lexical_child(root, candidate, code)
    current = root
    for part in relative.parts:
        current = current / part
        try:
            mode = current.lstat().st_mode
        except OSError as error:
            raise EvidenceError(code, str(error)) from error
        if stat.S_ISLNK(mode):
            raise EvidenceError(code, f"symlink component: {current}")


def confined_regular_file(root: Path, raw: str, code: str) -> Path:
    candidate = Path(raw)
    lexical_child(root, candidate, code)
    reject_symlink_components(root, candidate, code)
    try:
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(root.resolve(strict=True))
    except (OSError, ValueError) as error:
        raise EvidenceError(code, str(error)) from error
    try:
        mode = candidate.lstat().st_mode
    except OSError as error:
        raise EvidenceError(code, str(error)) from error
    if not stat.S_ISREG(mode):
        raise EvidenceError(code, "not a regular file")
    return candidate


def confined_directory(root: Path, raw: str, code: str) -> Path:
    candidate = Path(raw)
    lexical_child(root, candidate, code)
    reject_symlink_components(root, candidate, code)
    try:
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(root.resolve(strict=True))
    except (OSError, ValueError) as error:
        raise EvidenceError(code, str(error)) from error
    if not candidate.is_dir() or candidate.is_symlink():
        raise EvidenceError(code, "not a regular directory")
    return candidate


def require_fresh(path: Path, marker: Path, code: str) -> None:
    try:
        if path.stat().st_mtime_ns < marker.stat().st_mtime_ns:
            raise EvidenceError(code)
    except OSError as error:
        raise EvidenceError(code, str(error)) from error


def require_sha(path: Path, expected: str, code: str) -> str:
    if not SHA64.fullmatch(expected):
        raise EvidenceError(code, "invalid expected SHA-256")
    observed = sha256_file(path)
    if observed != expected:
        raise EvidenceError(code, f"{observed} != {expected}")
    return observed


def validate_report_identity(report: dict[str, Any], *, expected_mode: str, expected_source_sha: str) -> None:
    require_equal(report, "schema_version", PILOT_SCHEMA, "REPORT_SCHEMA_MISMATCH")
    require_equal(report, "pilot_id", PILOT_ID, "REPORT_PILOT_ID_MISMATCH")
    require_equal(report, "profile", PILOT_PROFILE, "REPORT_PROFILE_MISMATCH")
    require_equal(report, "product_profile", PILOT_PROFILE, "REPORT_PRODUCT_PROFILE_MISMATCH")
    require_equal(report, "status", "passed", "REPORT_STATUS_NOT_PASSED")
    require_equal(report, "mode", expected_mode, "REPORT_MODE_MISMATCH")
    require_equal(report, "source_head", expected_source_sha, "REPORT_SOURCE_SHA_MISMATCH")
    require_equal(report, "pipeline_state", "delivered", "REPORT_PIPELINE_STATE_MISMATCH")
    require_equal(report, "fallback_used", True, "REPORT_FALLBACK_TRUTH_MISMATCH")
    require_equal(report, "real_provider_observed", False, "REPORT_PROVIDER_TRUTH_MISMATCH")
    require_equal(report, "provider_request_ids", [], "REPORT_PROVIDER_REQUESTS_PRESENT")
    run_id = require_string(report, "run_id", "REPORT_RUN_ID_MISSING")
    if not UUID.fullmatch(run_id):
        raise EvidenceError("REPORT_RUN_ID_INVALID")
    for key in (
        "order_id", "order_brief_id", "pipeline_run_id", "story_package_id", "delivery_package_id",
        "report_path", "manifest_path", "delivery_zip_path", "qc_report_path", "delivery_root",
        "run_context_path", "runtime_root", "artifact_root", "run_root", "core_db_path",
    ):
        require_string(report, key, f"REPORT_{key.upper()}_MISSING")
    for key in ("source_sha256", "manifest_sha256", "qc_report_sha256", "delivery_zip_sha256"):
        value = require_string(report, key, f"REPORT_{key.upper()}_MISSING")
        if not SHA64.fullmatch(value):
            raise EvidenceError(f"REPORT_{key.upper()}_INVALID")


def validate_context(report: dict[str, Any], context_path: Path) -> None:
    context = read_object(context_path, "RUN_CONTEXT_JSON_INVALID")
    mappings = {
        "schema_version": RUN_CONTEXT_SCHEMA,
        "pilot_id": report["pilot_id"],
        "profile": report["profile"],
        "run_id": report["run_id"],
        "source_head": report["source_head"],
        "mode": report["mode"],
        "runtime_root": report["runtime_root"],
        "artifact_root": report["artifact_root"],
        "run_root": report["run_root"],
        "core_db_path": report["core_db_path"],
        "order_id": report["order_id"],
        "order_brief_id": report["order_brief_id"],
        "pipeline_run_id": report["pipeline_run_id"],
        "story_package_id": report["story_package_id"],
        "delivery_package_id": report["delivery_package_id"],
    }
    for key, expected in mappings.items():
        if context.get(key) != expected:
            raise EvidenceError("RUN_CONTEXT_SEMANTIC_MISMATCH", key)


def validate_manifest(report: dict[str, Any], manifest_path: Path) -> dict[str, Any]:
    manifest = read_object(manifest_path, "MANIFEST_JSON_INVALID")
    require_equal(manifest, "schema_version", MANIFEST_SCHEMA, "MANIFEST_SCHEMA_MISMATCH")
    mappings = {
        "pilot_id": report["pilot_id"],
        "product_profile": report["product_profile"],
        "order_id": report["order_id"],
        "order_brief_id": report["order_brief_id"],
        "pipeline_run_id": report["pipeline_run_id"],
        "story_package_id": report["story_package_id"],
        "source_sha256": report["source_sha256"],
        "fallback_used": report["fallback_used"],
    }
    for key, expected in mappings.items():
        if manifest.get(key) != expected:
            raise EvidenceError("MANIFEST_SEMANTIC_MISMATCH", key)
    try:
        if float(manifest.get("duration_seconds")) != float(report.get("final_duration_seconds")):
            raise EvidenceError("MANIFEST_DURATION_MISMATCH")
    except (TypeError, ValueError) as error:
        raise EvidenceError("MANIFEST_DURATION_MISMATCH", str(error)) from error
    return manifest

