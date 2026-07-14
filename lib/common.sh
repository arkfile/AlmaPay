# AlmaPay common helpers. Sourced by bin/almapay and other libraries.
# shellcheck shell=bash

set -euo pipefail

ALMAPAY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALMAPAY_ROOT="$(cd "${ALMAPAY_LIB_DIR}/.." && pwd)"

ALMAPAY_USER="almapay"
ALMAPAY_DATA_ROOT="/var/lib/almapay"
ALMAPAY_CHAINDATA_ROOT="${ALMAPAY_DATA_ROOT}/chaindata"
ALMAPAY_HOST_LOCK_PATH="${ALMAPAY_DATA_ROOT}/upstream.lock"
ALMAPAY_LISTEN_FIXED="127.0.0.1:8080"
ALMAPAY_COMPOSE_PROVIDER_PATH="/usr/bin/podman-compose"

# Prefer a host-specific lock written by lock-research on the deployment VPS.
if [[ -z "${ALMAPAY_LOCKFILE:-}" && -f "${ALMAPAY_HOST_LOCK_PATH}" ]]; then
  ALMAPAY_LOCKFILE="${ALMAPAY_HOST_LOCK_PATH}"
fi

almapay_log() {
  local level="$1"
  shift
  printf '[almapay:%s] %s\n' "${level}" "$*" >&2
}

almapay_info() { almapay_log info "$*"; }
almapay_warn() { almapay_log warn "$*"; }
almapay_error() { almapay_log error "$*"; }

almapay_die() {
  almapay_error "$*"
  exit 1
}

almapay_require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || almapay_die "required command missing: ${cmd}"
  done
}

# Refuse to continue if this process is UID 0 (runtime path).
almapay_refuse_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    almapay_die "runtime command refuses UID 0; use sudo -u ${ALMAPAY_USER} or almapay bootstrap-host for privileged host setup"
  fi
}

almapay_require_service_user() {
  almapay_refuse_root
  if ! almapay_is_service_user; then
    almapay_die "runtime command must run as ${ALMAPAY_USER}; use sudo -u ${ALMAPAY_USER} -H"
  fi
  export HOME="${ALMAPAY_DATA_ROOT}"
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
}

# True when the current effective user is the AlmaPay service account.
almapay_is_service_user() {
  [[ "$(id -un)" == "${ALMAPAY_USER}" ]]
}

almapay_confirm() {
  local flag="${1:-}"
  local message="${2:-destructive action}"
  if [[ "${flag}" == "--yes-i-really-mean-it" ]]; then
    return 0
  fi
  if [[ "${ALMAPAY_NONINTERACTIVE:-0}" == "1" ]]; then
    almapay_die "refusing '${message}' without --yes-i-really-mean-it in noninteractive mode"
  fi
  almapay_die "refusing '${message}' without --yes-i-really-mean-it"
}

# Redact common secret-like tokens from diagnostic text.
almapay_redact() {
  local text="$1"
  text="$(printf '%s' "${text}" | sed -E \
    -e 's/(api[_-]?key|token|password|secret|passwd|authorization)(=|:[[:space:]]*)[^[:space:]]+/\1\2[REDACTED]/gi' \
    -e 's/BTCPay-Sig:[[:space:]]*sha256=[0-9a-fA-F]+/BTCPay-Sig: sha256=[REDACTED]/g' \
    -e 's#(postgres(ql)?://[^:/[:space:]]+):[^@[:space:]]+@#\1:[REDACTED]@#gi' \
    -e 's/(sk_live_|sk_test_|whsec_|xprv|xpub|spendkey|viewkey)[A-Za-z0-9_-]+/\1[REDACTED]/gi')"
  printf '%s' "${text}"
}

almapay_abspath() {
  local path="$1"
  if [[ "${path}" = /* ]]; then
    printf '%s\n' "${path}"
  else
    printf '%s\n' "$(pwd)/${path}"
  fi
}

almapay_sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | awk '{print $1}'
  else
    almapay_die "sha256sum or shasum required"
  fi
}

almapay_tmpdir() {
  mktemp -d "${TMPDIR:-/tmp}/almapay.XXXXXX"
}

# Disable shell tracing before reading secrets.
almapay_secrets_guard() {
  set +x
  set +v
}

almapay_source_optional() {
  almapay_die "internal error: executable env-file sourcing is prohibited"
}
