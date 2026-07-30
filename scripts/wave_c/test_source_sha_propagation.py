#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PINNED_PRIVATE_SHA = "be76c8be95fa61d175c4c99ea16b4bf670510560"


class SourceShaPropagationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.components = (ROOT / "scripts" / "wave_c" / "components.sh").read_text(encoding="utf-8")
        self.workflow = (ROOT / ".github" / "workflows" / "run-wave-c-exact-evidence.yml").read_text(encoding="utf-8")
        self.contract = json.loads(
            (ROOT / "contracts" / "GFF_WAVE_C_G1_V03_VALIDATION_v01.json").read_text(encoding="utf-8")
        )

    def discovered_component_body(self) -> str:
        match = re.search(
            r"run_discovered_component\(\) \{(?P<body>.*?)\n\}\n\nphase_core_component_matrix\(\)",
            self.components,
            re.S,
        )
        self.assertIsNotNone(match, "run_discovered_component body missing")
        return match.group("body")

    def test_discovered_component_receives_exact_runner_sha(self) -> None:
        body = self.discovered_component_body()
        self.assertEqual(1, body.count('"GFF_SOURCE_SHA=$PRIVATE_SHA"'))
        self.assertIn('run_private "$step_id" component "$command_id" "$private_checkout"', body)
        self.assertLess(
            body.index('run_private "$step_id" component "$command_id" "$private_checkout"'),
            body.index('"GFF_SOURCE_SHA=$PRIVATE_SHA"'),
        )

    def test_source_sha_has_no_user_controlled_origin(self) -> None:
        body = self.discovered_component_body()
        self.assertNotRegex(body, r"GFF_SOURCE_SHA=\$(?:[1-9]|\{|@|\*)")
        self.assertNotIn("GFF_SOURCE_SHA=${GFF_SOURCE_SHA", body)
        self.assertNotIn("inputs:", self.workflow)
        self.assertEqual([], self.contract["workflow_inputs"])
        self.assertEqual("source_controlled_fixed_value", self.contract["private_sha_source"])
        self.assertFalse(self.contract["canonical_v03_executor"]["workflow_input_override_allowed"])

    def test_pinned_private_sha_is_unchanged(self) -> None:
        self.assertIn(f"PRIVATE_SHA: {PINNED_PRIVATE_SHA}", self.workflow)
        self.assertEqual(PINNED_PRIVATE_SHA, self.contract["pinned_private_sha"])
        self.assertNotIn("${{ inputs.", self.workflow)

    def test_security_invariants_remain_fixed(self) -> None:
        self.assertIn("PRIVATE_REPO: TheGor-365/generative-film-factory-control-center", self.workflow)
        self.assertIn("PRIVATE_BRANCH: main", self.workflow)
        self.assertFalse(self.contract["arbitrary_shell_allowed"])
        self.assertFalse(self.contract["arbitrary_paths_allowed"])
        self.assertFalse(self.contract["public_artifact_upload"])
        self.assertFalse(self.contract["cache"])
        self.assertFalse(self.contract["paid_provider_calls"])
        self.assertFalse(self.contract["network_media_provider_calls"])
        self.assertTrue(self.contract["always_delete_private_checkout"])
        self.assertTrue(self.contract["always_delete_runtime_and_artifact_roots"])
        self.assertEqual(["PASS", "FAIL", "ERROR", "BLOCKED"], self.contract["result_vocabulary"])


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(SourceShaPropagationTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.wasSuccessful():
        print("DISCOVERED_COMPONENT_RECEIVES_GFF_SOURCE_SHA=true")
        print("SOURCE_SHA_EQUALS_PRIVATE_SHA=true")
        print("USER_CONTROLLED_SHA_INPUT=false")
        print("PINNED_PRIVATE_SHA_UNCHANGED=true")
        print("SOURCE_SHA_PROPAGATION_SECURITY_INVARIANTS=PASS")
    raise SystemExit(0 if result.wasSuccessful() else 1)
