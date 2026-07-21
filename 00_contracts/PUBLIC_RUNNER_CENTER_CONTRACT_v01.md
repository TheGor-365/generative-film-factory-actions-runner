# PUBLIC RUNNER CENTER CONTRACT v01

```text
CONTRACT_ID=PUBLIC_RUNNER_CENTER_CONTRACT_v01
INITIAL_WORK_ORDER_ID=RWO-PUBLIC-RUNNER-BOOTSTRAP-001
CURRENT_RECOVERY_ID=RWO-PUBLIC-RUNNER-FMR005-REPAIR004-GATE-001
PUBLIC_RUNNER_REPO=TheGor-365/generative-film-factory-actions-runner
PRIVATE_CONTROL_CENTER_REPO=TheGor-365/generative-film-factory-control-center
WORKFLOW_NAME=Run Private Validator
TRIGGER=workflow_dispatch_only
GLOBAL_PERMISSIONS=contents:read
VALIDATION_JOB=validate-private-sha
WRITEBACK_JOB=writeback-result
PUBLIC_JOB_ID=validate-private-sha
PUBLIC_ARTIFACTS=none
CACHE=none
ACCESS_CONFIGURATION_AUTHORIZED=false
RUN_AUTHORIZED=false
PRIVATE_WRITEBACK_AUTHORIZED=false
NO_FAKE_GREEN=true
```

## Authority and result vocabulary

The private Control Center remains the source of truth. This public repository may produce execution evidence for an exact private SHA; it cannot change research truth, coordination truth, architecture authority, release state, client acceptance, or production state.

```text
PASS=allowlisted validator commands returned zero for the exact private SHA
FAIL=allowlisted validator commands executed and returned nonzero
ERROR=policy access checkout dispatch runner or infrastructure failure
BLOCKED=required authorization or access is unavailable
```

An unknown result produces no accepted evidence. `PASS` is not research, critic, human, legal, artistic, client, production, or release acceptance. `ERROR` is not content `FAIL`.

## Workflow boundary

The sole workflow is `.github/workflows/run-private-validator.yml` and has these constraints:

- manual `workflow_dispatch` only;
- global `contents: read` permission only;
- GitHub-hosted Linux runners only;
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

## Allowlisted dispatch tuples

### Control Center readonly validation

```text
private_repo=TheGor-365/generative-film-factory-control-center
private_branch=main
private_sha=<exact 40-character lowercase SHA>
gate_id=CONTROL_CENTER_READONLY_VALIDATION_v02
status_context=public-runner/control-center/readonly-validation
write_pr_comment=false
```

Fixed commands:

```text
PYTHONDONTWRITEBYTECODE=1 python scripts/validate_control_center.py
PYTHONDONTWRITEBYTECODE=1 python -m unittest tests/test_validate_control_center.py
```

### FMR-005 Repair 004 validation

```text
private_repo=TheGor-365/generative-film-factory-control-center
private_branch=worker/fmr005-repair-004
private_sha=a10449add891b4cf6da48b98d17d638f4eafceb8
private_pr=137
gate_id=FMR005_REPAIR004_VALIDATION_v01
status_context=public-runner/fmr005/repair004-validation
write_status=false
write_pr_comment=false
```

The workflow validates the exact tuple again before checkout. The runner code then validates the matching machine-readable gate record and does not execute command text supplied by JSON or workflow input.

Fixed Repair 004 checks:

```text
1 exact changed-path set equals the sixteen paths in GATE_ALLOWLIST_v01.json
2 git diff --check origin/main...HEAD
3 PYTHONDONTWRITEBYTECODE=1 python scripts/validate_control_center.py
4 PYTHONDONTWRITEBYTECODE=1 python scripts/validate_fmr005_repair.py --repo-root .
5 PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s tests -p test_*.py
6 observed unit-test count must be greater than 58
```

The Repair 004 gate is not a general branch validator. It accepts only PR `137`, branch `worker/fmr005-repair-004`, the named status context, and the exact gate ID.

## Exact-SHA checkout and cleanup

The validation job:

1. checks out this public runner with credentials disabled;
2. validates all structured inputs;
3. checks out the allowlisted private branch using `PRIVATE_REPO_READ_TOKEN`, full history, and `persist-credentials: false`;
4. proves the resolved branch head equals `private_sha`;
5. switches the private checkout to detached HEAD at that exact SHA;
6. invokes only `scripts/run_allowlisted_gate.sh`;
7. performs cleanup with `rm -rf -- private-checkout` under `if: always()`;
8. emits compact result metadata without caches, artifacts, debug dumps, or uploads.

The full-history checkout is required only so the Repair 004 gate can resolve `origin/main`, calculate the merge-base diff, and prove the exact sixteen-path scope. A missing `origin/main` produces a policy `ERROR`, not a fabricated validation result.

## Log and evidence boundary

Allowed public output is limited to:

```text
repository identifier
branch identifier
exact SHA
gate and validator-set identifiers
file counts
stable policy and validation result codes
unit-test count
failed test names
exit codes
public run identity
short summary
```

Forbidden public output includes:

```text
full private files
research document bodies
private repository archives
client inputs
provider payloads
credentials
private artifact URLs
rendered media
```

Validator and unittest command output is captured in temporary files. The runner emits only compact statuses, counts, and failed test names, then removes the temporary files. No workflow artifacts are uploaded.

## Gate implementation boundary

The allowlist is `00_contracts/GATE_ALLOWLIST_v01.json`. `scripts/run_allowlisted_gate.sh` contains fixed cases for the two gates. It does not use `eval`, input-provided commands, arbitrary paths, or command text from JSON.

The Repair 004 gate compares the observed `origin/main...HEAD` changed-path set to the exact allowlisted sixteen-path set. It also performs a whitespace check on the same merge-base range. A new private branch commit invalidates earlier evidence.

## Credential boundary

The validation job may receive only:

```text
PRIVATE_REPO_READ_TOKEN
```

for read-only checkout of the private Control Center. The token value is configured outside Git, is not persisted by checkout, and must not be printed.

The separate writeback job references `PRIVATE_REPO_WRITE_TOKEN`, but Repair 004 dispatch policy requires both `write_status=false` and `write_pr_comment=false`. Therefore no private write token is required or authorized for this recovery gate.

## Authorization state

Repository files define capability but do not authorize use. Until separate master commands are issued:

```text
ACCESS_CONFIGURATION_AUTHORIZED=false
WORKFLOW_DISPATCH_AUTHORIZED=false
PRIVATE_WRITEBACK_AUTHORIZED=false
RUNNER_RESULT_ACCEPTANCE_AUTHORIZED=false
```

Static review and merge of the five-file public-runner implementation do not by themselves authorize secret creation or workflow dispatch.