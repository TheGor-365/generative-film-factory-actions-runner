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
GATE_ID=CONTROL_CENTER_READONLY_VALIDATION_v02
PUBLIC_ARTIFACTS=none
CACHE=none
ACCESS_CONFIGURATION_AUTHORIZED=false
RUN_AUTHORIZED=false
MERGE_ALLOWED=false
NO_FAKE_GREEN=true
```

## Authority

The private Control Center remains the source of truth. This public repository may produce execution evidence for an exact private SHA; it cannot change research truth, coordination truth, architecture authority, release state, client acceptance, or production state.

A runner result has narrow semantics:

```text
PASS=allowlisted validator commands returned zero for the exact private SHA
FAIL=allowlisted validator commands executed and returned nonzero
ERROR=policy access checkout dispatch runner or infrastructure failure
BLOCKED=required authorization or access is unavailable
```

PASS is not research, critic, human, legal, artistic, client, production, or release acceptance.

## Workflow boundary

The sole workflow is `.github/workflows/run-private-validator.yml` and has these constraints:

- manual `workflow_dispatch` only;
- global `contents: read` permission only;
- GitHub-hosted Linux runners only;
- no environments, deployments, releases, packages, matrices, caches, or artifact uploads;
- no arbitrary shell, command, path, URL, repository, gate, status context, or artifact-name input;
- no execution from pull requests, forks, schedules, repository dispatches, or workflow chaining;
- no secret values in Git, logs, status descriptions, or PR comments;
- no private repository archive or private content in public artifacts.

## Structured inputs

The workflow accepts only:

```text
private_repo=TheGor-365/generative-film-factory-control-center
private_branch=main
private_sha=<40-character lowercase hexadecimal SHA>
gate_id=CONTROL_CENTER_READONLY_VALIDATION_v02
status_context=public-runner/control-center/readonly-validation
write_status=true|false
write_pr_comment=true|false
private_pr=<positive integer or empty>
```

Repository, branch, gate, and status context are choice-restricted and validated again before checkout. The SHA and optional PR number are syntax-validated before use.

## Exact-SHA checkout

The validation job:

1. checks out this public runner with credentials disabled;
2. validates all structured inputs;
3. checks out the allowlisted private branch with a separately configured minimum-permission read credential;
4. proves the resolved branch head equals `private_sha`;
5. switches the private checkout to detached HEAD at that exact SHA;
6. invokes only `scripts/run_allowlisted_gate.sh`;
7. emits compact result metadata without uploading artifacts.

Any branch/SHA mismatch is a policy error and stops validation.

## Gate execution

The allowlist is `00_contracts/GATE_ALLOWLIST_v01.json`. The shell runner contains a fixed case for the single gate and does not execute command text from JSON or workflow input.

Fixed commands:

```text
PYTHONDONTWRITEBYTECODE=1 python scripts/validate_control_center.py
PYTHONDONTWRITEBYTECODE=1 python -m unittest tests/test_validate_control_center.py
```

## Writeback boundary

`writeback-result` runs only when explicitly requested by boolean workflow inputs. It uses separate externally configured credentials for commit status and PR comment operations. It writes compact metadata only:

- public run identity;
- private repository identifier, branch, and exact SHA;
- gate and validator-set identifiers;
- PASS, FAIL, or ERROR and exit code;
- status context;
- `PUBLIC_ARTIFACT_COUNT=0`;
- `PRIVATE_CONTENT_PUBLIC_EXPOSURE=false`.

It never modifies private files or branches.

## Immutable action pins

```text
actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065
```

Checkout always sets `persist-credentials: false`.

## Authorization state

Repository files define capability but do not authorize use. Until separate commands are issued:

```text
ACCESS_CONFIGURATION_AUTHORIZED=false
RUN_AUTHORIZED=false
MERGE_ALLOWED=false
```
