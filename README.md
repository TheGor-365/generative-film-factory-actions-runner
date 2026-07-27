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
- No cache, artifact upload, deployment, release, package publishing, self-hosted runner, or production orchestration is included.
- Runner `PASS` applies only to the named gate and exact private SHA. It is not research, critic, human, legal, artistic, client, production, or release acceptance.
- A gate `ERROR` or infrastructure failure is not a content `FAIL`.

## Current phase

The FMR-005 Repair 004 gate is submitted for exact-head static and security review. Secret configuration, workflow dispatch, private writeback, and runner-result acceptance remain prohibited until separately authorized by the master coordinator.

## Wave C exact Actions evidence gate

```text
WORK_ORDER_ID=RWO-GFF-WAVE-C-ACTIONS-EVIDENCE-001
GATE_ID=GFF_WAVE_C_G1_V03_VALIDATION_v01
WORKFLOW=.github/workflows/run-wave-c-exact-evidence.yml
CONTRACT=contracts/GFF_WAVE_C_G1_V03_VALIDATION_v01.json
RUNNER=scripts/run_wave_c_exact_gate.sh
RUNNER_MODULES=scripts/wave_c/*.sh
PRIVATE_REPOSITORY=TheGor-365/generative-film-factory-control-center
ALLOWED_BRANCH=main
STATUS_CONTEXT=public-runner/gff/wave-c-validation
WORKFLOW_INPUTS=private_sha_only
```

The Wave C gate proves that private `main` equals the coordinator-frozen exact SHA, detaches that checkout, and runs a fixed source-controlled matrix: Ruby/toolchain preflight; Core, Onboarding/Web, Story, Media and Ops suites; `factory validate-source`; `factory doctor`; clean deterministic Run A and verification; independent clean deterministic Run B and verification; aggregate two-run release-check; and the unique repository-declared Wave C v03 command or stage.

The private commands receive a sanitized allowlisted environment. Provider credentials and GitHub tokens are not forwarded. Deterministic synthetic media may exist only under the ephemeral runner temp root. The workflow contains no cache or upload action and always deletes the private checkout plus every runtime, artifact, report and evidence root.

```text
ARBITRARY_SHELL_INPUT=false
ARBITRARY_PATH_INPUT=false
PUBLIC_ARTIFACT_UPLOAD=false
AUDIO_VIDEO_ARTIFACT_UPLOAD=false
PRIVATE_SOURCE_LOGGING=false
PRIVATE_MEDIA_LOGGING=false
NETWORK_MEDIA_PROVIDER_CALLS=false
PAID_PROVIDER_CALLS=false
CACHE=false
CLEANUP_ALWAYS=true
```

Source preparation does not authorize dispatch. Final execution remains blocked until the coordinator supplies `WAVE_C_INTEGRATION_HEAD=<exact 40-character private main SHA>` after CHAT 1–5 source returns are verified.
