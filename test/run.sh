#!/usr/bin/env bash
# ============================================================================
# attackbox-ansible test harness
# ----------------------------------------------------------------------------
# Spin up disposable Kali and/or Parrot containers, run the playbook against
# them (via Ansible's docker connection — no SSH), then assert the result with
# test/verify.yml. Everything runs INSIDE the containers; the host only runs
# the ansible control process.
#
#   test/run.sh [kali|parrot|all] [smoke|full]
#
#   smoke (default) : skips heavy builds (metasploit, hashcat, john, empire install)
#   full            : runs everything (slow; large downloads + compiles)
#
#   KEEP=1 test/run.sh ...   # leave containers running afterward for debugging
#
# gocryptfs needs FUSE, which needs these container privileges (validated on
# GitHub Actions ubuntu runners too).
# ============================================================================
set -euo pipefail

DISTRO="${1:-all}"
MODE="${2:-smoke}"
KEEP="${KEEP:-0}"

declare -A IMAGES=(
  [kali]=kalilinux/kali-rolling
  [parrot]=parrotsec/security
  [debian]=debian:stable
  [ubuntu]=ubuntu:24.04
)

FUSE_FLAGS=(
  --cap-add SYS_ADMIN
  --device /dev/fuse
  --security-opt apparmor=unconfined
  --security-opt seccomp=unconfined
)

case "$DISTRO" in
  kali)   TARGETS=(kali) ;;
  parrot) TARGETS=(parrot) ;;
  debian) TARGETS=(debian) ;;
  ubuntu) TARGETS=(ubuntu) ;;
  all)    TARGETS=(kali parrot debian ubuntu) ;;
  *) echo "usage: $0 [kali|parrot|debian|ubuntu|all] [smoke|full]" >&2; exit 2 ;;
esac

SKIP_TAGS=()
VERIFY_HEAVY=false
if [ "$MODE" = "smoke" ]; then
  SKIP_TAGS=(--skip-tags heavy)
elif [ "$MODE" = "full" ]; then
  VERIFY_HEAVY=true
else
  echo "usage: $0 [kali|parrot|debian|ubuntu|all] [smoke|full]" >&2; exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LIMIT=""
for d in "${TARGETS[@]}"; do LIMIT+="attackbox-test-$d,"; done

cleanup() {
  [ "$KEEP" = "1" ] && { echo "KEEP=1 — leaving containers up"; return; }
  for d in "${TARGETS[@]}"; do docker rm -f "attackbox-test-$d" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

echo "== starting containers: ${TARGETS[*]} =="
for d in "${TARGETS[@]}"; do
  name="attackbox-test-$d"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" "${FUSE_FLAGS[@]}" "${IMAGES[$d]}" sleep infinity >/dev/null
  echo "  started $name (${IMAGES[$d]})"
done

echo "== ensuring ansible collections =="
ansible-galaxy collection install -r requirements.yml >/dev/null 2>&1 || \
  echo "  (galaxy install skipped/failed — assuming collections already present)"

echo "== provisioning [$MODE] =="
ansible-playbook -i test/inventory.docker.ini playbook.yml --limit "$LIMIT" "${SKIP_TAGS[@]}"

echo "== verifying [$MODE] =="
ansible-playbook -i test/inventory.docker.ini test/verify.yml --limit "$LIMIT" \
  -e "verify_heavy=$VERIFY_HEAVY"

echo "== PASS ($MODE): ${TARGETS[*]} =="
