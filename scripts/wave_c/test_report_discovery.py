#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
import json
import os
import tempfile
import time
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = ROOT / "scripts" / "wave_c" / "report_discovery.py"
spec = importlib.util.spec_from_file_location("report_discovery", HELPER_PATH)
helper = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(helper)
SOURCE_SHA = "b" * 40
SOURCE_DIGEST = "a" * 64


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


class Fixture:
    def __init__(self, root: Path, label: str = "a") -> None:
        self.root = root
        self.outer = root / f"run-{label}"
        self.runtime = self.outer / "runtime"
        self.artifact = self.outer / "artifacts"
        self.runtime.mkdir(parents=True)
        self.artifact.mkdir(parents=True)
        self.marker = self.outer / "pilot-started.marker"
        self.marker.write_text("started\n", encoding="utf-8")
        self.run_id = str(uuid.uuid4())
        self.run_root = self.runtime / "pilot-runs" / self.run_id
        self.run_root.mkdir(parents=True)
        self.delivery_id = f"delivery-{uuid.uuid4()}"
        self.delivery = self.artifact / "orders" / f"order-{label}" / "delivery"
        self.delivery.mkdir(parents=True)
        self.manifest = self.delivery / "manifest.json"
        self.qc = self.delivery / "qc_report.json"
        self.zip = self.delivery / "delivery.zip"
        self.context = self.delivery / "factory_run_context.json"
        self.db = self.run_root / "core.json"
        self.report = self.run_root / "pilot_report.json"
        self.normalized = self.outer / "pilot-report.json"
        self.binding = self.outer / "report-binding.json"
        self.cli = self.outer / "pilot.log"
        self.db.write_text("{}\n", encoding="utf-8")
        self.qc.write_text('{"status":"passed"}\n', encoding="utf-8")
        self.zip.write_bytes(b"zip-fixture-" + label.encode())
        self.manifest_payload = {
            "schema_version": helper.MANIFEST_SCHEMA,
            "pilot_id": helper.PILOT_ID,
            "product_profile": helper.PILOT_PROFILE,
            "order_id": f"order-{label}",
            "order_brief_id": f"brief-{label}",
            "pipeline_run_id": f"pipeline-{label}",
            "story_package_id": f"story-{label}",
            "source_sha256": SOURCE_DIGEST,
            "fallback_used": True,
            "duration_seconds": 120.0,
        }
        write_json(self.manifest, self.manifest_payload)
        self.context_payload = {
            "schema_version": helper.RUN_CONTEXT_SCHEMA,
            "pilot_id": helper.PILOT_ID,
            "profile": helper.PILOT_PROFILE,
            "run_id": self.run_id,
            "source_head": SOURCE_SHA,
            "mode": "deterministic",
            "runtime_root": str(self.runtime),
            "artifact_root": str(self.artifact),
            "run_root": str(self.run_root),
            "core_db_path": str(self.db),
            "order_id": f"order-{label}",
            "order_brief_id": f"brief-{label}",
            "pipeline_run_id": f"pipeline-{label}",
            "story_package_id": f"story-{label}",
            "delivery_package_id": self.delivery_id,
        }
        write_json(self.context, self.context_payload)
        self.payload = {
            "schema_version": helper.PILOT_SCHEMA,
            "pilot_id": helper.PILOT_ID,
            "profile": helper.PILOT_PROFILE,
            "product_profile": helper.PILOT_PROFILE,
            "status": "passed",
            "mode": "deterministic",
            "run_id": self.run_id,
            "source_head": SOURCE_SHA,
            "started_at": "2026-07-30T00:00:00.000000Z",
            "finished_at": "2026-07-30T00:02:00.000000Z",
            "runtime_root": str(self.runtime),
            "artifact_root": str(self.artifact),
            "run_root": str(self.run_root),
            "core_db_path": str(self.db),
            "order_id": f"order-{label}",
            "order_brief_id": f"brief-{label}",
            "pipeline_run_id": f"pipeline-{label}",
            "story_package_id": f"story-{label}",
            "delivery_package_id": self.delivery_id,
            "shot_count": 12,
            "target_shot_count": 12,
            "target_duration_seconds": 120.0,
            "final_duration_seconds": 120.0,
            "pipeline_state": "delivered",
            "manifest_path": str(self.manifest),
            "delivery_zip_path": str(self.zip),
            "qc_report_path": str(self.qc),
            "delivery_root": str(self.delivery),
            "run_context_path": str(self.context),
            "report_path": str(self.report),
            "fallback_used": True,
            "real_provider_observed": False,
            "real_provider_route_count": 0,
            "provider_request_ids": [],
            "checks": {},
            "source_sha256": SOURCE_DIGEST,
            "manifest_sha256": helper.sha256_file(self.manifest),
            "qc_report_sha256": helper.sha256_file(self.qc),
            "delivery_zip_sha256": helper.sha256_file(self.zip),
        }
        self.sync()

    def sync(self) -> None:
        write_json(self.report, self.payload)
        self.cli.write_text(json.dumps(self.payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def bind_args(self):
        return type("Args", (), {
            "cli_log": str(self.cli),
            "expected_runtime_root": str(self.runtime),
            "expected_artifact_root": str(self.artifact),
            "expected_source_sha": SOURCE_SHA,
            "expected_mode": "deterministic",
            "not_before_file": str(self.marker),
            "normalized_report": str(self.normalized),
            "binding_output": str(self.binding),
        })()

    def bind(self) -> dict:
        helper.bind_pilot(self.bind_args())
        return json.loads(self.binding.read_text(encoding="utf-8"))


class ReportDiscoveryTest(unittest.TestCase):
    def assert_code(self, fixture: Fixture, code: str) -> None:
        with self.assertRaises(helper.EvidenceError) as caught:
            helper.bind_pilot(fixture.bind_args())
        self.assertEqual(code, caught.exception.code)

    def test_contract_declares_exact_report_interface(self) -> None:
        contract = json.loads((ROOT / "contracts" / "GFF_WAVE_C_G1_V03_VALIDATION_v01.json").read_text(encoding="utf-8"))
        interface = contract["pilot_report_evidence_interface"]
        self.assertEqual("factory_120s_pilot_report_v02", interface["pilot_report_schema"])
        self.assertEqual("passed", interface["required_status"])
        self.assertEqual("deterministic", interface["required_mode"])
        self.assertTrue(interface["cli_report_semantic_equality"])
        self.assertTrue(interface["normalize_only_after_validation"])
        self.assertTrue(interface["reject_path_escape_or_symlink_components"])
        self.assertTrue(interface["aggregate_requires_exactly_two_distinct_validated_bindings"])
        self.assertEqual([], contract["workflow_inputs"])
        self.assertFalse(contract["public_artifact_upload"])
        self.assertFalse(contract["cache"])
        self.assertFalse(contract["network_media_provider_calls"])
        self.assertFalse(contract["paid_provider_calls"])

    def test_happy_path_binds_original_normalized_and_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(Path(directory))
            binding = fixture.bind()
            self.assertEqual(fixture.run_id, binding["run_id"])
            self.assertEqual(str(fixture.report), binding["report_original_path"])
            self.assertEqual(str(fixture.normalized), binding["report_normalized_path"])
            self.assertEqual(helper.sha256_file(fixture.report), binding["report_sha256"])
            self.assertEqual(helper.sha256_file(fixture.manifest), binding["manifest_sha256"])
            helper.validate_binding(binding, expected_report=fixture.normalized)

    def test_cli_json_missing_malformed_and_ambiguous_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cases = (("", "CLI_JSON_MISSING"), ("{", "CLI_JSON_MALFORMED"), ("{}\n{}", "CLI_JSON_AMBIGUOUS"))
            for index, (raw, code) in enumerate(cases):
                fixture = Fixture(root / str(index))
                fixture.cli.write_text(raw, encoding="utf-8")
                with self.subTest(code=code):
                    self.assert_code(fixture, code)

    def test_exact_schema_status_mode_source_and_roots_are_enforced(self) -> None:
        mutations = (
            ("schema_version", "wrong", "REPORT_SCHEMA_MISMATCH"),
            ("status", "failed", "REPORT_STATUS_NOT_PASSED"),
            ("mode", "provider", "REPORT_MODE_MISMATCH"),
            ("source_head", "c" * 40, "REPORT_SOURCE_SHA_MISMATCH"),
            ("runtime_root", "/tmp/elsewhere", "REPORT_RUNTIME_ROOT_MISMATCH"),
            ("artifact_root", "/tmp/elsewhere", "REPORT_ARTIFACT_ROOT_MISMATCH"),
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for index, (field, value, code) in enumerate(mutations):
                fixture = Fixture(root / str(index))
                fixture.payload[field] = value
                fixture.sync()
                with self.subTest(field=field):
                    self.assert_code(fixture, code)

    def test_report_escape_symlink_stale_and_semantic_mismatch_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            escape = Fixture(root / "escape")
            outside = root / "outside-report.json"
            write_json(outside, escape.payload)
            escape.payload["report_path"] = str(outside)
            escape.cli.write_text(json.dumps(escape.payload), encoding="utf-8")
            self.assert_code(escape, "REPORT_PATH_CONFINEMENT_FAILED")

            symlink = Fixture(root / "symlink")
            real = symlink.report.with_name("real-report.json")
            symlink.report.rename(real)
            symlink.report.symlink_to(real)
            self.assert_code(symlink, "REPORT_PATH_CONFINEMENT_FAILED")

            stale = Fixture(root / "stale")
            future = time.time_ns() + 5_000_000_000
            os.utime(stale.marker, ns=(future, future))
            self.assert_code(stale, "STALE_REPORT_REJECTED")

            mismatch = Fixture(root / "mismatch")
            disk = copy.deepcopy(mismatch.payload)
            disk["delivery_package_id"] = "different"
            write_json(mismatch.report, disk)
            self.assert_code(mismatch, "CLI_REPORT_SEMANTIC_MISMATCH")

    def test_manifest_escape_symlink_hash_and_semantic_mismatch_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            escape = Fixture(root / "escape")
            outside = root / "outside-manifest.json"
            write_json(outside, escape.manifest_payload)
            escape.payload["manifest_path"] = str(outside)
            escape.payload["manifest_sha256"] = helper.sha256_file(outside)
            escape.sync()
            self.assert_code(escape, "MANIFEST_PATH_CONFINEMENT_FAILED")

            symlink = Fixture(root / "symlink")
            real = symlink.manifest.with_name("real-manifest.json")
            symlink.manifest.rename(real)
            symlink.manifest.symlink_to(real)
            self.assert_code(symlink, "MANIFEST_PATH_CONFINEMENT_FAILED")

            digest = Fixture(root / "digest")
            digest.payload["manifest_sha256"] = "f" * 64
            digest.sync()
            self.assert_code(digest, "MANIFEST_SHA256_MISMATCH")

            semantic = Fixture(root / "semantic")
            semantic.manifest_payload["pipeline_run_id"] = "wrong"
            write_json(semantic.manifest, semantic.manifest_payload)
            semantic.payload["manifest_sha256"] = helper.sha256_file(semantic.manifest)
            semantic.sync()
            self.assert_code(semantic, "MANIFEST_SEMANTIC_MISMATCH")

    def test_delivery_and_run_context_binding_is_exact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(Path(directory))
            fixture.context_payload["delivery_package_id"] = "wrong"
            write_json(fixture.context, fixture.context_payload)
            fixture.sync()
            self.assert_code(fixture, "RUN_CONTEXT_SEMANTIC_MISMATCH")

    def test_runtime_seed_augmentation_records_exact_bindings(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            a = Fixture(root, "a")
            b = Fixture(root, "b")
            binding_a = a.bind(); binding_b = b.bind()
            two_path = root / "two-run.json"
            helper.validate_two_run(type("Args", (), {
                "binding_a": str(a.binding), "binding_b": str(b.binding),
                "expected_report_a": str(a.normalized), "expected_report_b": str(b.normalized),
                "expected_runtime_root_a": str(a.runtime), "expected_artifact_root_a": str(a.artifact),
                "expected_runtime_root_b": str(b.runtime), "expected_artifact_root_b": str(b.artifact),
                "output": str(two_path),
            })())
            seed_path = root / "seed.json"
            write_json(seed_path, {"schema_version": "factory_actions_evidence_runtime_seed_v01", "run_a": {}, "run_b": {}, "aggregate": {}})
            helper.augment_runtime_seed(type("Args", (), {
                "seed": str(seed_path), "binding_a": str(a.binding), "binding_b": str(b.binding),
                "two_run_binding": str(two_path),
            })())
            seed = json.loads(seed_path.read_text(encoding="utf-8"))
            self.assertEqual(binding_a, seed["run_a"]["report_binding"])
            self.assertEqual(binding_b, seed["run_b"]["report_binding"])
            self.assertEqual(helper.self_hash(seed, "runtime_seed_sha256"), seed["runtime_seed_sha256"])

    def test_two_distinct_runs_pass_and_duplicate_reuse_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            a = Fixture(root, "a")
            b = Fixture(root, "b")
            a.bind(); b.bind()
            args = type("Args", (), {
                "binding_a": str(a.binding), "binding_b": str(b.binding),
                "expected_report_a": str(a.normalized), "expected_report_b": str(b.normalized),
                "expected_runtime_root_a": str(a.runtime), "expected_artifact_root_a": str(a.artifact),
                "expected_runtime_root_b": str(b.runtime), "expected_artifact_root_b": str(b.artifact),
                "output": str(root / "two-run.json"),
            })()
            helper.validate_two_run(args)
            payload = json.loads((root / "two-run.json").read_text(encoding="utf-8"))
            self.assertEqual(helper.TWO_RUN_SCHEMA, payload["schema_version"])

            duplicate = type("Args", (), {
                "binding_a": str(a.binding), "binding_b": str(a.binding),
                "expected_report_a": str(a.normalized), "expected_report_b": str(a.normalized),
                "expected_runtime_root_a": str(a.runtime), "expected_artifact_root_a": str(a.artifact),
                "expected_runtime_root_b": str(a.runtime), "expected_artifact_root_b": str(a.artifact),
                "output": str(root / "duplicate.json"),
            })()
            with self.assertRaises(helper.EvidenceError) as caught:
                helper.validate_two_run(duplicate)
            self.assertEqual("TWO_RUN_BINDING_NOT_DISTINCT", caught.exception.code)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ReportDiscoveryTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.wasSuccessful():
        print("REPORT_DISCOVERY_PARSER=PASS")
        print("REPORT_PATH_CONFINEMENT=PASS")
        print("CLI_REPORT_SEMANTIC_BINDING=PASS")
        print("MANIFEST_PATH_CONFINEMENT=PASS")
        print("DISTINCT_TWO_RUN_BINDING=PASS")
        print("NEW_NEGATIVE_MUTATIONS=PASS")
        print("NO_FAKE_GREEN=true")
    raise SystemExit(0 if result.wasSuccessful() else 1)
