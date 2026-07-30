#!/usr/bin/env bash
set -uo pipefail

topology_error() {
  printf '%s\n' \
    "TOPOLOGY_ERROR=$1" \
    "RESULT=ERROR" \
    "EXIT_CODE=2" \
    "NO_FAKE_GREEN=true"
  return 2
}

assert_detached_private_state() {
  local checkout=$1
  local pin=$2
  local detached_head
  detached_head=$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)
  if [[ "$detached_head" != "$pin" ]]; then
    topology_error "DETACHED_SHA_MISMATCH"
    return $?
  fi
  printf '%s\n' "DETACHED_PRIVATE_SHA_MATCH=true"

  local symbolic_head
  symbolic_head=$(git -C "$checkout" symbolic-ref -q HEAD 2>/dev/null || true)
  if [[ -n "$symbolic_head" ]]; then
    topology_error "PRIVATE_HEAD_NOT_DETACHED"
    return $?
  fi

  local worktree_status
  worktree_status=$(git -C "$checkout" status --porcelain --untracked-files=normal 2>/dev/null || true)
  if [[ -n "$worktree_status" ]]; then
    topology_error "PRIVATE_WORKTREE_DIRTY"
    return $?
  fi
  printf '%s\n' "PRIVATE_WORKTREE_CLEAN=true"
}

verify_private_checkout_topology() {
  local checkout=$1
  local pin=$2

  if [[ ! -d "$checkout/.git" ]]; then
    topology_error "PRIVATE_CHECKOUT_MISSING"
    return $?
  fi

  local observed_main
  observed_main=$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)
  if [[ ! "$observed_main" =~ ^[0-9a-f]{40}$ ]]; then
    topology_error "PRIVATE_MAIN_HEAD_INVALID"
    return $?
  fi
  printf '%s\n' "PRIVATE_MAIN_HEAD_OBSERVED=$observed_main"

  local shallow
  shallow=$(git -C "$checkout" rev-parse --is-shallow-repository 2>/dev/null || true)
  if [[ "$shallow" != "false" ]]; then
    topology_error "PRIVATE_HISTORY_INCOMPLETE"
    return $?
  fi
  printf '%s\n' "PRIVATE_FULL_HISTORY=true"

  if ! git -C "$checkout" cat-file -e "$pin^{commit}" 2>/dev/null; then
    topology_error "PRIVATE_PIN_MISSING"
    return $?
  fi
  printf '%s\n' "PRIVATE_PIN_EXISTS=true"

  if ! git -C "$checkout" merge-base --is-ancestor "$pin" "$observed_main" >/dev/null 2>&1; then
    topology_error "PRIVATE_PIN_NOT_ANCESTOR_OF_ALLOWLISTED_MAIN"
    return $?
  fi
  printf '%s\n' "PRIVATE_PIN_ANCESTOR_OF_ALLOWLISTED_MAIN=true"

  if ! git -C "$checkout" checkout --detach --quiet "$pin" >/dev/null 2>&1; then
    topology_error "PRIVATE_DETACH_FAILED"
    return $?
  fi

  assert_detached_private_state "$checkout" "$pin"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ $# -ne 2 ]]; then
    topology_error "INVALID_TOPOLOGY_ARGUMENT_COUNT"
    exit $?
  fi
  verify_private_checkout_topology "$1" "$2"
fi
