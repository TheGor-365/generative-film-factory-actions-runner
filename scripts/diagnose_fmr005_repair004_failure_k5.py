import base64
import os
import re
import subprocess
import sys
from pathlib import Path

root = Path("private-checkout")
expected_sha = "a10449add891b4cf6da48b98d17d638f4eafceb8"
private_repo_url = "https://github.com/TheGor-365/generative-film-factory-control-center"
expected_paths = {
    "04_research/FMR-005/normalized/01_RESEARCH_REPORT.md",
    "04_research/FMR-005/normalized/08_VALIDATOR_CANDIDATES.json",
    "04_research/FMR-005/normalized/10_IMPLEMENTATION_HANDOFF.md",
    "04_research/FMR-005/normalized/MANIFEST.json",
    "04_research/FMR-005/normalized/PACKAGE_VALIDATION_REPORT.json",
    "04_research/FMR-005/repair_004/01_REPAIR_REPORT.md",
    "04_research/FMR-005/repair_004/02_FINDING_DISPOSITION.json",
    "04_research/FMR-005/repair_004/03_VALIDATION_REPORT.json",
    "04_research/FMR-005/repair_004/MANIFEST.json",
    "scripts/validate_fmr005_repair.py",
    "tests/fixtures/fmr005_repair/invalid_package_validation_report_drift.json",
    "tests/fixtures/fmr005_repair/invalid_report_assertion_count_drift.json",
    "tests/fixtures/fmr005_repair/invalid_report_claim_count_drift.json",
    "tests/fixtures/fmr005_repair/invalid_report_status_drift.json",
    "tests/fixtures/fmr005_repair/valid_report_consistency_control.json",
    "tests/test_validate_fmr005_repair.py",
}
prefixes = (
    "FAILURE_CODE=",
    "POLICY_ERROR=",
    "VALIDATION_ERROR=",
    "MANIFEST_ERROR=",
    "REPORT_ERROR=",
    "PACKAGE_ERROR=",
)


def invoke(
    args: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=cwd,
        env=env,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        check=False,
    )


def run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return invoke(args, cwd=root)


def emit_codes(text: str) -> None:
    for line in text.splitlines():
        if line.startswith(prefixes):
            print(line[:500])


print("DIAGNOSTIC_MODE=SANITIZED_FAILURE_METADATA_ONLY")
print("PRIVATE_FILE_BODIES_PRINTED=false")
print("PUBLIC_ARTIFACT_COUNT=0")
print("PRIVATE_CONTENT_PUBLIC_EXPOSURE=false")
print("VERIFIED_READ_SECRET_REUSED=true")

read_token = os.environ.get("PRIVATE_REPO_READ_TOKEN", "")
if not read_token:
    print("RUNNER_INFRASTRUCTURE=FAIL")
    print("FAILURE_CODE=PRIVATE_REPO_READ_TOKEN_MISSING")
    raise SystemExit(1)

root.mkdir(parents=True, exist_ok=False)
init = invoke(["git", "init", "-q", str(root)])
if init.returncode != 0:
    print("RUNNER_INFRASTRUCTURE=FAIL")
    print("FAILURE_CODE=PRIVATE_CHECKOUT_INIT_FAILED")
    raise SystemExit(1)
remote = invoke(["git", "-C", str(root), "remote", "add", "origin", private_repo_url])
if remote.returncode != 0:
    print("RUNNER_INFRASTRUCTURE=FAIL")
    print("FAILURE_CODE=PRIVATE_REMOTE_ADD_FAILED")
    raise SystemExit(1)

basic = base64.b64encode(f"x-access-token:{read_token}".encode("utf-8")).decode("ascii")
git_env = os.environ.copy()
git_env.update(
    {
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "http.https://github.com/.extraheader",
        "GIT_CONFIG_VALUE_0": f"AUTHORIZATION: basic {basic}",
    }
)
fetch = invoke(
    [
        "git",
        "-C",
        str(root),
        "fetch",
        "--quiet",
        "--no-tags",
        "--depth=1",
        "origin",
        "+refs/heads/worker/fmr005-repair-004:refs/remotes/origin/worker/fmr005-repair-004",
        "+refs/heads/main:refs/remotes/origin/main",
    ],
    env=git_env,
)
if fetch.returncode != 0:
    print("RUNNER_INFRASTRUCTURE=FAIL")
    print("FAILURE_CODE=PRIVATE_EXACT_REFS_FETCH_FAILED")
    raise SystemExit(1)
checkout = invoke(["git", "-C", str(root), "checkout", "--quiet", "--detach", expected_sha])
if checkout.returncode != 0:
    print("RUNNER_INFRASTRUCTURE=FAIL")
    print("FAILURE_CODE=PRIVATE_EXACT_SHA_CHECKOUT_FAILED")
    raise SystemExit(1)

actual_sha = run(["git", "rev-parse", "HEAD"]).stdout.strip()
print(f"EXPECTED_PRIVATE_SHA={expected_sha}")
print(f"ACTUAL_PRIVATE_SHA={actual_sha}")
if actual_sha != expected_sha:
    print("EXACT_PRIVATE_SHA_BINDING=FAIL")
    print("RUNNER_POLICY=FAIL")
    print("RUNNER_INFRASTRUCTURE=PASS")
    print("FAILURE_CODE=PRIVATE_BRANCH_SHA_MISMATCH")
    raise SystemExit(1)

print("EXACT_PRIVATE_SHA_BINDING=PASS")
print("RUNNER_INFRASTRUCTURE=PASS")
print(f"PYTHON_VERSION={sys.version.split()[0]}")
overall = 0

scope = run(["git", "diff", "--name-only", "origin/main...HEAD"])
observed = {line for line in scope.stdout.splitlines() if line}
scope_pass = scope.returncode == 0 and observed == expected_paths
print(f"EXPECTED_CHANGED_PATH_COUNT={len(expected_paths)}")
print(f"OBSERVED_CHANGED_PATH_COUNT={len(observed)}")
print(f"MISSING_CHANGED_PATH_COUNT={len(expected_paths - observed)}")
print(f"UNAUTHORIZED_CHANGED_PATH_COUNT={len(observed - expected_paths)}")
print("EXACT_CHANGED_PATH_SCOPE=" + ("PASS" if scope_pass else "FAIL"))
overall |= 0 if scope_pass else 1

diff = run(["git", "diff", "--check", "origin/main...HEAD"])
diff_pass = diff.returncode == 0
print("GIT_DIFF_CHECK=" + ("PASS" if diff_pass else "FAIL"))
overall |= 0 if diff_pass else 1

components = [
    ("CONTROL_CENTER_VALIDATOR", ["python", "scripts/validate_control_center.py"]),
    (
        "FMR005_REPAIR_VALIDATOR",
        ["python", "scripts/validate_fmr005_repair.py", "--repo-root", "."],
    ),
]
for label, command in components:
    result = run(command)
    print(f"{label}_EXIT_CODE={result.returncode}")
    emit_codes(result.stdout)
    emit_codes(result.stderr)
    passed = result.returncode == 0
    print(f"{label}=" + ("PASS" if passed else "FAIL"))
    overall |= 0 if passed else 1

unit = run(["python", "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py"])
unit_text = unit.stdout + "\n" + unit.stderr
matches = re.findall(r"Ran\s+(\d+)\s+tests?", unit_text)
count = int(matches[-1]) if matches else None
failed = sorted(
    set(re.findall(r"^(?:FAIL|ERROR):\s+([^\s]+)", unit_text, flags=re.MULTILINE))
)
discovery_pass = unit.returncode == 0 and count is not None
threshold_pass = count is not None and count > 58
print("FULL_UNITTEST_DISCOVERY=" + ("PASS" if discovery_pass else "FAIL"))
print("UNIT_TEST_COUNT_OBSERVED=" + ("true" if count is not None else "false"))
print(f"UNIT_TEST_COUNT={count if count is not None else 0}")
print("UNIT_TEST_COUNT_GREATER_THAN_58=" + ("true" if threshold_pass else "false"))
print(f"FAILED_TEST_NAME_COUNT={len(failed)}")
for name in failed:
    print(f"FAILED_TEST={name}")
print("MUTATION_CHECKS_COUPLED_TO_FULL_UNITTEST=true")
print("MUTATION_CHECKS=" + ("PASS" if discovery_pass and threshold_pass else "FAIL"))
overall |= 0 if discovery_pass and threshold_pass else 1

print("RUNNER_POLICY=" + ("PASS" if scope_pass else "FAIL"))
print("DIAGNOSTIC_GATE_RESULT=" + ("PASS" if overall == 0 else "FAIL"))
raise SystemExit(0 if overall == 0 else 1)
