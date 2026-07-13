#!/usr/bin/env bash
# Opt-in Bitcoin Core 30+ regtest smoke test. Downloads no blockchain data.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=../../lib/upstream.sh
source "${ROOT}/lib/upstream.sh"

[[ "${ALMAPAY_RUN_REGTEST:-0}" == "1" ]] || {
  echo "SKIP regtest-bitcoin (set ALMAPAY_RUN_REGTEST=1)"
  exit 0
}
almapay_refuse_root
command -v podman >/dev/null 2>&1 || almapay_die "podman is required"

export ALMAPAY_LOCKFILE="${ALMAPAY_LOCKFILE:-${ROOT}/upstream.lock}"
image="$(almapay_lock_image_runtime_ref bitcoin_core)"
name="almapay-regtest-bitcoin-$$"
volume="${name}-data"

cleanup() {
  podman rm -f "${name}" >/dev/null 2>&1 || true
  podman volume rm "${volume}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

podman pull "${image}"
podman volume create "${volume}" >/dev/null
podman run -d --name "${name}" \
  --network none \
  -e BITCOIN_NETWORK=regtest \
  -e CREATE_WALLET=false \
  -e BITCOIN_EXTRA_ARGS=$'server=1\nlisten=0\n' \
  -v "${volume}:/data:Z" \
  "${image}" >/dev/null

for _ in $(seq 1 60); do
  if podman exec "${name}" bitcoin-cli -regtest -datadir=/data getblockchaininfo >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
podman exec "${name}" bitcoin-cli -regtest -datadir=/data getblockchaininfo >/dev/null
version="$(podman exec "${name}" bitcoin-cli -regtest -datadir=/data getnetworkinfo |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
((version >= 300000)) || almapay_die "Bitcoin Core regtest version is below 300000"

podman exec "${name}" bitcoin-cli -regtest -datadir=/data \
  createwallet almapay-regtest false false "" false true >/dev/null
address="$(podman exec "${name}" bitcoin-cli -regtest -datadir=/data \
  -rpcwallet=almapay-regtest getnewaddress)"
podman exec "${name}" bitcoin-cli -regtest -datadir=/data \
  -rpcwallet=almapay-regtest generatetoaddress 101 "${address}" >/dev/null
blocks="$(podman exec "${name}" bitcoin-cli -regtest -datadir=/data getblockcount)"
[[ "${blocks}" -eq 101 ]] || almapay_die "regtest mining fixture failed"
echo "PASS Bitcoin Core regtest ${version}, mined ${blocks} blocks without chain download"
