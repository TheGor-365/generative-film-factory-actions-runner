#!/usr/bin/env python3
from __future__ import annotations

import copy
import json
import tempfile
import unittest
import uuid
from pathlib import Path

import report_discovery as helper

SOURCE_SHA = "b" * 40
SOURCE_DIGEST = "a" * 64


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


class Fixture:
    def __init__(self, root: Path, label: str) -> None:
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
        self.context = self.delivery / "factory_run_context.json"
        self.qc = self.delivery / "qc_report.json"
        self.zip = self.delivery / "delivery.zip"
        self.db = self.run_root / "core.json"
        self.report = self.run_root / "pilot_report.json"
        self.normalized = self.outer / "pilot-report.json"
        self.binding = self.outer / "report-binding.json"
        self.cli = self.outer / "pilot.log"
        self.db.write_text("{}\n", encoding="utf-8")
        self.qc.write_text(json.dumps({"status": "passed", "label": label}) + "\n", encoding="utf-8")
        self.zip.write_bytes(("zip-" + label).encode())
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
        write_json(self.report, self.payload)
        self.cli.write_text(json.dumps(self.payload) + "\n", encoding="utf-8")

    def bind(self) -> dict:
        helper.bind_pilot(type("Args", (), {
            "cli_log": str(self.cli),
            "expected_runtime_root": str(self.runtime),
            "expected_artifact_root": str(self.artifact),
            "expected_source_sha": SOURCE_SHA,
            "expected_mode": "deterministic",
            "not_before_file": str(self.marker),
            "normalized_report": str(self.normalized),
            "binding_output": str(self.binding),
        })())
        return json.loads(self.binding.read_text(encoding="utf-8"))

    def validation_kwargs(self) -> dict:
        return {
            "expected_report": self.normalized,
            "expected_runtime_root": self.runtime,
            "expected_artifact_root": self.artifact,
        }


def rehash_binding(payload: dict) -> dict:
    payload["binding_sha256"] = helper.self_hash(payload, "binding_sha256")
    return payload


class BindingSemanticTest(unittest.TestCase):
    def test_closed_per_run_schema_and_semantic_rewrites_reject(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            a = Fixture(root, "a")
            b = Fixture(root, "b")
            original = a.bind()
            other = b.bind()
            helper.validate_binding(original, **a.validation_kwargs())
            mutations = {
                "pilot_id": "GFF-PILOT-REWRITTEN",
                "profile": "rewritten_profile",
                "status": "failed",
                "mode": "provider",
                "source_head": "c" * 40,
                "run_id": other["run_id"],
                "delivery_package_id": other["delivery_package_id"],
                "runtime_root": other["runtime_root"],
                "artifact_root": other["artifact_root"],
                "run_root": other["run_root"],
                "report_original_path": other["report_original_path"],
                "report_normalized_path": other["report_normalized_path"],
                "report_sha256": other["report_sha256"],
                "manifest_path": other["manifest_path"],
                "manifest_sha256": other["manifest_sha256"],
                "run_context_path": other["run_context_path"],
                "run_context_sha256": other["run_context_sha256"],
                "delivery_zip_path": other["delivery_zip_path"],
                "delivery_zip_sha256": other["delivery_zip_sha256"],
                "qc_report_path": other["qc_report_path"],
                "qc_report_sha256": other["qc_report_sha256"],
            }
            for field, value in mutations.items():
                mutated = rehash_binding({**original, field: value})
                with self.subTest(field=field), self.assertRaises(helper.EvidenceError):
                    helper.validate_binding(mutated, **a.validation_kwargs())
            extra = dict(original)
            extra["extra_key"] = "forbidden"
            rehash_binding(extra)
            with self.assertRaises(helper.EvidenceError) as caught:
                helper.validate_binding(extra, **a.validation_kwargs())
            self.assertEqual("BINDING_CLOSED_SCHEMA_MISMATCH", caught.exception.code)

    def test_closed_two_run_schema_and_augment_full_revalidation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            a = Fixture(root, "a")
            b = Fixture(root, "b")
            binding_a = a.bind()
            binding_b = b.bind()
            two_path = root / "two-run.json"
            args = type("Args", (), {
                "binding_a": str(a.binding),
                "binding_b": str(b.binding),
                "expected_report_a": str(a.normalized),
                "expected_report_b": str(b.normalized),
                "expected_runtime_root_a": str(a.runtime),
                "expected_artifact_root_a": str(a.artifact),
                "expected_runtime_root_b": str(b.runtime),
                "expected_artifact_root_b": str(b.artifact),
                "output": str(two_path),
            })()
            helper.validate_two_run(args)
            two = json.loads(two_path.read_text(encoding="utf-8"))
            helper.validate_two_run_payload(two, binding_a, binding_b)

            top_extra = copy.deepcopy(two)
            top_extra["extra_key"] = True
            top_extra["binding_sha256"] = helper.self_hash(top_extra, "binding_sha256")
            with self.assertRaises(helper.EvidenceError) as caught:
                helper.validate_two_run_payload(top_extra, binding_a, binding_b)
            self.assertEqual("TWO_RUN_BINDING_CLOSED_SCHEMA_MISMATCH", caught.exception.code)

            nested_extra = copy.deepcopy(two)
            nested_extra["run_a"]["extra_key"] = True
            nested_extra["binding_sha256"] = helper.self_hash(nested_extra, "binding_sha256")
            with self.assertRaises(helper.EvidenceError) as caught:
                helper.validate_two_run_payload(nested_extra, binding_a, binding_b)
            self.assertEqual("TWO_RUN_BINDING_RUN_CLOSED_SCHEMA_MISMATCH", caught.exception.code)

            seed = root / "seed.json"
            write_json(seed, {
                "schema_version": "factory_actions_evidence_runtime_seed_v01",
                "run_a": {},
                "run_b": {},
                "aggregate": {},
            })
            augment_args = type("Args", (), {
                "seed": str(seed),
                "binding_a": str(a.binding),
                "binding_b": str(b.binding),
                "two_run_binding": str(two_path),
                "expected_report_a": str(a.normalized),
                "expected_report_b": str(b.normalized),
                "expected_runtime_root_a": str(a.runtime),
                "expected_artifact_root_a": str(a.artifact),
                "expected_runtime_root_b": str(b.runtime),
                "expected_artifact_root_b": str(b.artifact),
            })()
            helper.augment_runtime_seed(augment_args)

            rewritten = {**binding_a, "pilot_id": "GFF-PILOT-REWRITTEN"}
            rehash_binding(rewritten)
            write_json(a.binding, rewritten)
            with self.assertRaises(helper.EvidenceError):
                helper.augment_runtime_seed(augment_args)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(BindingSemanticTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.wasSuccessful():
        print("CLOSED_PER_RUN_BINDING_SCHEMA=PASS")
        print("CLOSED_TWO_RUN_BINDING_SCHEMA=PASS")
        print("REPORT_BINDING_SEMANTIC_EQUALITY=PASS")
        print("RECOMPUTED_SELF_HASH_MUTATIONS=PASS")
        print("AUGMENT_RUNTIME_SEED_FULL_REVALIDATION=PASS")
        print("NO_FAKE_GREEN=true")
    raise SystemExit(0 if result.wasSuccessful() else 1)
