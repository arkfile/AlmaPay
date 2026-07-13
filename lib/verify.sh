# AlmaPay fail-closed runtime verification.
# shellcheck shell=bash

almapay_verify_server_info() {
  local production="$1"
  local output
  if [[ -z "${ALMAPAY_VERIFY_API_KEY:-}" ]]; then
    if [[ "${production}" -eq 1 ]]; then
      almapay_die "ALMAPAY_VERIFY_API_KEY is required for production synchronization verification"
    fi
    almapay_warn "server synchronization check skipped: ALMAPAY_VERIFY_API_KEY is not configured"
    return 0
  fi

  output="$(
    printf 'header = "Authorization: token %s"\n' "${ALMAPAY_VERIFY_API_KEY}" |
      curl --config - --fail --silent --show-error \
        --connect-timeout 10 --max-time 30 \
        "https://${ALMAPAY_DOMAIN}/api/v1/server/info"
  )" ||
    almapay_die "authenticated BTCPay server-info request failed"
  python3 -c '
import json
import sys
production = sys.argv[1] == "1"
data = json.load(sys.stdin)
synced = data.get("status", {}).get("fullySynched")
if synced is True:
    print("[almapay:info] BTCPay reports fully synchronized", file=sys.stderr)
elif production:
    raise SystemExit("BTCPay is reachable but not fully synchronized")
else:
    print("[almapay:warn] BTCPay is reachable but not fully synchronized", file=sys.stderr)
' "${production}" <<<"${output}" ||
    almapay_die "BTCPay server-info response failed synchronization validation"
}

almapay_verify_postgres() {
  local container
  container="$(almapay_container_for_service postgres)"
  podman exec "${container}" pg_isready \
    -U "${POSTGRES_USER:-postgres}" \
    -d "${POSTGRES_DB:-postgres}" >/dev/null ||
    almapay_die "PostgreSQL readiness check failed"
}

almapay_verify_bitcoin_sync() {
  local production="$1"
  local container output
  container="$(almapay_container_for_service bitcoind)"
  output="$(podman exec "${container}" bitcoin-cli -datadir=/data getblockchaininfo 2>/dev/null)" ||
    almapay_die "unable to query Bitcoin Core getblockchaininfo"
  python3 -c '
import json
import sys
production = sys.argv[1] == "1"
data = json.load(sys.stdin)
ready = (
    data.get("initialblockdownload") is False
    and float(data.get("verificationprogress", 0)) >= 0.9999
)
if not ready and production:
    raise SystemExit("Bitcoin Core is reachable but not synchronized")
if not ready:
    print("[almapay:warn] Bitcoin Core is reachable but not synchronized", file=sys.stderr)
else:
    print("[almapay:info] Bitcoin Core reports synchronized", file=sys.stderr)
' "${production}" <<<"${output}" ||
    almapay_die "Bitcoin synchronization validation failed"
}

almapay_verify_host_health() {
  command -v getenforce >/dev/null 2>&1 ||
    almapay_die "getenforce is required for runtime verification"
  [[ "$(getenforce)" == "Enforcing" ]] ||
    almapay_die "SELinux is not enforcing"
  systemctl is-active --quiet caddy ||
    almapay_die "host Caddy service is not active"

  local available_kib inode_percent
  available_kib="$(df -Pk "${ALMAPAY_DATA_ROOT}" | awk 'NR==2 {print $4}')"
  inode_percent="$(df -Pi "${ALMAPAY_DATA_ROOT}" | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
  [[ "${available_kib}" =~ ^[0-9]+$ && "${available_kib}" -ge 20971520 ]] ||
    almapay_die "data root has less than 20 GiB free"
  [[ "${inode_percent}" =~ ^[0-9]+$ && "${inode_percent}" -lt 95 ]] ||
    almapay_die "data root inode use is at least 95%"
}

almapay_verify_ports() {
  local listeners
  listeners="$(ss -H -lnt)"
  printf '%s\n' "${listeners}" |
    awk '$4 ~ /:8080$/ {print $4}' |
    grep -qx '127.0.0.1:8080' ||
    almapay_die "BTCPay is not listening exactly on 127.0.0.1:8080"
  if printf '%s\n' "${listeners}" |
    awk '$4 ~ /:8080$/ {print $4}' |
    grep -Evqx '127.0.0.1:8080'; then
    almapay_die "port 8080 has an unexpected non-loopback listener"
  fi
  local port
  for port in 5432 32838 43782 18081 18082 18083; do
    if printf '%s\n' "${listeners}" | awk -v port="${port}" '$4 ~ ":" port "$" {found=1} END {exit !found}'; then
      almapay_die "internal service port ${port} is host-published"
    fi
  done
}

almapay_verify() {
  local production=0
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --production) production=1 ;;
      *) almapay_die "unknown verify argument: ${arg}" ;;
    esac
  done

  almapay_require_service_user
  almapay_load_config
  almapay_validate_config
  almapay_require_release_lock
  almapay_require_secrets
  almapay_require_cmd podman curl jq ss systemctl
  almapay_require_compose_provider

  [[ -f "$(almapay_compose_file)" ]] ||
    almapay_die "generated Compose file is missing"
  almapay_compose_security_validate "$(almapay_compose_file)"

  systemctl --user is-enabled --quiet almapay.service ||
    almapay_die "almapay user service is not enabled"
  systemctl --user is-active --quiet almapay.service ||
    almapay_die "almapay user service is not active"

  local service image_key
  while read -r service image_key; do
    almapay_assert_container_image \
      "${service}" \
      "$(almapay_lock_image_runtime_ref "${image_key}")"
  done <<'EOF'
btcpayserver btcpayserver
postgres postgres
nbxplorer nbxplorer
bitcoind bitcoin_core
EOF
  if [[ "${ALMAPAY_MONERO_MODE}" == "local-pruned" ]]; then
    almapay_assert_container_image monerod "$(almapay_lock_image_runtime_ref monero)"
  fi

  curl --fail --silent --show-error \
    --connect-timeout 5 --max-time 15 \
    "http://${ALMAPAY_LISTEN_FIXED}/api/v1/health" >/dev/null ||
    almapay_die "BTCPay loopback health check failed"
  getent ahosts "${ALMAPAY_DOMAIN}" >/dev/null ||
    almapay_die "public domain does not resolve: ${ALMAPAY_DOMAIN}"
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    "https://${ALMAPAY_DOMAIN}/api/v1/health" >/dev/null ||
    almapay_die "public HTTPS health check failed"

  almapay_verify_ports
  almapay_verify_host_health
  almapay_verify_postgres
  almapay_assert_btcpay_version_floor
  almapay_assert_bitcoin_version_floor
  almapay_verify_bitcoin_sync "${production}"
  almapay_verify_server_info "${production}"

  if [[ "${production}" -eq 1 ]]; then
    [[ -n "${ALMAPAY_VERIFY_STORE_ID:-}" ]] ||
      almapay_die "ALMAPAY_VERIFY_STORE_ID is required for production verification"
    [[ -n "${ALMAPAY_VERIFY_WEBHOOK_URL:-}" ]] ||
      almapay_die "ALMAPAY_VERIFY_WEBHOOK_URL is required for production verification"
    almapay_die "production verification remains blocked until plugin, backup/restore, privacy, Greenfield permission, and webhook checks are implemented and exercised on AlmaLinux"
  fi

  almapay_info "runtime verification passed (non-production)"
}
