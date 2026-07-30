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
        self.lib = (ROOT / "scripts" / "wave_c" / "lib.sh").read_text(encoding="utf-8")
        self.components = (ROOT / "scripts" / "wave_c" / "components.sh").read_text(encoding="utf-8")
        self.runtime = (ROOT / "scripts" / "wave_c" / "runtime.sh").read_text(encoding="utf-8")
        self.workflow = (ROOT / ".github" / "workflows" / "run-wave-c-exact-evidence.yml").read_text(encoding="utf-8")
        self.contract = json.loads(
            (ROOT / "contracts" / "GFF_WAVE_C_G1_V03_VALIDATION_v01.json").read_text(encoding="utf-8")
        )

    def test_every_private_command_receives_exact_source_sha_from_base_env(self) -> None:
        self.assertEqual(1, self.lib.count('"GFF_SOURCE_SHA=$PRIVATE_SHA"'))
        self.assertIn('timeout --signal=TERM --kill-after=30s "$command_timeout" env -i "${base_env[@]}" "${extra_env[@]}"', self.lib)
        self.assertGreater((self.components + self.runtime).count("run_private "), 5)
        self.assertNotIn("GFF_SOURCE_SHA=", self.components)
        self.assertNotIn("GFF_SOURCE_SHA=", self.runtime)

    def test_source_sha_has_no_user_controlled_origin(self) -> None:
        self.assertNotRegex(self.lib, r"GFF_SOURCE_SHA=\$(?:[1-9]|\{|@|\*)")
        self.assertNotIn("GFF_SOURCE_SHA=${GFF_SOURCE_SHA", self.lib)
        self.assertNotIn("inputs:", self.workflow)
        self.assertEqual([], self.contract["workflow_inputs"])
        self.assertEqual("source_controlled_fixed_value", self.contract["private_sha_source"])
        self.assertFalse(self.contract["canonical_v03_executor"]["workflow_input_override_allowed"])

    def test_pinned_private_sha_is_unchanged_and_allowlisted(self) -> None:
        self.assertIn(f"PRIVATE_SHA: {PINNED_PRIVATE_SHA}", self.workflow)
        self.assertIn(f'FIXED_PRIVATE_SHA="{PINNED_PRIVATE_SHA}"', self.lib)
        self.assertEqual(PINNED_PRIVATE_SHA, self.contract["pinned_private_sha"])
        self.assertNotIn("${{ inputs.", self.workflow)

    def test_security_invariants_remain_fixed(self) -> None:
        self.assertIn("PRIVATE_REPO: TheGor-365/generative-film-factory-control-center", self.workflow)
        self.assertIn("PRIVATE_BRANCH: main", self.workflow)
        self.assertIn("repository: TheGor-365/generative-film-factory-control-center", self.workflow)
        self.assertRegex(self.workflow, r"(?m)^\s+ref: main$")
        self.assertRegex(self.workflow, r"(?m)^\s+fetch-depth: 0$")
        self.assertFalse(self.contract["arbitrary_shell_allowed"])
        self.assertFalse(self.contract["arbitrary_paths_allowed"])
        self.assertFalse(self.contract["arbitrary_repositories_allowed"])
        self.assertFalse(self.contract["public_artifact_upload"])
        self.assertFalse(self.contract["cache"])
        self.assertFalse(self.contract["paid_provider_calls"])
        self.assertFalse(self.contract["network_media_provider_calls"])
        self.assertTrue(self.contract["always_delete_private_checkout"])
        self.assertTrue(self.contract["always_delete_runtime_and_artifact_roots"])
        self.assertEqual(["PASS", "FAIL", "ERROR", "BLOCKED"], self.contract["result_vocabulary"])

    def test_old_main_equality_assertion_is_absent(self) -> None:
        all_source = self.lib + self.components + self.runtime
        self.assertNotIn("PRIVATE_MAIN_SHA_MISMATCH", all_source)
        self.assertNotIn("PRIVATE_MAIN_SHA_MATCH", all_source)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(SourceShaPropagationTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.wasSuccessful():
        print("ALL_PRIVATE_PHASES_RECEIVE_GFF_SOURCE_SHA=true")
        print("SOURCE_SHA_EQUALS_PRIVATE_SHA=true")
        print("USER_CONTROLLED_SHA_INPUT=false")
        print("PINNED_PRIVATE_SHA_UNCHANGED=true")
        print("SOURCE_SHA_PROPAGATION_SECURITY_INVARIANTS=PASS")
        print("OLD_EQUALITY_ASSERTION_PRESENT=false")
    raise SystemExit(0 if result.wasSuccessful() else 1)
