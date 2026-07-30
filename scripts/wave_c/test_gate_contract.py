#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import importlib.util
import json
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = ROOT / "scripts" / "wave_c" / "evidence_contract.py"
spec = importlib.util.spec_from_file_location("evidence_contract", HELPER_PATH)
helper = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(helper)

ZERO = "0" * 64
ONE = "1" * 64
TWO = "2" * 64
THREE = "3" * 64
FOUR = "4" * 64
FIVE = "5" * 64
SIX = "6" * 64
SEVEN = "7" * 64
EIGHT = "8" * 64
NINE = "9" * 64


def official_actions_fixture(component_matrix: dict) -> dict:
    required = list(helper.REQUIRED_STEPS)
    steps = [
        {"step_id": step_id, "outcome": "success", "exit_code": 0, "evidence_sha256": hashlib.sha256(step_id.encode()).hexdigest()}
        for step_id in required
    ]
    payload = {
        "schema_version": "factory_actions_evidence_bundle_v01",
        "gate_id": "GFF_WAVE_C_G1_V03_VALIDATION_v01",
        "private_repository": "TheGor-365/generative-film-factory-control-center",
        "private_sha": "a" * 40,
        "runner_repository": "TheGor-365/generative-film-factory-actions-runner",
        "runner_sha": "b" * 40,
        "result": "PASS",
        "workflow": {"run_id": 12345, "run_attempt": 1, "status": "completed", "conclusion": "success"},
        "jobs": [{"job_id": 98765, "name": "validate-wave-c-exact-sha", "status": "completed", "conclusion": "success", "steps": steps}],
        "component_matrix": component_matrix,
        "doctor": {"source_sha": "a" * 40, "status": "PASS", "report_sha256": ONE},
        "run_a": {
            "source_sha": "a" * 40,
            "status": "PASS",
            "run_id": "run-a",
            "runtime_root_sha256": TWO,
            "artifact_root_sha256": THREE,
            "delivery_package_id": "delivery-a",
            "report_sha256": FOUR,
            "verify_sha256": FIVE,
            "fallback_used": True,
            "real_provider": False,
        },
        "run_b": {
            "source_sha": "a" * 40,
            "status": "PASS",
            "run_id": "run-b",
            "runtime_root_sha256": SIX,
            "artifact_root_sha256": SEVEN,
            "delivery_package_id": "delivery-b",
            "report_sha256": EIGHT,
            "verify_sha256": NINE,
            "fallback_used": True,
            "real_provider": False,
        },
        "aggregate": {"source_sha": "a" * 40, "status": "PASS", "evidence_index_sha256": ZERO, "release_check_sha256": ONE},
        "cleanup": {
            "private_checkout_deleted": True,
            "runtime_roots_deleted": True,
            "artifact_roots_deleted": True,
            "uploads_created": False,
            "caches_created": False,
        },
        "evidence_refs": [
            {"name": "component_matrix", "sha256": TWO},
            {"name": "doctor", "sha256": ONE},
            {"name": "run_a_report", "sha256": FOUR},
            {"name": "verify_a", "sha256": FIVE},
            {"name": "run_b_report", "sha256": EIGHT},
            {"name": "verify_b", "sha256": NINE},
            {"name": "aggregate_index", "sha256": ZERO},
            {"name": "release_check", "sha256": ONE},
        ],
    }
    payload["bundle_sha256"] = helper.self_hash(payload, "bundle_sha256")
    return payload


def validate_live_schema(payload: dict) -> None:
    required_top = {
        "gate_id", "private_repository", "private_sha", "runner_repository", "runner_sha", "result", "workflow", "jobs",
        "component_matrix", "doctor", "run_a", "run_b", "aggregate", "cleanup", "evidence_refs", "bundle_sha256"
    }
    assert required_top <= payload.keys()
    assert payload["result"] in helper.RESULTS
    assert re.fullmatch(r"[0-9a-f]{40}", payload["private_sha"])
    assert re.fullmatch(r"[0-9a-f]{40}", payload["runner_sha"])
    workflow = payload["workflow"]
    assert int(workflow["run_id"]) > 0 and int(workflow["run_attempt"]) > 0
    step_ids = [step["step_id"] for job in payload["jobs"] for step in job["steps"]]
    assert not (set(helper.REQUIRED_STEPS) - set(step_ids))
    matrix = payload["component_matrix"]
    assert matrix["schema_version"] == "factory_component_matrix_summary_v02"
    assert matrix["source_sha"] == payload["private_sha"]
    assert set(helper.COMPONENTS) <= set(matrix["components"])
    assert matrix["summary_sha256"] == helper.self_hash(matrix, "summary_sha256")
    for name in helper.COMPONENTS:
        component = matrix["components"][name]
        assert component["commands"]
        assert re.fullmatch(r"[0-9a-f]{64}", component["evidence_sha256"])
        for command in component["commands"]:
            assert {"command_id", "outcome", "exit_code", "evidence_sha256"} <= command.keys()
            assert command["outcome"] == "PASS"
            assert int(command["exit_code"]) == 0
    refs = [item["name"] for item in payload["evidence_refs"]]
    assert refs == list(helper.EVIDENCE_NAMES)
    assert payload["bundle_sha256"] == helper.self_hash(payload, "bundle_sha256")


class GateContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.contract = json.loads((ROOT / "contracts" / "GFF_WAVE_C_G1_V03_VALIDATION_v01.json").read_text(encoding="utf-8"))

    def test_contract_and_exact_step_ids(self) -> None:
        self.assertEqual(list(helper.REQUIRED_STEPS), self.contract["required_step_ids"])
        self.assertEqual("wave-c-v03-cycle", self.contract["canonical_v03_executor"]["command"])
        source_commit = self.contract["canonical_v03_executor"]["source_commit"]
        if source_commit is None:
            self.assertEqual("BLOCKED_PENDING_CHAT5_EXECUTOR_COMMIT", self.contract["canonical_v03_executor"]["binding_status"])
        else:
            self.assertRegex(source_commit, r"^[0-9a-f]{40}$")
        self.assertFalse(self.contract["arbitrary_shell_allowed"])
        self.assertFalse(self.contract["public_artifact_upload"])
        self.assertFalse(self.contract["cache"])
        self.assertEqual([], self.contract["workflow_inputs"])

    def test_private_checkout_topology_contract(self) -> None:
        topology = self.contract["private_checkout_topology"]
        self.assertEqual("allowlisted_main", topology["checkout_ref"])
        self.assertEqual(0, topology["fetch_depth"])
        self.assertTrue(topology["require_full_history"])
        self.assertTrue(topology["record_observed_main_head"])
        self.assertTrue(topology["require_pin_commit_exists"])
        self.assertTrue(topology["require_pin_ancestor_of_allowlisted_main"])
        self.assertTrue(topology["allow_main_equals_pin"])
        self.assertTrue(topology["allow_main_descendant_of_pin"])
        self.assertFalse(topology["require_main_equals_pin"])
        self.assertTrue(topology["detach_exact_pin"])
        self.assertTrue(topology["require_detached_head_equals_pin"])
        self.assertTrue(topology["require_clean_worktree"])

    def test_component_matrix_v02_generation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = {
                "schema_version": "gff_wave_c_gate_state_v02",
                "gate_id": "GFF_WAVE_C_G1_V03_VALIDATION_v01",
                "private_sha": "a" * 40,
                "runner_sha": "b" * 40,
                "records": [],
            }
            mapping = {
                "core": "core_component_matrix",
                "onboarding_web": "onboarding_web_component_matrix",
                "story": "story_component_matrix",
                "media": "media_component_matrix",
                "ops": "ops_component_matrix",
            }
            for name, step_id in mapping.items():
                state["records"].append(
                    {
                        "step_id": step_id,
                        "category": "component",
                        "command_id": f"{name}_001",
                        "outcome": "PASS",
                        "exit_code": 0,
                        "evidence_sha256": hashlib.sha256(name.encode()).hexdigest(),
                        "stable_codes": [],
                    }
                )
            helper.save_state(root, state)
            matrix, legacy = helper.generate_component_documents(root)
            self.assertEqual("factory_component_matrix_summary_v02", matrix["schema_version"])
            self.assertEqual("PASS", matrix["status"])
            self.assertEqual(matrix["summary_sha256"], helper.self_hash(matrix, "summary_sha256"))
            self.assertEqual("passed", legacy["status"])
            self.assertEqual(set(helper.COMPONENTS), set(matrix["components"]))

    def test_actions_bundle_reconstruction_fixture(self) -> None:
        components = {}
        for name in helper.COMPONENTS:
            command = {"command_id": f"{name}_001", "outcome": "PASS", "exit_code": 0, "evidence_sha256": hashlib.sha256(name.encode()).hexdigest()}
            component = {"outcome": "PASS", "commands": [command]}
            component["evidence_sha256"] = helper.self_hash(component, "evidence_sha256")
            components[name] = component
        matrix = {"schema_version": "factory_component_matrix_summary_v02", "source_sha": "a" * 40, "status": "PASS", "components": components}
        matrix["summary_sha256"] = helper.self_hash(matrix, "summary_sha256")
        payload = official_actions_fixture(matrix)
        validate_live_schema(payload)

    def test_four_state_classification(self) -> None:
        self.assertEqual("PASS", helper.overall_outcome(["PASS", "PASS"]))
        self.assertEqual("BLOCKED", helper.overall_outcome(["PASS", "BLOCKED"]))
        self.assertEqual("FAIL", helper.overall_outcome(["BLOCKED", "FAIL"]))
        self.assertEqual("ERROR", helper.overall_outcome(["FAIL", "ERROR"]))
        self.assertEqual("BLOCKED", helper.overall_outcome([]))

    def test_workflow_security_and_topology(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "run-wave-c-exact-evidence.yml").read_text(encoding="utf-8")
        production_paths = (
            ROOT / "scripts" / "run_wave_c_exact_gate.sh",
            ROOT / "scripts" / "wave_c" / "lib.sh",
            ROOT / "scripts" / "wave_c" / "components.sh",
            ROOT / "scripts" / "wave_c" / "runtime.sh",
            ROOT / "scripts" / "wave_c" / "evidence.sh",
            ROOT / "scripts" / "wave_c" / "git_topology.sh",
            ROOT / "scripts" / "wave_c" / "evidence_contract.py",
            ROOT / "scripts" / "wave_c" / "emit_failure_diagnostics.sh",
        )
        all_source = "\n".join(path.read_text(encoding="utf-8") for path in production_paths)
        for step_id in helper.REQUIRED_STEPS:
            self.assertIn(f"id: {step_id}", workflow)
        self.assertIn("id: canonical_v03_executor", workflow)
        self.assertIn("repository: TheGor-365/generative-film-factory-control-center", workflow)
        self.assertRegex(workflow, r"(?m)^\s+ref: main$")
        self.assertRegex(workflow, r"(?m)^\s+fetch-depth: 0$")
        self.assertNotIn("inputs:", workflow)
        self.assertNotIn("${{ inputs.", workflow)
        self.assertNotIn("actions/upload-artifact", workflow)
        self.assertNotIn("actions/cache", workflow)
        self.assertNotIn("__wave_c_execution_probe__", all_source)
        self.assertIsNone(re.search(r"ruby\s+[^\n]*factory[^\n]*\swave-c-v03(?:\s|$)", all_source))
        self.assertNotIn("eval ", all_source)
        self.assertNotIn("PRIVATE_MAIN_SHA_MISMATCH", all_source)
        self.assertNotIn("PRIVATE_MAIN_SHA_MATCH", all_source)

    def test_runtime_and_contract_executor_binding_match(self) -> None:
        runtime = (ROOT / "scripts" / "wave_c" / "runtime.sh").read_text(encoding="utf-8")
        command = self.contract["canonical_v03_executor"]["command"]
        self.assertIn('payload.get("canonical_v03_executor", {}).get("source_commit")', runtime)
        self.assertIn('payload.get("canonical_v03_executor", {}).get("command")', runtime)
        self.assertIn("CHAT5_EXECUTOR_COMMIT_NOT_BOUND", runtime)
        self.assertIn(command, json.dumps(self.contract))


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(GateContractTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.wasSuccessful():
        print("LIVE_OPS_SCHEMA_COMPATIBILITY=PASS")
        print("PRIVATE_CHECKOUT_TOPOLOGY_CONTRACT=PASS")
        print("NONEXISTENT_COMMAND_PROBE_REMOVED=true")
        print("COMPONENT_MATRIX_V02_GENERATION_TEST=PASS")
        print("ACTIONS_BUNDLE_RECONSTRUCTION_FIXTURE=PASS")
        print("FOUR_STATE_CLASSIFICATION_TEST=PASS")
        print("UPLOAD_ACTION_PRESENT=false")
        print("CACHE_ACTION_PRESENT=false")
    raise SystemExit(0 if result.wasSuccessful() else 1)
