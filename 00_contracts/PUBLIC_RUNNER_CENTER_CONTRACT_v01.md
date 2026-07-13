# PUBLIC RUNNER CENTER CONTRACT v01

```text
CONTRACT_ID=PUBLIC_RUNNER_CENTER_CONTRACT_v01
WORK_ORDER_ID=RWO-PUBLIC-RUNNER-BOOTSTRAP-001
PUBLIC_RUNNER_REPO=TheGor-365/generative-film-factory-actions-runner
PRIVATE_CONTROL_CENTER_REPO=TheGor-365/generative-film-factory-control-center
WORKFLOW_NAME=Run Private Validator
TRIGGER=workflow_dispatch_only
GLOBAL_PERMISSIONS=contents:read
VALIDATION_JOB=validate-private-sha
WRITEBACK_JOB=writeback-result
PUBLIC_JOB_ID=validate-private-sha
GATE_ID=CONTROL_CENTER_READONLY_VALIDATION_v02
PUBLIC_ARTIFACTS=none
CACHE=none
ACCESS_CONFIGURATION_AUTHORIZED=false
RUN_AUTHORIZED=false
MERGE_ALLOWED=false
NO_FAKE_GREEN=true
```

## Authority and result vocabulary

The private Control Center remains the source of truth. This public repository may produce execution evidence for an exact private SHA; it cannot change research truth, coordination truth, architecture authority, release state, client acceptance, or production state.

The exact result vocabulary is:

```text
PASS=allowlisted validator commands returned zero for the exact private SHA
FAIL=allowlisted validator commands executed and returned nonzero
ERROR=policy access checkout dispatch runner or infrastructure failure
BLOCKED=required authorization or access is unavailable
```

Both writeback scripts accept exactly `PASS|FAIL|ERROR|BLOCKED`. Commit-status mapping is exact:

```text
PASS=success
FAIL=failure
ERROR=error
BLOCKED=error
```

An unknown result produces `NO_WRITE=true` and `STABLE_POLICY_ERROR=true`; it is not silently converted into a publishable result. PASS is not research, critic, human, legal, artistic, client, production, or release acceptance.

## Workflow boundary

The sole workflow is `.github/workflows/run-private-validator.yml` and has these constraints:

- manual `workflow_dispatch` only;
- global `contents: read` permission only;
- GitHub-hosted Linux runners only;
- validation job identifier `validate-private-sha` and writeback job identifier `writeback-result`;
- no environments, deployments, releases, packages, matrices, caches, or artifact uploads;
- no arbitrary shell, command, path, URL, repository, gate, status context, or artifact-name input;
- no execution from pull requests, forks, schedules, repository dispatches, issue comments, pushes, or workflow chaining;
- no secret values in Git, logs, status descriptions, or PR comments;
- no private repository archive or private content in public artifacts.

Official action pins remain:

```text
actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065
```

Every checkout sets `persist-credentials: false`.

## Structured bootstrap inputs

The workflow accepts only:

```text
private_repo=TheGor-365/generative-film-factory-control-center
private_branch=main
private_sha=<40-character lowercase hexadecimal SHA>
gate_id=CONTROL_CENTER_READONLY_VALIDATION_v02
status_context=public-runner/control-center/readonly-validation
write_status=true|false
write_pr_comment=false
private_pr=<positive integer or empty>
```

Repository, branch, gate, and status context are choice-restricted and validated again before checkout. The current allowlist validates private `main`, so bootstrap dispatch policy requires `write_pr_comment=false`. PR-comment writeback capability is statically implemented but is not claimed as runtime-tested in this bootstrap phase.

## Exact-SHA checkout and cleanup

The validation job:

1. checks out this public runner with credentials disabled;
2. validates all structured inputs;
3. checks out the allowlisted private branch with `PRIVATE_REPO_READ_TOKEN` and `persist-credentials: false`;
4. proves the resolved branch head equals `private_sha`;
5. switches the private checkout to detached HEAD at that exact SHA;
6. invokes only `scripts/run_allowlisted_gate.sh`;
7. runs an `if: always()` cleanup step that executes `rm -rf -- private-checkout` without listing or printing private paths or content;
8. emits compact result metadata without caches, artifacts, debug dumps, or uploads.

Cleanup runs after validator success, validator failure, and policy failure whenever the job reaches the checkout or execution phase. Any branch/SHA mismatch is a policy error and stops validation.

## Gate execution

The allowlist is `00_contracts/GATE_ALLOWLIST_v01.json`. The shell runner contains a fixed case for the single gate and does not execute command text from JSON or workflow input.

`scripts/run_allowlisted_gate.sh` uses `set -euo pipefail`. Validator and test exit codes are preserved only through explicit `if command; then status=0; else status=$?; fi` blocks. It does not use `set +e`, `eval`, or `bash -c`/`sh -c` with input-provided command text.

Fixed commands:

```text
PYTHONDONTWRITEBYTECODE=1 python scripts/validate_control_center.py
PYTHONDONTWRITEBYTECODE=1 python -m unittest tests/test_validate_control_center.py
```

## Writeback credential and evidence boundary

The validation job never receives a write token. The only write-secret name is:

```text
PRIVATE_REPO_WRITE_TOKEN
```

It is referenced only inside `writeback-result` and is supplied to the two bounded writeback scripts as `PRIVATE_REPO_API_TOKEN`. Its value is configured outside Git and is not configured by this implementation repair.

Both writeback scripts require and strictly validate:

```text
PUBLIC_RUN_ID=<numeric GitHub Actions run id>
PUBLIC_JOB_ID=validate-private-sha
```

No additional GitHub Actions API lookup is used to derive the job identifier. Compact status and PR evidence include the stable job identifier together with the public run identifier.

`write_private_pr_comment.sh` performs no comment POST until it:

1. validates `PRIVATE_PR` as a positive integer;
2. performs a GET only to `https://api.github.com/repos/${PRIVATE_REPO}/pulls/${PRIVATE_PR}` for PR verification;
3. verifies the response is a pull-request object with the requested number and a string `pull_request.head.sha` equivalent at JSON path `head.sha`;
4. verifies `pull_request.head.sha == PRIVATE_SHA` exactly.

A lookup failure, invalid PR response, or head/SHA mismatch produces a stable policy error and no comment POST. The `/issues/${PRIVATE_PR}/comments` endpoint is used only after successful PR verification to create the comment; it is not used to prove that the target is a pull request.

Writeback metadata is compact and contains only public run/job identity, private repository identifier, branch, exact SHA, gate and validator-set identifiers, exact result, exit code, status context, `PUBLIC_ARTIFACT_COUNT=0`, and `PRIVATE_CONTENT_PUBLIC_EXPOSURE=false`. Writeback never modifies private files or branches.

## Authorization state

Repository files define capability but do not authorize use. Until separate commands are issued:

```text
ACCESS_CONFIGURATION_AUTHORIZED=false
RUN_AUTHORIZED=false
MERGE_ALLOWED=false
```
