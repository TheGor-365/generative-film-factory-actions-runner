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

## Initial gate

The bootstrap implementation contains one fixed gate:

```text
GATE_ID=CONTROL_CENTER_READONLY_VALIDATION_v02
VALIDATOR_SET=control_center_readonly_v02
STATUS_CONTEXT=public-runner/control-center/readonly-validation
```

The gate validates one exact private `main` commit after proving that the requested branch head equals the requested 40-character SHA. Commands are resolved from repository-controlled allowlist code; workflow inputs cannot supply shell commands, paths, URLs, environment assignments, or artifact names.

## Security boundary

- The private repository remains authoritative.
- Private access is configured outside Git only after separate authorization.
- Checkout credentials are not persisted.
- Full private files, repository archives, research bodies, client content, provider payloads, and media must not be emitted or uploaded.
- No cache, artifact upload, deployment, release, package publishing, self-hosted runner, or production orchestration is included.
- Runner PASS applies only to the named gate and exact private SHA. It is not research, critic, human, legal, artistic, client, production, or release acceptance.

## Current phase

Implementation is submitted through a draft pull request for static and security review. Access configuration, workflow dispatch, and merge remain prohibited until separately authorized by the master coordinator.
