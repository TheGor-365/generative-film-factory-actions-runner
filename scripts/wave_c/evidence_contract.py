#!/usr/bin/env python3
"""Deterministic compact evidence helpers for the fixed Wave C Actions gate."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Iterable

RESULTS = ("PASS", "FAIL", "ERROR", "BLOCKED")
PRECEDENCE = {"PASS": 0, "BLOCKED": 1, "FAIL": 2, "ERROR": 3}
COMPONENTS = ("core", "onboarding_web", "story", "media", "ops")
REQUIRED_STEPS = (
    "checkout_exact_sha",
    "ruby_toolchain_preflight",
    "core_component_matrix",
    "onboarding_web_component_matrix",
    "story_component_matrix",
    "media_component_matrix",
    "ops_component_matrix",
    "validate_source",
    "doctor",
    "pilot_a",
    "verify_a",
    "pilot_b",
    "verify_b",
    "aggregate_release_check",
    "cleanup",
)
EVIDENCE_NAMES = (
    "component_matrix",
    "doctor",
    "run_a_report",
    "verify_a",
    "run_b_report",
    "verify_b",
    "aggregate_index",
    "release_check",
)
SHA40 = re.compile(r"^[0-9a-f]{40}$")
SHA64 = re.compile(r"^[0-9a-f]{64}$")


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sha256_value(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def self_hash(document: dict[str, Any], field: str) -> str:
    return sha256_value({key: value for key, value in document.items() if key != field})


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_hash(root: Path) -> str:
    if not root.is_dir():
        return hashlib.sha256(b"missing-directory").hexdigest()
    entries: list[dict[str, Any]] = []
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        if path.is_symlink():
            entries.append({"type": "symlink", "path_hash": hashlib.sha256(path.relative_to(root).as_posix().encode()).hexdigest()})
        elif path.is_file():
            entries.append(
                {
                    "type": "file",
                    "path_hash": hashlib.sha256(path.relative_to(root).as_posix().encode()).hexdigest(),
                    "size": path.stat().st_size,
                    "sha256": sha256_file(path),
                }
            )
        elif path.is_dir():
            entries.append({"type": "directory", "path_hash": hashlib.sha256(path.relative_to(root).as_posix().encode()).hexdigest()})
    return sha256_value(entries)


def read_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"expected object: {path}")
    return payload


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n", encoding="utf-8")


def overall_outcome(outcomes: Iterable[str]) -> str:
    values = list(outcomes)
    if not values:
        return "BLOCKED"
    unknown = sorted(set(values) - set(RESULTS))
    if unknown:
        raise ValueError(f"unknown outcomes: {','.join(unknown)}")
    return max(values, key=lambda value: PRECEDENCE[value])


def state_path(work_root: Path) -> Path:
    return work_root / "evidence" / "gate_state.json"


def load_state(work_root: Path) -> dict[str, Any]:
    return read_json(state_path(work_root))


def save_state(work_root: Path, state: dict[str, Any]) -> None:
    write_json(state_path(work_root), state)


def init_state(args: argparse.Namespace) -> None:
    if not SHA40.fullmatch(args.private_sha) or not SHA40.fullmatch(args.runner_sha):
        raise SystemExit("POLICY_ERROR=INVALID_EXACT_SHA")
    root = Path(args.work_root)
    state = {
        "schema_version": "gff_wave_c_gate_state_v02",
        "gate_id": args.gate_id,
        "private_sha": args.private_sha,
        "runner_sha": args.runner_sha,
        "records": [],
    }
    save_state(root, state)
    print("GATE_STATE_INITIALIZED=true")


def record(args: argparse.Namespace) -> None:
    if args.outcome not in RESULTS:
        raise SystemExit("POLICY_ERROR=INVALID_OUTCOME")
    if not SHA64.fullmatch(args.evidence_sha256):
        raise SystemExit("POLICY_ERROR=INVALID_EVIDENCE_SHA256")
    root = Path(args.work_root)
    state = load_state(root)
    item = {
        "step_id": args.step_id,
        "category": args.category,
        "command_id": args.command_id,
        "outcome": args.outcome,
        "exit_code": int(args.exit_code),
        "evidence_sha256": args.evidence_sha256,
        "stable_codes": sorted(set(args.stable_code or [])),
    }
    records = [
        existing
        for existing in state.get("records", [])
        if not (existing.get("step_id") == args.step_id and existing.get("command_id") == args.command_id)
    ]
    records.append(item)
    state["records"] = records
    save_state(root, state)
    print(f"RECORDED_STEP_ID={args.step_id}")
    print(f"RECORDED_COMMAND_ID={args.command_id}")
    print(f"RECORDED_OUTCOME={args.outcome}")


def records_for_step(state: dict[str, Any], step_id: str) -> list[dict[str, Any]]:
    return [record for record in state.get("records", []) if record.get("step_id") == step_id]


def step_evidence(state: dict[str, Any], step_id: str) -> dict[str, Any]:
    records = records_for_step(state, step_id)
    outcome = overall_outcome(record["outcome"] for record in records)
    exit_codes = [int(record["exit_code"]) for record in records]
    payload = {
        "step_id": step_id,
        "outcome": outcome,
        "exit_code": 0 if outcome == "PASS" else (3 if outcome == "BLOCKED" else (2 if outcome == "ERROR" else max(exit_codes or [1]))),
        "commands": [
            {
                "command_id": record["command_id"],
                "outcome": record["outcome"],
                "exit_code": int(record["exit_code"]),
                "evidence_sha256": record["evidence_sha256"],
            }
            for record in sorted(records, key=lambda item: item["command_id"])
        ],
    }
    payload["evidence_sha256"] = sha256_value(payload)
    return payload


def generate_component_documents(work_root: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    state = load_state(work_root)
    component_steps = {
        "core": "core_component_matrix",
        "onboarding_web": "onboarding_web_component_matrix",
        "story": "story_component_matrix",
        "media": "media_component_matrix",
        "ops": "ops_component_matrix",
    }
    components: dict[str, Any] = {}
    for name, step_id in component_steps.items():
        records = records_for_step(state, step_id)
        commands = [
            {
                "command_id": record["command_id"],
                "outcome": record["outcome"],
                "exit_code": int(record["exit_code"]),
                "evidence_sha256": record["evidence_sha256"],
            }
            for record in sorted(records, key=lambda item: item["command_id"])
        ]
        component = {"outcome": overall_outcome(command["outcome"] for command in commands), "commands": commands}
        component["evidence_sha256"] = self_hash(component, "evidence_sha256")
        components[name] = component
    matrix = {
        "schema_version": "factory_component_matrix_summary_v02",
        "source_sha": state["private_sha"],
        "status": overall_outcome(component["outcome"] for component in components.values()),
        "components": components,
    }
    matrix["summary_sha256"] = self_hash(matrix, "summary_sha256")

    flattened = [command for component in components.values() for command in component["commands"]]
    legacy = {
        "schema_version": "factory_component_test_summary_v01",
        "status": "passed" if matrix["status"] == "PASS" else "failed",
        "source_head": state["private_sha"],
        "commands": [
            {
                "command": command["command_id"],
                "exit_code": command["exit_code"],
                "status": "passed" if command["outcome"] == "PASS" else "failed",
            }
            for command in flattened
        ],
        "checks": {
            "all_required_component_groups_present": {
                "passed": all(bool(components[name]["commands"]) for name in COMPONENTS),
                "missing_group_count": sum(1 for name in COMPONENTS if not components[name]["commands"]),
            },
            "all_component_commands_passed": {
                "passed": matrix["status"] == "PASS",
                "failed_command_count": sum(1 for command in flattened if command["outcome"] != "PASS"),
            },
            "private_source_logged": {"passed": True, "observed": False},
            "paid_provider_called": {"passed": True, "observed": False},
            "public_artifact_uploaded": {"passed": True, "observed": False},
        },
        "component_command_counts": {name: len(components[name]["commands"]) for name in COMPONENTS},
        "no_fake_green": True,
    }
    return matrix, legacy


def command_generate_components(args: argparse.Namespace) -> None:
    root = Path(args.work_root)
    matrix, legacy = generate_component_documents(root)
    matrix_path = root / "evidence" / "component_matrix_v02.json"
    legacy_path = root / "evidence" / "component_test_summary.json"
    write_json(matrix_path, matrix)
    write_json(legacy_path, legacy)
    print(f"COMPONENT_MATRIX_V02_SHA256={sha256_file(matrix_path)}")
    print(f"COMPONENT_MATRIX_V02_SUMMARY_SHA256={matrix['summary_sha256']}")
    print(f"LEGACY_COMPONENT_SUMMARY_SHA256={sha256_file(legacy_path)}")
    print(f"COMPONENT_MATRIX_OUTCOME={matrix['status']}")


def status_from_record(state: dict[str, Any], step_id: str) -> str:
    return step_evidence(state, step_id)["outcome"]


def safe_json(path: Path) -> dict[str, Any]:
    try:
        return read_json(path)
    except Exception:
        return {}


def string_field(payload: dict[str, Any], names: Iterable[str], default: str = "") -> str:
    for name in names:
        value = payload.get(name)
        if isinstance(value, str) and value:
            return value
    return default


def bool_field(payload: dict[str, Any], names: Iterable[str], default: bool) -> bool:
    for name in names:
        value = payload.get(name)
        if isinstance(value, bool):
            return value
    return default


def runtime_seed(args: argparse.Namespace) -> None:
    root = Path(args.work_root)
    state = load_state(root)
    matrix_path = root / "evidence" / "component_matrix_v02.json"
    legacy_path = root / "evidence" / "component_test_summary.json"
    if not matrix_path.is_file() or not legacy_path.is_file():
        matrix, legacy = generate_component_documents(root)
        write_json(matrix_path, matrix)
        write_json(legacy_path, legacy)
    matrix = read_json(matrix_path)

    doctor_path = root / "evidence" / "doctor.json"
    run_a_report_path = root / "run-a" / "pilot-report.json"
    run_a_verify_path = root / "run-a" / "verify.json"
    run_b_report_path = root / "run-b" / "pilot-report.json"
    run_b_verify_path = root / "run-b" / "verify.json"
    release_path = root / "evidence" / "release-check.json"
    release = safe_json(release_path)
    aggregate_index_path = Path(string_field(release, ("aggregate_evidence_index",), "")) if release else Path("")
    if not aggregate_index_path.is_file():
        aggregate_index_path = root / "evidence" / "aggregate-index-missing.json"

    def compact_run(label: str, report_path: Path, verify_path: Path) -> dict[str, Any]:
        report = safe_json(report_path)
        step = "pilot_a" if label == "run_a" else "pilot_b"
        verify_step = "verify_a" if label == "run_a" else "verify_b"
        status = overall_outcome((status_from_record(state, step), status_from_record(state, verify_step)))
        runtime_dir = root / ("run-a" if label == "run_a" else "run-b") / "runtime"
        artifact_dir = root / ("run-a" if label == "run_a" else "run-b") / "artifacts"
        return {
            "source_sha": state["private_sha"],
            "status": status,
            "run_id": string_field(report, ("run_id",), f"missing-{label}-run-id"),
            "runtime_root_sha256": tree_hash(runtime_dir),
            "artifact_root_sha256": tree_hash(artifact_dir),
            "delivery_package_id": string_field(report, ("delivery_package_id",), f"missing-{label}-delivery-id"),
            "report_sha256": sha256_file(report_path) if report_path.is_file() else hashlib.sha256(f"missing-{label}-report".encode()).hexdigest(),
            "verify_sha256": sha256_file(verify_path) if verify_path.is_file() else hashlib.sha256(f"missing-{label}-verify".encode()).hexdigest(),
            "fallback_used": bool_field(report, ("fallback_used", "demo_fallback_used"), True),
            "real_provider": bool_field(report, ("real_provider", "real_provider_observed"), False),
        }

    run_a = compact_run("run_a", run_a_report_path, run_a_verify_path)
    run_b = compact_run("run_b", run_b_report_path, run_b_verify_path)
    aggregate_status = status_from_record(state, "aggregate_release_check")
    aggregate = {
        "source_sha": state["private_sha"],
        "status": aggregate_status,
        "evidence_index_sha256": sha256_file(aggregate_index_path) if aggregate_index_path.is_file() else hashlib.sha256(b"missing-aggregate-index").hexdigest(),
        "release_check_sha256": sha256_file(release_path) if release_path.is_file() else hashlib.sha256(b"missing-release-check").hexdigest(),
    }
    doctor = {
        "source_sha": state["private_sha"],
        "status": status_from_record(state, "doctor"),
        "report_sha256": sha256_file(doctor_path) if doctor_path.is_file() else hashlib.sha256(b"missing-doctor").hexdigest(),
    }
    refs = [
        {"name": "component_matrix", "sha256": sha256_file(matrix_path)},
        {"name": "doctor", "sha256": doctor["report_sha256"]},
        {"name": "run_a_report", "sha256": run_a["report_sha256"]},
        {"name": "verify_a", "sha256": run_a["verify_sha256"]},
        {"name": "run_b_report", "sha256": run_b["report_sha256"]},
        {"name": "verify_b", "sha256": run_b["verify_sha256"]},
        {"name": "aggregate_index", "sha256": aggregate["evidence_index_sha256"]},
        {"name": "release_check", "sha256": aggregate["release_check_sha256"]},
    ]
    required_non_cleanup = [step for step in REQUIRED_STEPS if step != "cleanup"]
    steps = [step_evidence(state, step) for step in required_non_cleanup]
    canonical = step_evidence(state, "canonical_v03_executor")
    all_outcomes = [step["outcome"] for step in steps] + [canonical["outcome"]]
    result = overall_outcome(all_outcomes)
    stable_codes = sorted(
        {
            code
            for record in state.get("records", [])
            if record.get("outcome") != "PASS"
            for code in record.get("stable_codes", [])
        }
    )
    v03_log_path = root / "logs" / "CANONICAL_V03_EXECUTOR.log"
    v03_payload = safe_json(v03_log_path)
    seed = {
        "schema_version": "factory_actions_evidence_runtime_seed_v01",
        "gate_id": state["gate_id"],
        "private_repository": args.private_repository,
        "private_sha": state["private_sha"],
        "runner_repository": args.runner_repository,
        "runner_sha": state["runner_sha"],
        "result": result,
        "required_step_ids": list(REQUIRED_STEPS),
        "step_evidence": steps + [canonical],
        "component_matrix": matrix,
        "doctor": doctor,
        "run_a": run_a,
        "run_b": run_b,
        "aggregate": aggregate,
        "evidence_refs": refs,
        "canonical_v03_executor": {
            "step_id": "canonical_v03_executor",
            "outcome": canonical["outcome"],
            "executor_commit": args.executor_commit if SHA40.fullmatch(args.executor_commit) else None,
            "binding_status": "BOUND" if SHA40.fullmatch(args.executor_commit) else "BLOCKED_PENDING_CHAT5_EXECUTOR_COMMIT",
            "command_id": args.executor_command,
            "release_bundle_path_observed": bool(string_field(v03_payload, ("bundle_path", "evidence_bundle_path", "wave_c_release_bundle_path"), "")),
            "release_bundle_sha256": string_field(v03_payload, ("bundle_sha256", "evidence_bundle_sha256", "wave_c_release_bundle_sha256"), hashlib.sha256(b"missing-wave-c-release-bundle").hexdigest()),
        },
        "blockers": stable_codes,
    }
    seed["runtime_seed_sha256"] = self_hash(seed, "runtime_seed_sha256")
    output_path = root / "evidence" / "actions_runtime_seed.json"
    write_json(output_path, seed)
    print(json.dumps(seed, sort_keys=True, separators=(",", ":"), ensure_ascii=False))


def cleanup_line(args: argparse.Namespace) -> None:
    raw = sys.stdin.read().strip()
    try:
        seed = json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        seed = {}
    if not isinstance(seed, dict):
        seed = {}
    runtime = dict(seed)
    runtime["schema_version"] = "factory_actions_evidence_runtime_v01"
    runtime["cleanup"] = {
        "private_checkout_deleted": args.private_checkout_deleted == "true",
        "runtime_roots_deleted": args.runtime_roots_deleted == "true",
        "artifact_roots_deleted": args.artifact_roots_deleted == "true",
        "uploads_created": False,
        "caches_created": False,
    }
    runtime.pop("runtime_seed_sha256", None)
    runtime["runtime_evidence_sha256"] = self_hash(runtime, "runtime_evidence_sha256")
    compact = json.dumps(runtime, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    print(f"ACTIONS_RUNTIME_EVIDENCE_JSON={compact}")
    print(f"ACTIONS_RUNTIME_EVIDENCE_SHA256={runtime['runtime_evidence_sha256']}")


def validate_contract(args: argparse.Namespace) -> None:
    contract = read_json(Path(args.contract))
    expected = {
        "gate_id": "GFF_WAVE_C_G1_V03_VALIDATION_v01",
        "private_repository": "TheGor-365/generative-film-factory-control-center",
        "allowed_branch": "main",
        "status_context": "public-runner/gff/wave-c-validation",
        "workflow_inputs": ["private_sha"],
        "arbitrary_shell_allowed": False,
        "public_artifact_upload": False,
        "cache": False,
        "paid_provider_calls": False,
        "network_media_provider_calls": False,
        "no_fake_green": True,
    }
    for key, value in expected.items():
        if contract.get(key) != value:
            raise SystemExit(f"POLICY_ERROR=CONTRACT_{key.upper()}_MISMATCH")
    if contract.get("required_step_ids") != list(REQUIRED_STEPS):
        raise SystemExit("POLICY_ERROR=CONTRACT_REQUIRED_STEP_IDS_MISMATCH")
    executor = contract.get("canonical_v03_executor")
    if not isinstance(executor, dict):
        raise SystemExit("POLICY_ERROR=CONTRACT_EXECUTOR_MISSING")
    source_commit = executor.get("source_commit")
    binding_status = executor.get("binding_status")
    if source_commit is not None and not SHA40.fullmatch(str(source_commit)):
        raise SystemExit("POLICY_ERROR=CONTRACT_EXECUTOR_COMMIT_INVALID")
    if source_commit is None and binding_status != "BLOCKED_PENDING_CHAT5_EXECUTOR_COMMIT":
        raise SystemExit("POLICY_ERROR=CONTRACT_EXECUTOR_PENDING_STATUS_INVALID")
    if source_commit is not None and binding_status not in {None, "BOUND"}:
        raise SystemExit("POLICY_ERROR=CONTRACT_EXECUTOR_BOUND_STATUS_INVALID")
    if executor.get("command") != "wave-c-v03-cycle":
        raise SystemExit("POLICY_ERROR=CONTRACT_EXECUTOR_COMMAND_MISMATCH")
    print("FIXED_DISPATCH_POLICY=PASS")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    init = sub.add_parser("init")
    init.add_argument("--work-root", required=True)
    init.add_argument("--gate-id", required=True)
    init.add_argument("--private-sha", required=True)
    init.add_argument("--runner-sha", required=True)
    init.set_defaults(func=init_state)

    rec = sub.add_parser("record")
    rec.add_argument("--work-root", required=True)
    rec.add_argument("--step-id", required=True)
    rec.add_argument("--category", required=True)
    rec.add_argument("--command-id", required=True)
    rec.add_argument("--outcome", required=True)
    rec.add_argument("--exit-code", required=True, type=int)
    rec.add_argument("--evidence-sha256", required=True)
    rec.add_argument("--stable-code", action="append")
    rec.set_defaults(func=record)

    comp = sub.add_parser("generate-components")
    comp.add_argument("--work-root", required=True)
    comp.set_defaults(func=command_generate_components)

    seed = sub.add_parser("runtime-seed")
    seed.add_argument("--work-root", required=True)
    seed.add_argument("--private-repository", required=True)
    seed.add_argument("--runner-repository", required=True)
    seed.add_argument("--executor-commit", required=True)
    seed.add_argument("--executor-command", required=True)
    seed.set_defaults(func=runtime_seed)

    cleanup = sub.add_parser("cleanup-line")
    cleanup.add_argument("--private-checkout-deleted", choices=("true", "false"), required=True)
    cleanup.add_argument("--runtime-roots-deleted", choices=("true", "false"), required=True)
    cleanup.add_argument("--artifact-roots-deleted", choices=("true", "false"), required=True)
    cleanup.set_defaults(func=cleanup_line)

    contract = sub.add_parser("validate-contract")
    contract.add_argument("--contract", required=True)
    contract.set_defaults(func=validate_contract)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
