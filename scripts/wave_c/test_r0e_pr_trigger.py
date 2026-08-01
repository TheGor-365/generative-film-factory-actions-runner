#!/usr/bin/env python3
"""Fail-closed validator and source tests for the exact R0E-04 PR trigger slot."""
from __future__ import annotations

import argparse
import copy
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "gff_r0e_observable_trigger_v01"
CHAT_INSTANCE_ID = "GFF-CHAT-R0E-04"
WORK_ORDER_ID = "RWO-GFF-RUNNER-ONE-FRESH-OBSERVABLE-RUN-004"
FROZEN_PRIVATE_SHA = "be76c8be95fa61d175c4c99ea16b4bf670510560"
AUTHORIZATION_NONCE = "66f5bbb15d1d8d2af1dd7b1587047ec551a9b35121fa85267ed97ffc6e44b7c6"
TRIGGER_BRANCH = "run/r0e-04-fresh-evidence-001"
TRIGGER_PATH = ".github/gff/r0e_triggers/R0E_04_001.json"

LEGACY_R0E02_CHAT = "GFF-CHAT-R0E-02"
LEGACY_R0E02_WORK_ORDER = "RWO-GFF-RUNNER-ONE-FRESH-OBSERVABLE-RUN-002"
LEGACY_R0E02_NONCE = "fca997c30d411578f1ae216300f219ce60025fadb75eda7285e38f36c02aab97"
LEGACY_R0E02_BRANCH = "run/r0e-02-fresh-evidence-001"
LEGACY_R0E02_PATH = ".github/gff/r0e_triggers/R0E_02_001.json"

LEGACY_R0E03_CHAT = "GFF-CHAT-R0E-03"
LEGACY_R0E03_WORK_ORDER = "RWO-GFF-RUNNER-ONE-FRESH-OBSERVABLE-RUN-003"
LEGACY_R0E03_NONCE = "435aa7987702ff8c7462f1c01f47e2e12193a24e461c7dacd9d34d23305c25ab"
LEGACY_R0E03_BRANCH = "run/r0e-03-fresh-evidence-001"
LEGACY_R0E03_PATH = ".github/gff/r0e_triggers/R0E_03_001.json"

NEW_NEGATIVE_ATTACKS = 25
SHA40 = re.compile(r"^[0-9a-f]{40}$")

EXPECTED_KEYS = frozenset(
    {
        "schema_version",
        "chat_instance_id",
        "work_order_id",
        "runner_base_sha",
        "frozen_private_sha",
        "authorization_nonce",
        "dispatch_ordinal",
        "historical_rerun",
        "second_dispatch",
        "media_execution_authorized",
        "paid_provider_execution_authorized",
        "no_fake_green",
    }
)
FALSE_FLAGS = (
    "historical_rerun",
    "second_dispatch",
    "media_execution_authorized",
    "paid_provider_execution_authorized",
)
DUPLICATE_AUTHORITY_KEYS = (
    "authorization_nonce",
    "runner_base_sha",
    "dispatch_ordinal",
    "historical_rerun",
    "second_dispatch",
    "media_execution_authorized",
    "paid_provider_execution_authorized",
    "no_fake_green",
)


class TriggerValidationError(ValueError):
    """Closed trigger document or PR-selection contract failure."""


def reject_duplicate_object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """Build one JSON object while rejecting every duplicate key recursively."""
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise TriggerValidationError(f"TRIGGER_JSON_DUPLICATE_KEY key={key}")
        result[key] = value
    return result


def require_exact_string(payload: dict[str, Any], key: str, expected: str) -> None:
    value = payload.get(key)
    if type(value) is not str or value != expected:
        raise TriggerValidationError(f"{key.upper()}_MISMATCH")


def validate_trigger_document(payload: Any, runner_base_sha: str) -> None:
    """Validate the exact closed R0E-04 trigger document against trusted source constants."""
    if type(payload) is not dict:
        raise TriggerValidationError("TRIGGER_ROOT_NOT_OBJECT")

    observed_keys = frozenset(payload)
    if observed_keys != EXPECTED_KEYS:
        missing = ",".join(sorted(EXPECTED_KEYS - observed_keys)) or "none"
        extra = ",".join(sorted(observed_keys - EXPECTED_KEYS)) or "none"
        raise TriggerValidationError(f"TRIGGER_KEYS_NOT_CLOSED missing={missing} extra={extra}")

    if type(runner_base_sha) is not str or not SHA40.fullmatch(runner_base_sha):
        raise TriggerValidationError("EXPECTED_RUNNER_BASE_SHA_INVALID")

    require_exact_string(payload, "schema_version", SCHEMA_VERSION)
    require_exact_string(payload, "chat_instance_id", CHAT_INSTANCE_ID)
    require_exact_string(payload, "work_order_id", WORK_ORDER_ID)
    require_exact_string(payload, "runner_base_sha", runner_base_sha)
    require_exact_string(payload, "frozen_private_sha", FROZEN_PRIVATE_SHA)
    require_exact_string(payload, "authorization_nonce", AUTHORIZATION_NONCE)

    ordinal = payload["dispatch_ordinal"]
    if type(ordinal) is not int or ordinal != 1:
        raise TriggerValidationError("DISPATCH_ORDINAL_NOT_EXACT_INTEGER_ONE")

    for key in FALSE_FLAGS:
        value = payload[key]
        if type(value) is not bool or value is not False:
            raise TriggerValidationError(f"{key.upper()}_NOT_EXACT_FALSE")

    no_fake_green = payload["no_fake_green"]
    if type(no_fake_green) is not bool or no_fake_green is not True:
        raise TriggerValidationError("NO_FAKE_GREEN_NOT_EXACT_TRUE")


def validate_pr_trigger_context(
    *,
    action: str,
    base_ref: str,
    head_repo: str,
    runner_repo: str,
    head_ref: str,
    trigger_path: str,
    expected_runner_base_sha: str,
    event_base_sha: str,
    execution_sha: str,
    trigger_sha: str,
    delta: list[str],
) -> None:
    """Model the workflow's fail-closed PR selection and one-file delta contract."""
    if action != "opened":
        raise TriggerValidationError("PR_ACTION_NOT_OPENED")
    if base_ref != "main":
        raise TriggerValidationError("PR_BASE_NOT_MAIN")
    if head_repo != runner_repo:
        raise TriggerValidationError("PR_HEAD_REPOSITORY_NOT_RUNNER")
    if head_ref != TRIGGER_BRANCH:
        raise TriggerValidationError("TRIGGER_BRANCH_MISMATCH")
    if trigger_path != TRIGGER_PATH:
        raise TriggerValidationError("TRIGGER_PATH_MISMATCH")

    for name, value in (
        ("expected_runner_base_sha", expected_runner_base_sha),
        ("event_base_sha", event_base_sha),
        ("execution_sha", execution_sha),
        ("trigger_sha", trigger_sha),
    ):
        if type(value) is not str or not SHA40.fullmatch(value):
            raise TriggerValidationError(f"{name.upper()}_INVALID")

    if event_base_sha != expected_runner_base_sha:
        raise TriggerValidationError("RUNNER_BASE_SHA_MISMATCH")
    if execution_sha != event_base_sha:
        if execution_sha == trigger_sha:
            raise TriggerValidationError("TRIGGER_HEAD_EXECUTION_FORBIDDEN")
        raise TriggerValidationError("EXACT_BASE_SHA_EXECUTION_REQUIRED")

    expected_delta = [f"A\t{TRIGGER_PATH}"]
    if delta != expected_delta:
        raise TriggerValidationError("ONE_ADDED_TRIGGER_FILE_DELTA_REQUIRED")


def load_json_object(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_object_pairs,
        )
    except TriggerValidationError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise TriggerValidationError("TRIGGER_JSON_INVALID") from exc


def canonical_payload(runner_base_sha: str = "1" * 40) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "chat_instance_id": CHAT_INSTANCE_ID,
        "work_order_id": WORK_ORDER_ID,
        "runner_base_sha": runner_base_sha,
        "frozen_private_sha": FROZEN_PRIVATE_SHA,
        "authorization_nonce": AUTHORIZATION_NONCE,
        "dispatch_ordinal": 1,
        "historical_rerun": False,
        "second_dispatch": False,
        "media_execution_authorized": False,
        "paid_provider_execution_authorized": False,
        "no_fake_green": True,
    }


def canonical_pr_context() -> dict[str, Any]:
    base_sha = "1" * 40
    return {
        "action": "opened",
        "base_ref": "main",
        "head_repo": "TheGor-365/generative-film-factory-actions-runner",
        "runner_repo": "TheGor-365/generative-film-factory-actions-runner",
        "head_ref": TRIGGER_BRANCH,
        "trigger_path": TRIGGER_PATH,
        "expected_runner_base_sha": base_sha,
        "event_base_sha": base_sha,
        "execution_sha": base_sha,
        "trigger_sha": "2" * 40,
        "delta": [f"A\t{TRIGGER_PATH}"],
    }


def duplicate_document(payload: dict[str, Any], key: str, first: Any, second: Any) -> str:
    entries: list[str] = []
    for observed_key, value in payload.items():
        if observed_key == key:
            entries.append(f"{json.dumps(key)}:{json.dumps(first)}")
            entries.append(f"{json.dumps(key)}:{json.dumps(second)}")
        else:
            entries.append(f"{json.dumps(observed_key)}:{json.dumps(value)}")
    return "{" + ",".join(entries) + "}"


def load_raw(raw: str) -> Any:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "trigger.json"
        path.write_text(raw, encoding="utf-8")
        return load_json_object(path)


class TriggerContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.runner_sha = "1" * 40
        self.payload = canonical_payload(self.runner_sha)

    def assert_rejected(self, mutation: dict[str, Any], expected_code: str) -> None:
        candidate = copy.deepcopy(self.payload)
        candidate.update(mutation)
        with self.assertRaisesRegex(TriggerValidationError, expected_code):
            validate_trigger_document(candidate, self.runner_sha)

    def test_canonical_trigger_passes(self) -> None:
        validate_trigger_document(self.payload, self.runner_sha)

    def test_closed_object_rejects_missing_and_extra_keys(self) -> None:
        missing = copy.deepcopy(self.payload)
        missing.pop("authorization_nonce")
        with self.assertRaisesRegex(TriggerValidationError, "TRIGGER_KEYS_NOT_CLOSED"):
            validate_trigger_document(missing, self.runner_sha)
        extra = copy.deepcopy(self.payload)
        extra["unexpected"] = False
        with self.assertRaisesRegex(TriggerValidationError, "TRIGGER_KEYS_NOT_CLOSED"):
            validate_trigger_document(extra, self.runner_sha)

    def test_exact_identity_and_authority_bindings(self) -> None:
        cases = {
            "schema_version": "wrong",
            "chat_instance_id": "GFF-CHAT-R0E-99",
            "work_order_id": "wrong",
            "runner_base_sha": "2" * 40,
            "frozen_private_sha": "3" * 40,
            "authorization_nonce": "wrong",
        }
        for key, value in cases.items():
            with self.subTest(key=key):
                self.assert_rejected({key: value}, key.upper())

    def test_ordinal_rejects_bool_string_zero_and_two(self) -> None:
        for value in (True, "1", 0, 2):
            with self.subTest(value=value):
                self.assert_rejected(
                    {"dispatch_ordinal": value},
                    "DISPATCH_ORDINAL_NOT_EXACT_INTEGER_ONE",
                )

    def test_forbidden_flags_require_exact_false(self) -> None:
        for key in FALSE_FLAGS:
            for value in (True, 0, "false", None):
                with self.subTest(key=key, value=value):
                    self.assert_rejected({key: value}, f"{key.upper()}_NOT_EXACT_FALSE")

    def test_no_fake_green_requires_exact_true(self) -> None:
        for value in (False, 1, "true", None):
            with self.subTest(value=value):
                self.assert_rejected({"no_fake_green": value}, "NO_FAKE_GREEN_NOT_EXACT_TRUE")


class DuplicateKeyParserTests(unittest.TestCase):
    def setUp(self) -> None:
        self.runner_sha = "1" * 40
        self.payload = canonical_payload(self.runner_sha)

    def assert_raw_rejected(self, raw: str, expected_key: str) -> None:
        with self.assertRaisesRegex(
            TriggerValidationError,
            rf"TRIGGER_JSON_DUPLICATE_KEY key={re.escape(expected_key)}",
        ):
            load_raw(raw)

    def test_identical_duplicate_authority_values_are_rejected(self) -> None:
        for key in DUPLICATE_AUTHORITY_KEYS:
            with self.subTest(key=key):
                value = self.payload[key]
                self.assert_raw_rejected(duplicate_document(self.payload, key, value, value), key)

    def test_conflicting_duplicate_authority_values_are_rejected(self) -> None:
        conflicting_values = {
            "authorization_nonce": "wrong",
            "runner_base_sha": "2" * 40,
            "dispatch_ordinal": 2,
            "historical_rerun": True,
            "second_dispatch": True,
            "media_execution_authorized": True,
            "paid_provider_execution_authorized": True,
            "no_fake_green": False,
        }
        for key, conflicting_value in conflicting_values.items():
            with self.subTest(key=key):
                self.assert_raw_rejected(
                    duplicate_document(self.payload, key, self.payload[key], conflicting_value),
                    key,
                )

    def test_nested_object_duplicates_are_rejected_recursively(self) -> None:
        raw = '{"future_nested":{"authority":false,"authority":true}}'
        self.assert_raw_rejected(raw, "authority")


class RequiredNegativeAttackTests(unittest.TestCase):
    """Exact mandatory rejection matrix for R0D-10 (25 attacks)."""

    def setUp(self) -> None:
        self.runner_sha = "1" * 40
        self.payload = canonical_payload(self.runner_sha)
        self.pr_context = canonical_pr_context()

    def assert_document_rejected(self, mutation: dict[str, Any], code: str) -> None:
        candidate = copy.deepcopy(self.payload)
        candidate.update(mutation)
        with self.assertRaisesRegex(TriggerValidationError, code):
            validate_trigger_document(candidate, self.runner_sha)

    def assert_pr_rejected(self, mutation: dict[str, Any], code: str) -> None:
        candidate = copy.deepcopy(self.pr_context)
        candidate.update(mutation)
        with self.assertRaisesRegex(TriggerValidationError, code):
            validate_pr_trigger_context(**candidate)

    def test_01_r0e02_path_rejected(self) -> None:
        self.assert_pr_rejected({"trigger_path": LEGACY_R0E02_PATH}, "TRIGGER_PATH_MISMATCH")

    def test_02_r0e02_branch_rejected(self) -> None:
        self.assert_pr_rejected({"head_ref": LEGACY_R0E02_BRANCH}, "TRIGGER_BRANCH_MISMATCH")

    def test_03_r0e02_chat_id_rejected(self) -> None:
        self.assert_document_rejected({"chat_instance_id": LEGACY_R0E02_CHAT}, "CHAT_INSTANCE_ID_MISMATCH")

    def test_04_r0e02_work_order_rejected(self) -> None:
        self.assert_document_rejected({"work_order_id": LEGACY_R0E02_WORK_ORDER}, "WORK_ORDER_ID_MISMATCH")

    def test_05_r0e02_nonce_rejected(self) -> None:
        self.assert_document_rejected({"authorization_nonce": LEGACY_R0E02_NONCE}, "AUTHORIZATION_NONCE_MISMATCH")

    def test_06_r0e03_path_rejected(self) -> None:
        self.assert_pr_rejected({"trigger_path": LEGACY_R0E03_PATH}, "TRIGGER_PATH_MISMATCH")

    def test_07_r0e03_branch_rejected(self) -> None:
        self.assert_pr_rejected({"head_ref": LEGACY_R0E03_BRANCH}, "TRIGGER_BRANCH_MISMATCH")

    def test_08_r0e03_chat_id_rejected(self) -> None:
        self.assert_document_rejected({"chat_instance_id": LEGACY_R0E03_CHAT}, "CHAT_INSTANCE_ID_MISMATCH")

    def test_09_r0e03_work_order_rejected(self) -> None:
        self.assert_document_rejected({"work_order_id": LEGACY_R0E03_WORK_ORDER}, "WORK_ORDER_ID_MISMATCH")

    def test_10_r0e03_nonce_rejected(self) -> None:
        self.assert_document_rejected({"authorization_nonce": LEGACY_R0E03_NONCE}, "AUTHORIZATION_NONCE_MISMATCH")

    def test_11_wrong_r0e04_path_rejected(self) -> None:
        self.assert_pr_rejected({"trigger_path": ".github/gff/r0e_triggers/R0E_04_002.json"}, "TRIGGER_PATH_MISMATCH")

    def test_12_wrong_r0e04_branch_rejected(self) -> None:
        self.assert_pr_rejected({"head_ref": "run/r0e-04-fresh-evidence-002"}, "TRIGGER_BRANCH_MISMATCH")

    def test_13_wrong_nonce_rejected(self) -> None:
        self.assert_document_rejected({"authorization_nonce": "0" * 64}, "AUTHORIZATION_NONCE_MISMATCH")

    def test_14_missing_nonce_rejected(self) -> None:
        candidate = copy.deepcopy(self.payload)
        candidate.pop("authorization_nonce")
        with self.assertRaisesRegex(TriggerValidationError, "TRIGGER_KEYS_NOT_CLOSED"):
            validate_trigger_document(candidate, self.runner_sha)

    def test_15_duplicate_nonce_rejected(self) -> None:
        raw = duplicate_document(
            self.payload,
            "authorization_nonce",
            AUTHORIZATION_NONCE,
            AUTHORIZATION_NONCE,
        )
        with self.assertRaisesRegex(TriggerValidationError, "TRIGGER_JSON_DUPLICATE_KEY key=authorization_nonce"):
            load_raw(raw)

    def test_16_conflicting_duplicate_nonce_rejected(self) -> None:
        raw = duplicate_document(
            self.payload,
            "authorization_nonce",
            AUTHORIZATION_NONCE,
            "0" * 64,
        )
        with self.assertRaisesRegex(TriggerValidationError, "TRIGGER_JSON_DUPLICATE_KEY key=authorization_nonce"):
            load_raw(raw)

    def test_17_nested_duplicate_keys_rejected(self) -> None:
        raw = '{"nested":{"nonce":"a","nonce":"b"}}'
        with self.assertRaisesRegex(TriggerValidationError, "TRIGGER_JSON_DUPLICATE_KEY key=nonce"):
            load_raw(raw)

    def test_18_wrong_runner_base_sha_rejected(self) -> None:
        self.assert_document_rejected({"runner_base_sha": "2" * 40}, "RUNNER_BASE_SHA_MISMATCH")

    def test_19_trigger_head_execution_rejected(self) -> None:
        self.assert_pr_rejected({"execution_sha": "2" * 40}, "TRIGGER_HEAD_EXECUTION_FORBIDDEN")

    def test_20_two_file_delta_rejected(self) -> None:
        self.assert_pr_rejected(
            {"delta": [f"A\t{TRIGGER_PATH}", "A\tREADME.md"]},
            "ONE_ADDED_TRIGGER_FILE_DELTA_REQUIRED",
        )

    def test_21_modified_file_delta_rejected(self) -> None:
        self.assert_pr_rejected({"delta": [f"M\t{TRIGGER_PATH}"]}, "ONE_ADDED_TRIGGER_FILE_DELTA_REQUIRED")

    def test_22_deleted_file_delta_rejected(self) -> None:
        self.assert_pr_rejected({"delta": [f"D\t{TRIGGER_PATH}"]}, "ONE_ADDED_TRIGGER_FILE_DELTA_REQUIRED")

    def test_23_fork_head_repository_rejected(self) -> None:
        self.assert_pr_rejected({"head_repo": "attacker/fork"}, "PR_HEAD_REPOSITORY_NOT_RUNNER")

    def test_24_non_main_base_rejected(self) -> None:
        self.assert_pr_rejected({"base_ref": "develop"}, "PR_BASE_NOT_MAIN")

    def test_25_non_opened_pr_action_rejected(self) -> None:
        self.assert_pr_rejected({"action": "synchronize"}, "PR_ACTION_NOT_OPENED")


class WorkflowSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.repo_root = Path(__file__).resolve().parents[2]
        cls.workflow_path = cls.repo_root / ".github/workflows/run-wave-c-exact-evidence.yml"
        cls.workflow = cls.workflow_path.read_text(encoding="utf-8")
        cls.validator_source = Path(__file__).read_text(encoding="utf-8")

    def test_event_selection_is_dispatch_or_exact_opened_pr(self) -> None:
        source = self.workflow
        self.assertIn("  workflow_dispatch:\n", source)
        self.assertIn("  pull_request:\n", source)
        self.assertIn("      - main\n", source)
        self.assertIn("      - opened\n", source)
        self.assertNotIn("pull_request_target", source)
        self.assertNotIn("inputs:", source)

    def test_active_static_contract_is_exact_r0e04(self) -> None:
        source = self.workflow
        expected_lines = (
            f"      ACTIVE_TRIGGER_CHAT: {CHAT_INSTANCE_ID}\n",
            f"      ACTIVE_TRIGGER_WORK_ORDER: {WORK_ORDER_ID}\n",
            f"      ACTIVE_TRIGGER_BRANCH: {TRIGGER_BRANCH}\n",
            f"      ACTIVE_TRIGGER_PATH: {TRIGGER_PATH}\n",
            f"      ACTIVE_TRIGGER_NONCE: {AUTHORIZATION_NONCE}\n",
            f"      TRIGGER_PATH: {TRIGGER_PATH}\n",
        )
        for line in expected_lines:
            with self.subTest(line=line):
                self.assertIn(line, source)

    def test_path_and_same_repository_branch_are_exact(self) -> None:
        source = self.workflow
        self.assertIn(f"      - {TRIGGER_PATH}\n", source)
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", source)
        self.assertIn(f"github.event.pull_request.head.ref == '{TRIGGER_BRANCH}'", source)
        self.assertIn("github.event.pull_request.base.ref == 'main'", source)
        self.assertIn('[[ "$PR_HEAD_REF" == "$ACTIVE_TRIGGER_BRANCH" ]]', source)

    def test_legacy_slots_are_not_active_workflow_constants(self) -> None:
        source = self.workflow
        for legacy in (
            LEGACY_R0E02_PATH,
            LEGACY_R0E02_BRANCH,
            LEGACY_R0E02_CHAT,
            LEGACY_R0E02_WORK_ORDER,
            LEGACY_R0E02_NONCE,
            LEGACY_R0E03_PATH,
            LEGACY_R0E03_BRANCH,
            LEGACY_R0E03_CHAT,
            LEGACY_R0E03_WORK_ORDER,
            LEGACY_R0E03_NONCE,
        ):
            with self.subTest(legacy=legacy):
                self.assertNotIn(legacy, source)

    def test_active_validator_assignments_are_exact_and_not_legacy(self) -> None:
        source = self.validator_source
        self.assertIn(f'CHAT_INSTANCE_ID = "{CHAT_INSTANCE_ID}"', source)
        self.assertIn(f'WORK_ORDER_ID = "{WORK_ORDER_ID}"', source)
        self.assertIn(f'AUTHORIZATION_NONCE = "{AUTHORIZATION_NONCE}"', source)
        self.assertIn(f'TRIGGER_BRANCH = "{TRIGGER_BRANCH}"', source)
        self.assertIn(f'TRIGGER_PATH = "{TRIGGER_PATH}"', source)
        self.assertNotIn(f'CHAT_INSTANCE_ID = "{LEGACY_R0E02_CHAT}"', source)
        self.assertNotIn(f'CHAT_INSTANCE_ID = "{LEGACY_R0E03_CHAT}"', source)

    def test_execution_uses_exact_base_and_head_is_evidence_only(self) -> None:
        source = self.workflow
        self.assertIn(
            "RUNNER_SHA: ${{ github.event_name == 'pull_request' && github.event.pull_request.base.sha || github.sha }}",
            source,
        )
        self.assertIn(
            "TRIGGER_SHA: ${{ github.event_name == 'pull_request' && github.event.pull_request.head.sha || '' }}",
            source,
        )
        self.assertIn("ref: ${{ env.RUNNER_SHA }}", source)
        self.assertNotIn("ref: ${{ env.TRIGGER_SHA }}", source)
        self.assertIn('[[ "$actual_runner_sha" == "$RUNNER_SHA" ]]', source)
        self.assertIn('git show "$TRIGGER_SHA:$TRIGGER_PATH"', source)
        self.assertIn("TRIGGER_HEAD_EXECUTED=false", source)

    def test_exact_one_file_delta_and_closed_contract_are_enforced(self) -> None:
        source = self.workflow
        self.assertIn('git diff --name-status "$RUNNER_SHA" "$TRIGGER_SHA"', source)
        self.assertIn("[[ ${#trigger_delta[@]} -eq 1 ]]", source)
        self.assertIn("$'A\\t'\"$TRIGGER_PATH\"", source)
        self.assertIn("test_r0e_pr_trigger.py validate", source)
        self.assertIn("--runner-base-sha \"$RUNNER_SHA\"", source)

    def test_no_artifact_or_cache_actions_added(self) -> None:
        source = self.workflow
        self.assertNotIn("actions/upload-artifact", source)
        self.assertNotIn("actions/cache", source)


def run_validation(path: Path, runner_base_sha: str) -> int:
    try:
        payload = load_json_object(path)
        validate_trigger_document(payload, runner_base_sha)
    except TriggerValidationError as exc:
        print(f"TRIGGER_JSON_CLOSED=FAIL reason={exc}", file=sys.stderr)
        return 1

    print("TRIGGER_JSON_CLOSED=PASS")
    print("TRIGGER_CHAT_WORK_ORDER_IDS=PASS")
    print("TRIGGER_DISPATCH_ORDINAL=PASS")
    print("TRIGGER_NONCE=PASS")
    print("TRIGGER_FROZEN_PRIVATE_SHA=PASS")
    print("TRIGGER_FALSE_FLAGS=PASS")
    print("NO_FAKE_GREEN=true")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command")
    validate = subparsers.add_parser("validate")
    validate.add_argument("--path", type=Path, required=True)
    validate.add_argument("--runner-base-sha", required=True)
    return parser.parse_args(argv)


def emit_static_contract() -> None:
    print(f"ACTIVE_TRIGGER_CHAT={CHAT_INSTANCE_ID}")
    print(f"ACTIVE_TRIGGER_WORK_ORDER={WORK_ORDER_ID}")
    print(f"ACTIVE_TRIGGER_BRANCH={TRIGGER_BRANCH}")
    print(f"ACTIVE_TRIGGER_PATH={TRIGGER_PATH}")
    print(f"ACTIVE_TRIGGER_NONCE={AUTHORIZATION_NONCE}")
    print("R0E02_ACTIVE_CONSTANTS_PRESENT=false")
    print("R0E03_ACTIVE_CONSTANTS_PRESENT=false")
    print(f"NEW_NEGATIVE_ATTACKS={NEW_NEGATIVE_ATTACKS}")
    print("NO_FAKE_GREEN=true")


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.command == "validate":
        return run_validation(args.path, args.runner_base_sha)
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.wasSuccessful():
        emit_static_contract()
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
