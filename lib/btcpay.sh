# AlmaPay runtime service and version helpers.
# shellcheck shell=bash

almapay_btcpay_loopback_base() {
  printf 'http://%s\n' "${ALMAPAY_LISTEN_FIXED}"
}

almapay_btcpay_public_base() {
  printf 'https://%s\n' "${ALMAPAY_DOMAIN}"
}

almapay_container_for_service() {
  local service="$1"
  local matches
  matches="$(podman ps \
    --filter "label=com.docker.compose.service=${service}" \
    --format '{{.Names}}')"
  if [[ -z "${matches}" ]]; then
    matches="$(podman ps \
      --filter "label=io.podman.compose.service=${service}" \
      --format '{{.Names}}')"
  fi
  [[ "$(printf '%s\n' "${matches}" | sed '/^$/d' | wc -l)" -eq 1 ]] ||
    almapay_die "expected exactly one running container for service ${service}"
  printf '%s\n' "${matches}"
}

almapay_query_btcpay_version() {
  local container output
  container="$(almapay_container_for_service btcpayserver)"
  output="$(podman exec "${container}" dotnet BTCPayServer.dll --version 2>/dev/null)" ||
    almapay_die "unable to query the running BTCPay process version"
  if [[ "${output}" =~ ([0-9]+\.[0-9]+\.[0-9]+([.][0-9]+)?) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    almapay_die "BTCPay returned an unrecognized version: $(almapay_redact "${output}")"
  fi
}

almapay_query_bitcoin_version_numeric() {
  local container output
  container="$(almapay_container_for_service bitcoind)"
  output="$(podman exec "${container}" bitcoin-cli -datadir=/data getnetworkinfo 2>/dev/null)" ||
    almapay_die "unable to query Bitcoin Core getnetworkinfo"
  python3 -c 'import json,sys; print(int(json.load(sys.stdin)["version"]))' <<<"${output}" ||
    almapay_die "Bitcoin Core returned invalid getnetworkinfo JSON"
}

almapay_version_at_least() {
  local actual="$1"
  local minimum="$2"
  python3 - "${actual}" "${minimum}" <<'PY'
import re
import sys

def version(value):
    match = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?", value)
    if not match:
        raise SystemExit(2)
    return tuple(int(part or 0) for part in match.groups())

raise SystemExit(0 if version(sys.argv[1]) >= version(sys.argv[2]) else 1)
PY
}

almapay_assert_btcpay_version_floor() {
  local version minimum
  minimum="$(almapay_lock_get minimum_versions.btcpayserver)"
  version="$(almapay_query_btcpay_version)"
  almapay_version_at_least "${version}" "${minimum}" ||
    almapay_die "BTCPay version ${version} is below ${minimum}"
  almapay_info "BTCPay runtime version: ${version}"
}

almapay_assert_bitcoin_version_floor() {
  local numeric minimum
  minimum="$(almapay_lock_get minimum_versions.bitcoin_core_numeric)"
  numeric="$(almapay_query_bitcoin_version_numeric)"
  [[ "${numeric}" =~ ^[0-9]+$ ]] ||
    almapay_die "Bitcoin Core returned a nonnumeric version"
  ((numeric >= minimum)) ||
    almapay_die "Bitcoin Core numeric version ${numeric} is below ${minimum}"
  almapay_info "Bitcoin Core runtime numeric version: ${numeric}"
}

almapay_assert_container_image() {
  local service="$1"
  local expected="$2"
  local container actual expected_id
  container="$(almapay_container_for_service "${service}")"
  actual="$(podman inspect --format '{{.Image}}' "${container}")"
  expected_id="$(podman image inspect --format '{{.Id}}' "${expected}")"
  [[ "${actual}" == "${expected_id}" ]] ||
    almapay_die "${service} runtime image ID ${actual} does not resolve from locked reference ${expected}"
}
