# Generative Film Factory Actions Runner

Public, execution-only validation bridge for the private Generative Film Factory Control Center.

```text
REPOSITORY_ROLE=EXECUTION_ONLY_TEXT_AND_METADATA_VALIDATION_MACHINE_SHOP
SOURCE_OF_TRUTH=false
PRIVATE_CONTROL_CENTER=TheGor-365/generative-film-factory-control-center
ALLOWLISTED_GATES_ONLY=true
ARBITRARY_SHELL_ALLOWED=false
PUBLIC_ARTIFACTS=none
PRIVATE_CONTENT_STORAGE=false
AUDIO_VIDEO_EXECUTION_ALLOWED=false
ACCESS_CONFIGURATION_AUTHORIZED=false
RUN_AUTHORIZED=false
MERGE_ALLOWED=false
```

## Allowlisted gates

### Control Center readonly gate

```text
GATE_ID=CONTROL_CENTER_READONLY_VALIDATION_v02
ALLOWED_BRANCH=main
VALIDATOR_SET=control_center_readonly_v02
STATUS_CONTEXT=public-runner/control-center/readonly-validation
```

This gate validates one exact private `main` commit after proving that the requested branch head equals the requested 40-character SHA.

### FMR-005 Repair 004 gate

```text
GATE_ID=FMR005_REPAIR004_VALIDATION_v01
ALLOWED_BRANCH=worker/fmr005-repair-004
PRIVATE_PR=137
VALIDATOR_SET=fmr005_repair004_v01
STATUS_CONTEXT=public-runner/fmr005/repair004-validation
EXPECTED_CHANGED_PATH_COUNT=16
MINIMUM_UNIT_TEST_COUNT_EXCLUSIVE=58
```

This gate validates the exact staged Repair 004 branch. It checks the exact sixteen-path scope against private `main`, runs the Control Center validator, runs the FMR-005 repair validator, runs complete unit-test discovery, requires more than 58 tests, and runs `git diff --check`.

Commands and changed paths are resolved from repository-controlled code and the machine-readable allowlist. Workflow inputs cannot provide shell commands, paths, URLs, environment assignments, artifact names, or alternate repositories.

## Security boundary

- The private repository remains authoritative.
- Private access is configured outside Git only after separate authorization.
- Checkout credentials are not persisted.
- Full private files, repository archives, research bodies, client content, provider payloads, and media must not be emitted or uploaded.
- No cache action, artifact upload, deployment, release, package publishing, self-hosted runner, or production orchestration is included.
- Runner `PASS` applies only to the named gate and exact private SHA. It is not research, critic, human, legal, artistic, client, production, or release acceptance.
- A gate `ERROR` or infrastructure failure is not a content `FAIL`.

## Current phase

The FMR-005 Repair 004 gate is submitted for exact-head static and security review. Secret configuration, workflow dispatch, private writeback, and runner-result acceptance remain prohibited until separately authorized by the master coordinator.

## Wave C exact Actions evidence gate

```text
WORK_ORDER_ID=RWO-GFF-WAVE-C-CONVERGENCE-ACTIONS-GATE-REPAIR-001
GATE_ID=GFF_WAVE_C_G1_V03_VALIDATION_v01
WORKFLOW=.github/workflows/run-wave-c-exact-evidence.yml
CONTRACT=contracts/GFF_WAVE_C_G1_V03_VALIDATION_v01.json
RUNNER=scripts/run_wave_c_exact_gate.sh
EVIDENCE_HELPER=scripts/wave_c/evidence_contract.py
COMPATIBILITY_FIXTURE=scripts/wave_c/test_gate_contract.py
PRIVATE_REPOSITORY=TheGor-365/generative-film-factory-control-center
ALLOWED_BRANCH=main
STATUS_CONTEXT=public-runner/gff/wave-c-validation
WORKFLOW_INPUTS=private_sha_only
```

The repaired workflow exposes stable Actions step IDs for exact checkout, Ruby/toolchain preflight, all five component matrices, source validation, doctor, two independent deterministic pilots and verifies, aggregate release-check, canonical v03 execution, runtime evidence emission and cleanup.

The component result is emitted in two additive forms:

```text
factory_component_test_summary_v01
factory_component_matrix_summary_v02
```

The legacy summary remains the input to the two-run aggregate. The v02 matrix is bound to the exact private SHA and contains the five component outcomes, command IDs, command outcomes, exit codes, command evidence hashes, component hashes and a canonical `summary_sha256`.

The gate emits `factory_actions_evidence_runtime_v01`, containing every non-API field required to reconstruct `factory_actions_evidence_bundle_v01`. Numeric workflow/job IDs, run attempt, API step outcomes and final conclusions are added only after completion from authenticated GitHub Actions APIs. They are never invented inside the workflow.

The canonical v03 step accepts no workflow override. The full executable surface is pinned to `59c91f4830dc4738dd537ce79a13ef591e4c96d8`; the executor implementation is `9a4829452cd3947b7ef2913c62d45890b5a31b29`. The step still returns `BLOCKED` when the coordinator-frozen SHA does not contain the pinned CLI commit. The fixed command is:

```text
factory wave-c-v03-cycle --source-sha <exact-private-sha>
```

The runner does not probe CLI usage or invoke the nonexistent top-level `factory wave-c-v03` command. The private CLI exposes `wave-c-v03-cycle --source-sha <exact-sha>` at `59c91f4830dc4738dd537ce79a13ef591e4c96d8`; no command discovery or workflow override is permitted.

```text
PASS=all fixed checks and canonical v03 executor completed successfully
FAIL=executed content or deterministic validation returned nonzero
ERROR=runner checkout token toolchain timeout or infrastructure failure
BLOCKED=required source-controlled command input or evidence is absent
ARBITRARY_SHELL_INPUT=false
ARBITRARY_PATH_INPUT=false
PUBLIC_ARTIFACT_UPLOAD=false
AUDIO_VIDEO_ARTIFACT_UPLOAD=false
PRIVATE_SOURCE_LOGGING=false
PRIVATE_MEDIA_LOGGING=false
NETWORK_MEDIA_PROVIDER_CALLS=false
PAID_PROVIDER_CALLS=false
CACHE_ACTION_PRESENT=false
CLEANUP_ALWAYS=true
```

The `cleanup` step always deletes the private checkout and all runtime, artifact, report and evidence roots. It emits compact deletion flags and proves that no upload or cache action is present.

Source preparation does not authorize merge, ready-for-review transition or workflow dispatch. Final execution remains blocked until the coordinator freezes `WAVE_C_INTEGRATION_HEAD=<exact 40-character private main SHA>`.
