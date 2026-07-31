#!/usr/bin/env python3
"""Discover, bind, validate and normalize PilotRunner evidence."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from report_discovery_contract import *  # noqa: F403

PER_RUN_BINDING_FIELDS = (
    "schema_version",
    "pilot_id",
    "profile",
    "status",
    "mode",
    "source_head",
    "run_id",
    "delivery_package_id",
    "runtime_root",
    "artifact_root",
    "run_root",
    "report_original_path",
    "report_normalized_path",
    "report_sha256",
    "manifest_path",
    "manifest_sha256",
    "run_context_path",
    "run_context_sha256",
    "delivery_zip_path",
    "delivery_zip_sha256",
    "qc_report_path",
    "qc_report_sha256",
    "binding_sha256",
)
PER_RUN_BINDING_KEYS = frozenset(PER_RUN_BINDING_FIELDS)
TWO_RUN_BINDING_FIELDS = (
    "schema_version",
    "source_head",
    "mode",
    "run_a",
    "run_b",
    "binding_sha256",
)
TWO_RUN_BINDING_KEYS = frozenset(TWO_RUN_BINDING_FIELDS)
DISTINCT_RUN_FIELDS = (
    "run_id",
    "delivery_package_id",
    "runtime_root",
    "artifact_root",
    "run_root",
    "report_original_path",
    "report_normalized_path",
    "report_sha256",
    "manifest_path",
    "manifest_sha256",
)


def require_exact_keys(payload: dict[str, Any], expected: frozenset[str], code: str) -> None:
    observed = frozenset(payload)
    if observed != expected:
        missing = ",".join(sorted(expected - observed)) or "none"
        extra = ",".join(sorted(observed - expected)) or "none"
        raise EvidenceError(code, f"missing={missing};extra={extra}")


def atomic_copy(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_symlink():
        raise EvidenceError("NORMALIZED_REPORT_SYMLINK")
    temp = target.with_name(f".{target.name}.tmp-{os.getpid()}")
    try:
        shutil.copyfile(source, temp)
        os.replace(temp, target)
    finally:
        try:
            temp.unlink()
        except FileNotFoundError:
            pass


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise EvidenceError("BINDING_OUTPUT_SYMLINK")
    temp = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    temp.write_text(
        json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    os.replace(temp, path)


def bind_pilot(args: argparse.Namespace) -> None:
    expected_runtime = Path(args.expected_runtime_root)
    expected_artifact = Path(args.expected_artifact_root)
    marker = Path(args.not_before_file)
    if not marker.is_file() or marker.is_symlink():
        raise EvidenceError("PILOT_START_MARKER_INVALID")
    if not SHA40.fullmatch(args.expected_source_sha):
        raise EvidenceError("EXPECTED_SOURCE_SHA_INVALID")

    cli = parse_single_cli_object(Path(args.cli_log))
    validate_report_identity(cli, expected_mode=args.expected_mode, expected_source_sha=args.expected_source_sha)
    runtime_root = exact_root(cli["runtime_root"], expected_runtime, "REPORT_RUNTIME_ROOT_MISMATCH")
    artifact_root = exact_root(cli["artifact_root"], expected_artifact, "REPORT_ARTIFACT_ROOT_MISMATCH")
    run_root = confined_directory(runtime_root, cli["run_root"], "REPORT_RUN_ROOT_ESCAPE")
    expected_run_root = runtime_root / "pilot-runs" / cli["run_id"]
    if run_root != expected_run_root:
        raise EvidenceError("REPORT_RUN_ROOT_BINDING_MISMATCH")

    report_path = confined_regular_file(runtime_root, cli["report_path"], "REPORT_PATH_CONFINEMENT_FAILED")
    if report_path != run_root / "pilot_report.json":
        raise EvidenceError("REPORT_PATH_BINDING_MISMATCH")
    require_fresh(report_path, marker, "STALE_REPORT_REJECTED")
    report = read_object(report_path, "REPORT_JSON_INVALID")
    if report != cli:
        raise EvidenceError("CLI_REPORT_SEMANTIC_MISMATCH")

    core_db = confined_regular_file(runtime_root, cli["core_db_path"], "CORE_DB_PATH_CONFINEMENT_FAILED")
    if core_db.parent != run_root:
        raise EvidenceError("CORE_DB_RUN_BINDING_MISMATCH")
    delivery_root = confined_directory(artifact_root, cli["delivery_root"], "DELIVERY_ROOT_CONFINEMENT_FAILED")
    manifest_path = confined_regular_file(artifact_root, cli["manifest_path"], "MANIFEST_PATH_CONFINEMENT_FAILED")
    if manifest_path.parent != delivery_root or manifest_path.name != "manifest.json":
        raise EvidenceError("MANIFEST_DELIVERY_BINDING_MISMATCH")
    context_path = confined_regular_file(artifact_root, cli["run_context_path"], "RUN_CONTEXT_PATH_CONFINEMENT_FAILED")
    if context_path.parent != delivery_root:
        raise EvidenceError("RUN_CONTEXT_DELIVERY_BINDING_MISMATCH")
    zip_path = confined_regular_file(artifact_root, cli["delivery_zip_path"], "DELIVERY_ZIP_PATH_CONFINEMENT_FAILED")
    qc_path = confined_regular_file(artifact_root, cli["qc_report_path"], "QC_REPORT_PATH_CONFINEMENT_FAILED")
    if zip_path.parent != delivery_root or qc_path.parent != delivery_root:
        raise EvidenceError("DELIVERY_ARTIFACT_ROOT_BINDING_MISMATCH")
    for path, code in (
        (manifest_path, "STALE_MANIFEST_REJECTED"),
        (context_path, "STALE_RUN_CONTEXT_REJECTED"),
        (zip_path, "STALE_DELIVERY_ZIP_REJECTED"),
        (qc_path, "STALE_QC_REPORT_REJECTED"),
    ):
        require_fresh(path, marker, code)

    manifest_sha = require_sha(manifest_path, cli["manifest_sha256"], "MANIFEST_SHA256_MISMATCH")
    qc_sha = require_sha(qc_path, cli["qc_report_sha256"], "QC_REPORT_SHA256_MISMATCH")
    zip_sha = require_sha(zip_path, cli["delivery_zip_sha256"], "DELIVERY_ZIP_SHA256_MISMATCH")
    validate_manifest(report, manifest_path)
    validate_context(report, context_path)

    normalized_report = Path(args.normalized_report)
    if normalized_report != runtime_root.parent / "pilot-report.json":
        raise EvidenceError("NORMALIZED_REPORT_PATH_BINDING_MISMATCH")
    if normalized_report.resolve(strict=False) == report_path.resolve(strict=True):
        raise EvidenceError("NORMALIZED_REPORT_REUSES_ORIGINAL")
    atomic_copy(report_path, normalized_report)
    normalized_payload = read_object(normalized_report, "NORMALIZED_REPORT_JSON_INVALID")
    if normalized_payload != report:
        raise EvidenceError("NORMALIZED_REPORT_SEMANTIC_MISMATCH")
    report_sha = sha256_file(report_path)
    if sha256_file(normalized_report) != report_sha:
        raise EvidenceError("NORMALIZED_REPORT_SHA256_MISMATCH")

    binding = {
        "schema_version": BINDING_SCHEMA,
        "pilot_id": cli["pilot_id"],
        "profile": cli["profile"],
        "status": cli["status"],
        "mode": cli["mode"],
        "source_head": cli["source_head"],
        "run_id": cli["run_id"],
        "delivery_package_id": cli["delivery_package_id"],
        "runtime_root": str(runtime_root),
        "artifact_root": str(artifact_root),
        "run_root": str(run_root),
        "report_original_path": str(report_path),
        "report_normalized_path": str(normalized_report),
        "report_sha256": report_sha,
        "manifest_path": str(manifest_path),
        "manifest_sha256": manifest_sha,
        "run_context_path": str(context_path),
        "run_context_sha256": sha256_file(context_path),
        "delivery_zip_path": str(zip_path),
        "delivery_zip_sha256": zip_sha,
        "qc_report_path": str(qc_path),
        "qc_report_sha256": qc_sha,
    }
    binding["binding_sha256"] = self_hash(binding, "binding_sha256")
    require_exact_keys(binding, PER_RUN_BINDING_KEYS, "BINDING_CLOSED_SCHEMA_MISMATCH")
    write_json(Path(args.binding_output), binding)
    print("PILOT_REPORT_BINDING=PASS")
    print(f"PILOT_RUN_ID={binding['run_id']}")
    print(f"PILOT_REPORT_ORIGINAL_PATH={binding['report_original_path']}")
    print(f"PILOT_REPORT_NORMALIZED_PATH={binding['report_normalized_path']}")
    print(f"PILOT_REPORT_SHA256={binding['report_sha256']}")
    print(f"PILOT_MANIFEST_PATH={binding['manifest_path']}")
    print(f"PILOT_MANIFEST_SHA256={binding['manifest_sha256']}")


def load_binding(path: Path) -> dict[str, Any]:
    binding = read_object(path, "BINDING_JSON_INVALID")
    require_exact_keys(binding, PER_RUN_BINDING_KEYS, "BINDING_CLOSED_SCHEMA_MISMATCH")
    require_equal(binding, "schema_version", BINDING_SCHEMA, "BINDING_SCHEMA_MISMATCH")
    observed = binding.get("binding_sha256")
    if not isinstance(observed, str) or observed != self_hash(binding, "binding_sha256"):
        raise EvidenceError("BINDING_SELF_HASH_MISMATCH")
    return binding


def validate_binding(
    binding: dict[str, Any],
    *,
    expected_report: Path | None = None,
    expected_runtime_root: Path | None = None,
    expected_artifact_root: Path | None = None,
) -> None:
    require_exact_keys(binding, PER_RUN_BINDING_KEYS, "BINDING_CLOSED_SCHEMA_MISMATCH")
    require_equal(binding, "schema_version", BINDING_SCHEMA, "BINDING_SCHEMA_MISMATCH")
    observed_self_hash = binding.get("binding_sha256")
    if not isinstance(observed_self_hash, str) or observed_self_hash != self_hash(binding, "binding_sha256"):
        raise EvidenceError("BINDING_SELF_HASH_MISMATCH")
    runtime_root = Path(require_string(binding, "runtime_root", "BINDING_RUNTIME_ROOT_MISSING"))
    artifact_root = Path(require_string(binding, "artifact_root", "BINDING_ARTIFACT_ROOT_MISSING"))
    if expected_runtime_root is not None:
        runtime_root = exact_root(runtime_root, expected_runtime_root, "BINDING_RUNTIME_ROOT_MISMATCH")
    elif runtime_root.is_symlink() or not runtime_root.is_dir():
        raise EvidenceError("BINDING_RUNTIME_ROOT_INVALID")
    else:
        runtime_root = runtime_root.resolve(strict=True)
    if expected_artifact_root is not None:
        artifact_root = exact_root(artifact_root, expected_artifact_root, "BINDING_ARTIFACT_ROOT_MISMATCH")
    elif artifact_root.is_symlink() or not artifact_root.is_dir():
        raise EvidenceError("BINDING_ARTIFACT_ROOT_INVALID")
    else:
        artifact_root = artifact_root.resolve(strict=True)

    run_id = require_string(binding, "run_id", "BINDING_RUN_ID_MISSING")
    run_root = confined_directory(
        runtime_root,
        require_string(binding, "run_root", "BINDING_RUN_ROOT_MISSING"),
        "BINDING_RUN_ROOT_CONFINEMENT_FAILED",
    )
    if run_root != runtime_root / "pilot-runs" / run_id:
        raise EvidenceError("BINDING_RUN_ROOT_SEMANTIC_MISMATCH")

    report_original = confined_regular_file(
        runtime_root,
        require_string(binding, "report_original_path", "BINDING_REPORT_ORIGINAL_MISSING"),
        "BINDING_ORIGINAL_REPORT_CONFINEMENT_FAILED",
    )
    if report_original != run_root / "pilot_report.json":
        raise EvidenceError("BINDING_ORIGINAL_REPORT_PATH_MISMATCH")
    report_normalized = Path(require_string(binding, "report_normalized_path", "BINDING_REPORT_NORMALIZED_MISSING"))
    canonical_normalized = runtime_root.parent / "pilot-report.json"
    if report_normalized != canonical_normalized:
        raise EvidenceError("BINDING_NORMALIZED_REPORT_PATH_MISMATCH")
    if expected_report is not None and report_normalized != expected_report:
        raise EvidenceError("BINDING_NORMALIZED_REPORT_PATH_MISMATCH")
    if report_normalized.is_symlink() or not report_normalized.is_file():
        raise EvidenceError("BINDING_NORMALIZED_REPORT_SHA_MISMATCH")

    original_payload = read_object(report_original, "BINDING_ORIGINAL_REPORT_JSON_INVALID")
    normalized_payload = read_object(report_normalized, "BINDING_NORMALIZED_REPORT_JSON_INVALID")
    if original_payload != normalized_payload:
        raise EvidenceError("BINDING_REPORT_SEMANTIC_MISMATCH")
    validate_report_identity(
        original_payload,
        expected_mode=require_string(binding, "mode", "BINDING_MODE_MISSING"),
        expected_source_sha=require_string(binding, "source_head", "BINDING_SOURCE_SHA_MISSING"),
    )

    semantic_fields = {
        "pilot_id": "pilot_id",
        "profile": "profile",
        "status": "status",
        "mode": "mode",
        "source_head": "source_head",
        "run_id": "run_id",
        "delivery_package_id": "delivery_package_id",
        "runtime_root": "runtime_root",
        "artifact_root": "artifact_root",
        "run_root": "run_root",
        "report_original_path": "report_path",
        "manifest_path": "manifest_path",
        "run_context_path": "run_context_path",
        "delivery_zip_path": "delivery_zip_path",
        "qc_report_path": "qc_report_path",
        "manifest_sha256": "manifest_sha256",
        "delivery_zip_sha256": "delivery_zip_sha256",
        "qc_report_sha256": "qc_report_sha256",
    }
    for binding_key, report_key in semantic_fields.items():
        if binding.get(binding_key) != original_payload.get(report_key):
            raise EvidenceError("BINDING_REPORT_SEMANTIC_MISMATCH", binding_key)

    core_db = confined_regular_file(
        runtime_root,
        require_string(original_payload, "core_db_path", "REPORT_CORE_DB_PATH_MISSING"),
        "BINDING_CORE_DB_CONFINEMENT_FAILED",
    )
    if core_db.parent != run_root:
        raise EvidenceError("BINDING_CORE_DB_RUN_MISMATCH")
    delivery_root = confined_directory(
        artifact_root,
        require_string(original_payload, "delivery_root", "REPORT_DELIVERY_ROOT_MISSING"),
        "BINDING_DELIVERY_ROOT_CONFINEMENT_FAILED",
    )
    manifest = confined_regular_file(
        artifact_root,
        require_string(binding, "manifest_path", "BINDING_MANIFEST_MISSING"),
        "BINDING_MANIFEST_CONFINEMENT_FAILED",
    )
    context_path = confined_regular_file(
        artifact_root,
        require_string(binding, "run_context_path", "BINDING_RUN_CONTEXT_MISSING"),
        "BINDING_RUN_CONTEXT_CONFINEMENT_FAILED",
    )
    zip_path = confined_regular_file(
        artifact_root,
        require_string(binding, "delivery_zip_path", "BINDING_DELIVERY_ZIP_MISSING"),
        "BINDING_DELIVERY_ZIP_CONFINEMENT_FAILED",
    )
    qc_path = confined_regular_file(
        artifact_root,
        require_string(binding, "qc_report_path", "BINDING_QC_REPORT_MISSING"),
        "BINDING_QC_REPORT_CONFINEMENT_FAILED",
    )
    if manifest.parent != delivery_root or manifest.name != "manifest.json":
        raise EvidenceError("BINDING_MANIFEST_DELIVERY_MISMATCH")
    if context_path.parent != delivery_root:
        raise EvidenceError("BINDING_RUN_CONTEXT_DELIVERY_MISMATCH")
    if zip_path.parent != delivery_root or qc_path.parent != delivery_root:
        raise EvidenceError("BINDING_DELIVERY_ARTIFACT_ROOT_MISMATCH")

    for key in (
        "report_sha256",
        "manifest_sha256",
        "run_context_sha256",
        "delivery_zip_sha256",
        "qc_report_sha256",
        "binding_sha256",
    ):
        value = require_string(binding, key, f"BINDING_{key.upper()}_MISSING")
        if not SHA64.fullmatch(value):
            raise EvidenceError(f"BINDING_{key.upper()}_INVALID")
    for path, key, code in (
        (report_original, "report_sha256", "BINDING_ORIGINAL_REPORT_SHA_MISMATCH"),
        (report_normalized, "report_sha256", "BINDING_NORMALIZED_REPORT_SHA_MISMATCH"),
        (manifest, "manifest_sha256", "BINDING_MANIFEST_SHA_MISMATCH"),
        (context_path, "run_context_sha256", "BINDING_RUN_CONTEXT_SHA_MISMATCH"),
        (zip_path, "delivery_zip_sha256", "BINDING_DELIVERY_ZIP_SHA_MISMATCH"),
        (qc_path, "qc_report_sha256", "BINDING_QC_REPORT_SHA_MISMATCH"),
    ):
        if sha256_file(path) != binding[key]:
            raise EvidenceError(code)

    validate_manifest(original_payload, manifest)
    validate_context(original_payload, context_path)


def command_validate_binding(args: argparse.Namespace) -> None:
    binding = load_binding(Path(args.binding))
    validate_binding(
        binding,
        expected_report=Path(args.expected_report) if args.expected_report else None,
        expected_runtime_root=Path(args.expected_runtime_root) if args.expected_runtime_root else None,
        expected_artifact_root=Path(args.expected_artifact_root) if args.expected_artifact_root else None,
    )
    print(json.dumps(binding, sort_keys=True, separators=(",", ":"), ensure_ascii=False))


def validate_two_run_payload(
    two_run: dict[str, Any],
    binding_a: dict[str, Any],
    binding_b: dict[str, Any],
) -> None:
    require_exact_keys(two_run, TWO_RUN_BINDING_KEYS, "TWO_RUN_BINDING_CLOSED_SCHEMA_MISMATCH")
    require_equal(two_run, "schema_version", TWO_RUN_SCHEMA, "TWO_RUN_BINDING_SCHEMA_MISMATCH")
    observed = two_run.get("binding_sha256")
    if not isinstance(observed, str) or observed != self_hash(two_run, "binding_sha256"):
        raise EvidenceError("TWO_RUN_BINDING_SELF_HASH_MISMATCH")
    for key in ("run_a", "run_b"):
        value = two_run.get(key)
        if not isinstance(value, dict):
            raise EvidenceError("TWO_RUN_BINDING_RUN_ENTRY_INVALID", key)
        require_exact_keys(value, PER_RUN_BINDING_KEYS, "TWO_RUN_BINDING_RUN_CLOSED_SCHEMA_MISMATCH")
    if two_run["run_a"] != binding_a or two_run["run_b"] != binding_b:
        raise EvidenceError("TWO_RUN_BINDING_SEMANTIC_MISMATCH")
    if two_run.get("source_head") != binding_a.get("source_head") or two_run.get("source_head") != binding_b.get("source_head"):
        raise EvidenceError("TWO_RUN_SOURCE_SHA_MISMATCH")
    if two_run.get("mode") != binding_a.get("mode") or two_run.get("mode") != binding_b.get("mode"):
        raise EvidenceError("TWO_RUN_MODE_MISMATCH")


def validate_two_run(args: argparse.Namespace) -> None:
    binding_a = load_binding(Path(args.binding_a))
    binding_b = load_binding(Path(args.binding_b))
    validate_binding(
        binding_a,
        expected_report=Path(args.expected_report_a),
        expected_runtime_root=Path(args.expected_runtime_root_a),
        expected_artifact_root=Path(args.expected_artifact_root_a),
    )
    validate_binding(
        binding_b,
        expected_report=Path(args.expected_report_b),
        expected_runtime_root=Path(args.expected_runtime_root_b),
        expected_artifact_root=Path(args.expected_artifact_root_b),
    )
    duplicates = [field for field in DISTINCT_RUN_FIELDS if binding_a.get(field) == binding_b.get(field)]
    if duplicates:
        raise EvidenceError("TWO_RUN_BINDING_NOT_DISTINCT", ",".join(duplicates))
    if binding_a.get("source_head") != binding_b.get("source_head"):
        raise EvidenceError("TWO_RUN_SOURCE_SHA_MISMATCH")
    if binding_a.get("mode") != binding_b.get("mode"):
        raise EvidenceError("TWO_RUN_MODE_MISMATCH")
    payload = {
        "schema_version": TWO_RUN_SCHEMA,
        "source_head": binding_a["source_head"],
        "mode": binding_a["mode"],
        "run_a": binding_a,
        "run_b": binding_b,
    }
    payload["binding_sha256"] = self_hash(payload, "binding_sha256")
    validate_two_run_payload(payload, binding_a, binding_b)
    write_json(Path(args.output), payload)
    print("DISTINCT_TWO_RUN_BINDING=PASS")
    print(f"RUN_A_REPORT={binding_a['report_normalized_path']}")
    print(f"RUN_B_REPORT={binding_b['report_normalized_path']}")
    print(f"RUN_A_MANIFEST={binding_a['manifest_path']}")
    print(f"RUN_B_MANIFEST={binding_b['manifest_path']}")


def augment_runtime_seed(args: argparse.Namespace) -> None:
    seed_path = Path(args.seed)
    seed = read_object(seed_path, "RUNTIME_SEED_JSON_INVALID")
    binding_a = load_binding(Path(args.binding_a))
    binding_b = load_binding(Path(args.binding_b))
    validate_binding(
        binding_a,
        expected_report=Path(args.expected_report_a) if getattr(args, "expected_report_a", None) else None,
        expected_runtime_root=Path(args.expected_runtime_root_a) if getattr(args, "expected_runtime_root_a", None) else None,
        expected_artifact_root=Path(args.expected_artifact_root_a) if getattr(args, "expected_artifact_root_a", None) else None,
    )
    validate_binding(
        binding_b,
        expected_report=Path(args.expected_report_b) if getattr(args, "expected_report_b", None) else None,
        expected_runtime_root=Path(args.expected_runtime_root_b) if getattr(args, "expected_runtime_root_b", None) else None,
        expected_artifact_root=Path(args.expected_artifact_root_b) if getattr(args, "expected_artifact_root_b", None) else None,
    )
    two_run = read_object(Path(args.two_run_binding), "TWO_RUN_BINDING_JSON_INVALID")
    validate_two_run_payload(two_run, binding_a, binding_b)
    seed.setdefault("run_a", {})["report_binding"] = binding_a
    seed.setdefault("run_b", {})["report_binding"] = binding_b
    seed.setdefault("aggregate", {})["two_run_binding"] = two_run
    seed.pop("runtime_seed_sha256", None)
    seed["runtime_seed_sha256"] = self_hash(seed, "runtime_seed_sha256")
    write_json(seed_path, seed)
    print("RUNTIME_SEED_REPORT_BINDINGS=PASS")


def add_full_validation_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--expected-report-a", required=True)
    parser.add_argument("--expected-report-b", required=True)
    parser.add_argument("--expected-runtime-root-a", required=True)
    parser.add_argument("--expected-artifact-root-a", required=True)
    parser.add_argument("--expected-runtime-root-b", required=True)
    parser.add_argument("--expected-artifact-root-b", required=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    bind = sub.add_parser("bind-pilot")
    bind.add_argument("--cli-log", required=True)
    bind.add_argument("--expected-runtime-root", required=True)
    bind.add_argument("--expected-artifact-root", required=True)
    bind.add_argument("--expected-source-sha", required=True)
    bind.add_argument("--expected-mode", required=True, choices=("deterministic", "provider"))
    bind.add_argument("--not-before-file", required=True)
    bind.add_argument("--normalized-report", required=True)
    bind.add_argument("--binding-output", required=True)
    bind.set_defaults(func=bind_pilot)

    validate = sub.add_parser("validate-binding")
    validate.add_argument("--binding", required=True)
    validate.add_argument("--expected-report")
    validate.add_argument("--expected-runtime-root")
    validate.add_argument("--expected-artifact-root")
    validate.set_defaults(func=command_validate_binding)

    two = sub.add_parser("validate-two-run")
    two.add_argument("--binding-a", required=True)
    two.add_argument("--binding-b", required=True)
    add_full_validation_args(two)
    two.add_argument("--output", required=True)
    two.set_defaults(func=validate_two_run)

    augment = sub.add_parser("augment-runtime-seed")
    augment.add_argument("--seed", required=True)
    augment.add_argument("--binding-a", required=True)
    augment.add_argument("--binding-b", required=True)
    augment.add_argument("--two-run-binding", required=True)
    add_full_validation_args(augment)
    augment.set_defaults(func=augment_runtime_seed)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        args.func(args)
    except EvidenceError as error:
        print(f"REPORT_ERROR={error.code}")
        if error.detail:
            print(f"REPORT_ERROR_DETAIL={error.detail}")
        print("NO_FAKE_GREEN=true")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
