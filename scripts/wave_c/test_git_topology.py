#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOPOLOGY = ROOT / "scripts" / "wave_c" / "git_topology.sh"
RUNNER = ROOT / "scripts" / "run_wave_c_exact_gate.sh"
PINNED_PRIVATE_SHA = "be76c8be95fa61d175c4c99ea16b4bf670510560"


def run(command: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )


def require_ok(result: subprocess.CompletedProcess[str]) -> str:
    if result.returncode != 0:
        raise AssertionError(f"command failed ({result.returncode}):\n{result.stdout}")
    return result.stdout


class GitTopologyTest(unittest.TestCase):
    def init_repo(self, root: Path) -> Path:
        repo = root / "repo"
        require_ok(run(["git", "init", "-b", "main", str(repo)]))
        require_ok(run(["git", "config", "user.name", "Topology Fixture"], cwd=repo))
        require_ok(run(["git", "config", "user.email", "topology@example.invalid"], cwd=repo))
        return repo

    def commit(self, repo: Path, name: str, content: str) -> str:
        (repo / name).write_text(content, encoding="utf-8")
        require_ok(run(["git", "add", name], cwd=repo))
        require_ok(run(["git", "commit", "-m", f"add {name}"], cwd=repo))
        return require_ok(run(["git", "rev-parse", "HEAD"], cwd=repo)).strip()

    def verify(self, repo: Path, pin: str) -> subprocess.CompletedProcess[str]:
        return run(["bash", str(TOPOLOGY), str(repo), pin], cwd=ROOT)

    def assert_detached(self, repo: Path, pin: str) -> subprocess.CompletedProcess[str]:
        command = 'source "$1"; assert_detached_private_state "$2" "$3"'
        return run(["bash", "-c", command, "_", str(TOPOLOGY), str(repo), pin], cwd=ROOT)

    def test_main_equals_pin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = self.init_repo(Path(directory))
            pin = self.commit(repo, "base.txt", "base\n")
            result = self.verify(repo, pin)
            self.assertEqual(0, result.returncode, result.stdout)
            self.assertIn(f"PRIVATE_MAIN_HEAD_OBSERVED={pin}", result.stdout)
            self.assertIn("PRIVATE_PIN_EXISTS=true", result.stdout)
            self.assertIn("PRIVATE_PIN_ANCESTOR_OF_ALLOWLISTED_MAIN=true", result.stdout)
            self.assertIn("DETACHED_PRIVATE_SHA_MATCH=true", result.stdout)
            self.assertIn("PRIVATE_WORKTREE_CLEAN=true", result.stdout)

    def test_main_descendant_of_pin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = self.init_repo(Path(directory))
            pin = self.commit(repo, "base.txt", "base\n")
            main_head = self.commit(repo, "descendant.txt", "descendant\n")
            result = self.verify(repo, pin)
            self.assertEqual(0, result.returncode, result.stdout)
            self.assertIn(f"PRIVATE_MAIN_HEAD_OBSERVED={main_head}", result.stdout)
            self.assertIn("PRIVATE_PIN_ANCESTOR_OF_ALLOWLISTED_MAIN=true", result.stdout)
            self.assertEqual(pin, require_ok(run(["git", "rev-parse", "HEAD"], cwd=repo)).strip())

    def test_pin_not_ancestor_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = self.init_repo(Path(directory))
            self.commit(repo, "base.txt", "base\n")
            require_ok(run(["git", "checkout", "-b", "side"], cwd=repo))
            pin = self.commit(repo, "side.txt", "side\n")
            require_ok(run(["git", "checkout", "main"], cwd=repo))
            self.commit(repo, "main.txt", "main\n")
            result = self.verify(repo, pin)
            self.assertEqual(2, result.returncode, result.stdout)
            self.assertIn("TOPOLOGY_ERROR=PRIVATE_PIN_NOT_ANCESTOR_OF_ALLOWLISTED_MAIN", result.stdout)

    def test_missing_pin_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = self.init_repo(Path(directory))
            self.commit(repo, "base.txt", "base\n")
            result = self.verify(repo, "f" * 40)
            self.assertEqual(2, result.returncode, result.stdout)
            self.assertIn("TOPOLOGY_ERROR=PRIVATE_PIN_MISSING", result.stdout)

    def test_dirty_detached_checkout_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = self.init_repo(Path(directory))
            pin = self.commit(repo, "base.txt", "base\n")
            require_ok(run(["git", "checkout", "--detach", pin], cwd=repo))
            (repo / "dirty.txt").write_text("dirty\n", encoding="utf-8")
            result = self.assert_detached(repo, pin)
            self.assertEqual(2, result.returncode, result.stdout)
            self.assertIn("TOPOLOGY_ERROR=PRIVATE_WORKTREE_DIRTY", result.stdout)

    def test_wrong_detached_head_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = self.init_repo(Path(directory))
            pin = self.commit(repo, "base.txt", "base\n")
            wrong = self.commit(repo, "wrong.txt", "wrong\n")
            require_ok(run(["git", "checkout", "--detach", wrong], cwd=repo))
            result = self.assert_detached(repo, pin)
            self.assertEqual(2, result.returncode, result.stdout)
            self.assertIn("TOPOLOGY_ERROR=DETACHED_SHA_MISMATCH", result.stdout)

    def test_missing_history_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            origin = self.init_repo(root)
            pin = self.commit(origin, "base.txt", "base\n")
            self.commit(origin, "descendant.txt", "descendant\n")
            shallow = root / "shallow"
            require_ok(run(["git", "clone", "--depth", "1", f"file://{origin}", str(shallow)]))
            result = self.verify(shallow, pin)
            self.assertEqual(2, result.returncode, result.stdout)
            self.assertIn("TOPOLOGY_ERROR=PRIVATE_HISTORY_INCOMPLETE", result.stdout)

    def runner_env(self) -> dict[str, str]:
        env = os.environ.copy()
        env.update(
            {
                "GATE_ID": "GFF_WAVE_C_G1_V03_VALIDATION_v01",
                "PRIVATE_REPO": "TheGor-365/generative-film-factory-control-center",
                "PRIVATE_BRANCH": "main",
                "PRIVATE_SHA": PINNED_PRIVATE_SHA,
                "RUNNER_REPO": "TheGor-365/generative-film-factory-actions-runner",
                "RUNNER_SHA": "0" * 40,
                "STATUS_CONTEXT": "public-runner/gff/wave-c-validation",
                "GFF_WAVE_C_WORK_ROOT": str(ROOT / ".topology-test-work"),
            }
        )
        return env

    def assert_override_rejected(self, field: str, value: str, code: str) -> None:
        env = self.runner_env()
        env[field] = value
        result = run(["bash", str(RUNNER), "private-checkout", "initialize"], cwd=ROOT, env=env)
        self.assertEqual(2, result.returncode, result.stdout)
        self.assertIn(f"POLICY_ERROR={code}", result.stdout)

    def test_override_attempts_are_rejected(self) -> None:
        self.assert_override_rejected("PRIVATE_REPO", "attacker/repository", "PRIVATE_REPO_NOT_ALLOWLISTED")
        self.assert_override_rejected("PRIVATE_BRANCH", "attacker-branch", "PRIVATE_BRANCH_NOT_ALLOWLISTED")
        self.assert_override_rejected("PRIVATE_SHA", "a" * 40, "PRIVATE_SHA_NOT_ALLOWLISTED")

    def test_exact_source_sha_propagation_is_centralized(self) -> None:
        lib = (ROOT / "scripts" / "wave_c" / "lib.sh").read_text(encoding="utf-8")
        components = (ROOT / "scripts" / "wave_c" / "components.sh").read_text(encoding="utf-8")
        runtime = (ROOT / "scripts" / "wave_c" / "runtime.sh").read_text(encoding="utf-8")
        self.assertEqual(1, lib.count('"GFF_SOURCE_SHA=$PRIVATE_SHA"'))
        self.assertIn('env -i "${base_env[@]}" "${extra_env[@]}"', lib)
        self.assertNotIn("GFF_SOURCE_SHA=", components)
        self.assertNotIn("GFF_SOURCE_SHA=", runtime)
        self.assertGreater((components + runtime).count("run_private "), 5)

    def test_old_main_equals_pin_assertion_is_absent(self) -> None:
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
        source = "\n".join(path.read_text(encoding="utf-8") for path in production_paths)
        self.assertNotIn("PRIVATE_MAIN_SHA_MISMATCH", source)
        self.assertNotIn("PRIVATE_MAIN_SHA_MATCH", source)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(GitTopologyTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.wasSuccessful():
        print("PIN_EXISTS_CHECK=PASS")
        print("PIN_ANCESTOR_OF_ALLOWLISTED_MAIN=PASS")
        print("EXACT_DETACH_AND_CLEAN_CHECK=PASS")
        print("MAIN_EQUALS_PIN_FIXTURE=PASS")
        print("DESCENDANT_MAIN_FIXTURE=PASS")
        print("DIVERGED_MAIN_FIXTURE=PASS_REJECTED")
        print("MISSING_PIN_FIXTURE=PASS_REJECTED")
        print("DIRTY_CHECKOUT_FIXTURE=PASS_REJECTED")
        print("WRONG_DETACHED_HEAD_FIXTURE=PASS_REJECTED")
        print("MISSING_HISTORY_FIXTURE=PASS_REJECTED")
        print("OVERRIDE_ATTEMPTS=PASS_REJECTED")
        print("SOURCE_SHA_PROPAGATION=PASS")
        print("OLD_EQUALITY_ASSERTION_PRESENT=false")
        print("NO_FAKE_GREEN=true")
    raise SystemExit(0 if result.wasSuccessful() else 1)
