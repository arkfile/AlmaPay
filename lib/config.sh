# AlmaPay configuration loading and validation.
# shellcheck shell=bash

almapay_default_config_paths() {
  if [[ -n "${ALMAPAY_CONFIG:-}" ]]; then
    printf '%s\n' "${ALMAPAY_CONFIG}"
    return 0
  fi
  if [[ -f "${ALMAPAY_DATA_ROOT}/almapay.env" ]]; then
    printf '%s\n' "${ALMAPAY_DATA_ROOT}/almapay.env"
    return 0
  fi
  if [[ -f "${ALMAPAY_ROOT}/config/almapay.env" ]]; then
    printf '%s\n' "${ALMAPAY_ROOT}/config/almapay.env"
    return 0
  fi
  almapay_die "configuration missing; copy config/almapay.env.example to ${ALMAPAY_DATA_ROOT}/almapay.env"
}

almapay_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

almapay_config_key_allowed() {
  case "$1" in
    ALMAPAY_DOMAIN|ALMAPAY_NETWORK|ALMAPAY_LISTEN|ALMAPAY_BITCOIN_MODE|\
    ALMAPAY_MONERO_MODE|ALMAPAY_LIGHTNING_MODE|ALMAPAY_CARD_MODE|\
    ALMAPAY_ACME_EMAIL|ALMAPAY_ACME_MODE|ALMAPAY_BACKUP_TARGET|\
    ALMAPAY_BACKUP_RETENTION_DAYS|ALMAPAY_INCLUDE_CHAIN_DATA_IN_BACKUP)
      return 0
      ;;
    *) return 1 ;;
  esac
}

almapay_secret_key_allowed() {
  case "$1" in
    POSTGRES_USER|POSTGRES_DB|POSTGRES_PASSWORD|STRIPE_TEST_SECRET_KEY|\
    STRIPE_LIVE_SECRET_KEY|BOLTZ_API_KEY|ALMAPAY_VERIFY_API_KEY|\
    ALMAPAY_VERIFY_STORE_ID|ALMAPAY_VERIFY_WEBHOOK_URL)
      return 0
      ;;
    *) return 1 ;;
  esac
}

# Parse strict KEY=VALUE files as data. Never source operator-controlled files.
almapay_load_env_data() {
  local file="$1"
  local kind="$2"
  local line key value line_number=0
  local -A seen=()

  [[ -f "${file}" ]] || almapay_die "${kind} file not found: ${file}"
  [[ ! -L "${file}" ]] || almapay_die "${kind} file must not be a symlink: ${file}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_number=$((line_number + 1))
    line="$(almapay_trim "${line}")"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    if [[ ! "${line}" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      almapay_die "${kind} file ${file}:${line_number}: expected KEY=VALUE"
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    [[ -z "${seen[${key}]:-}" ]] ||
      almapay_die "duplicate ${kind} key ${key} in ${file}:${line_number}"
    seen["${key}"]=1
    if [[ "${kind}" == "configuration" ]]; then
      almapay_config_key_allowed "${key}" ||
        almapay_die "unknown configuration key ${key} in ${file}:${line_number}"
    else
      almapay_secret_key_allowed "${key}" ||
        almapay_die "unknown secret key ${key} in ${file}:${line_number}"
    fi

    # Permit simple matching quotes, but perform no shell expansion.
    if [[ "${value}" =~ ^\"(.*)\"$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "${value}" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    [[ "${value}" != *$'\r'* ]] ||
      almapay_die "${kind} file ${file}:${line_number}: carriage returns are not allowed"
    printf -v "${key}" '%s' "${value}"
    export "${key}"
  done <"${file}"
}

almapay_validate_nonsecret_file() {
  local file="$1"
  local mode
  mode="$(stat -c '%a' "${file}")"
  # Reject group/other writable configuration.
  if (( (8#${mode} & 8#022) != 0 )); then
    almapay_die "configuration must not be group/other writable: ${file} (mode ${mode})"
  fi
}

almapay_validate_secret_file() {
  local file="$1"
  local mode owner
  [[ -f "${file}" ]] || almapay_die "secrets file missing: ${file}"
  [[ ! -L "${file}" ]] || almapay_die "secrets file must not be a symlink: ${file}"
  mode="$(stat -c '%a' "${file}")"
  owner="$(stat -c '%U' "${file}")"
  [[ "${mode}" == "600" ]] ||
    almapay_die "secrets file must have mode 0600: ${file} (mode ${mode})"
  [[ "${owner}" == "${ALMAPAY_USER}" ]] ||
    almapay_die "secrets file must be owned by ${ALMAPAY_USER}: ${file} (owner ${owner})"
}

almapay_load_config() {
  local config_path secrets_path
  config_path="$(almapay_default_config_paths)"
  unset ALMAPAY_DOMAIN ALMAPAY_NETWORK ALMAPAY_LISTEN \
    ALMAPAY_BITCOIN_MODE ALMAPAY_MONERO_MODE ALMAPAY_LIGHTNING_MODE \
    ALMAPAY_CARD_MODE ALMAPAY_ACME_EMAIL ALMAPAY_ACME_MODE \
    ALMAPAY_BACKUP_TARGET ALMAPAY_BACKUP_RETENTION_DAYS \
    ALMAPAY_INCLUDE_CHAIN_DATA_IN_BACKUP
  unset POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD \
    STRIPE_TEST_SECRET_KEY STRIPE_LIVE_SECRET_KEY BOLTZ_API_KEY \
    ALMAPAY_VERIFY_API_KEY ALMAPAY_VERIFY_STORE_ID ALMAPAY_VERIFY_WEBHOOK_URL
  almapay_validate_nonsecret_file "${config_path}"
  almapay_load_env_data "${config_path}" configuration

  ALMAPAY_CONFIG_PATH="${config_path}"
  ALMAPAY_DOMAIN="${ALMAPAY_DOMAIN:-}"
  ALMAPAY_NETWORK="${ALMAPAY_NETWORK:-mainnet}"
  ALMAPAY_LISTEN="${ALMAPAY_LISTEN:-127.0.0.1:8080}"
  ALMAPAY_BITCOIN_MODE="${ALMAPAY_BITCOIN_MODE:-local-pruned}"
  ALMAPAY_MONERO_MODE="${ALMAPAY_MONERO_MODE:-local-pruned}"
  ALMAPAY_LIGHTNING_MODE="${ALMAPAY_LIGHTNING_MODE:-disabled}"
  ALMAPAY_CARD_MODE="${ALMAPAY_CARD_MODE:-disabled}"
  ALMAPAY_ACME_EMAIL="${ALMAPAY_ACME_EMAIL:-}"
  ALMAPAY_ACME_MODE="${ALMAPAY_ACME_MODE:-http-01}"
  ALMAPAY_BACKUP_TARGET="${ALMAPAY_BACKUP_TARGET:-}"
  ALMAPAY_BACKUP_RETENTION_DAYS="${ALMAPAY_BACKUP_RETENTION_DAYS:-30}"
  ALMAPAY_INCLUDE_CHAIN_DATA_IN_BACKUP="${ALMAPAY_INCLUDE_CHAIN_DATA_IN_BACKUP:-false}"

  secrets_path="${ALMAPAY_SECRETS:-${ALMAPAY_DATA_ROOT}/secrets.env}"
  ALMAPAY_SECRETS_PATH="${secrets_path}"
}

almapay_require_secrets() {
  almapay_validate_secret_file "${ALMAPAY_SECRETS_PATH}"
  almapay_secrets_guard
  almapay_load_env_data "${ALMAPAY_SECRETS_PATH}" secrets
  [[ -n "${POSTGRES_PASSWORD:-}" ]] ||
    almapay_die "POSTGRES_PASSWORD is required in ${ALMAPAY_SECRETS_PATH}"
  [[ "${POSTGRES_PASSWORD}" != "replace-with-long-random-value" ]] ||
    almapay_die "replace the example POSTGRES_PASSWORD in ${ALMAPAY_SECRETS_PATH}"
  ((${#POSTGRES_PASSWORD} >= 24)) ||
    almapay_die "POSTGRES_PASSWORD must be at least 24 characters"
  [[ "${POSTGRES_PASSWORD}" =~ ^[A-Za-z0-9._~!%\^\&*+=:@-]+$ ]] ||
    almapay_die "POSTGRES_PASSWORD contains characters unsafe for systemd/Compose/database interpolation"
}

almapay_validate_config() {
  local errors=()

  [[ -n "${ALMAPAY_DOMAIN}" ]] || errors+=("ALMAPAY_DOMAIN is required")
  if [[ ! "${ALMAPAY_DOMAIN}" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    errors+=("ALMAPAY_DOMAIN is not a valid hostname: ${ALMAPAY_DOMAIN}")
  fi

  case "${ALMAPAY_NETWORK}" in
    mainnet) ;;
    regtest) errors+=("ALMAPAY_NETWORK=regtest is fixture-only and is not accepted by production CLI configuration") ;;
    *) errors+=("ALMAPAY_NETWORK must be mainnet in the initial profile (got ${ALMAPAY_NETWORK})") ;;
  esac

  case "${ALMAPAY_BITCOIN_MODE}" in
    local-pruned) ;;
    *) errors+=("ALMAPAY_BITCOIN_MODE unsupported in initial profile: ${ALMAPAY_BITCOIN_MODE}") ;;
  esac

  case "${ALMAPAY_MONERO_MODE}" in
    disabled|local-pruned) ;;
    local-full) errors+=("ALMAPAY_MONERO_MODE=local-full requires a future profile") ;;
    *) errors+=("ALMAPAY_MONERO_MODE unsupported: ${ALMAPAY_MONERO_MODE}") ;;
  esac

  case "${ALMAPAY_LIGHTNING_MODE}" in
    disabled|boltz-nodeless) ;;
    *) errors+=("ALMAPAY_LIGHTNING_MODE unsupported: ${ALMAPAY_LIGHTNING_MODE}") ;;
  esac

  case "${ALMAPAY_CARD_MODE}" in
    disabled|stripe) ;;
    *) errors+=("ALMAPAY_CARD_MODE unsupported: ${ALMAPAY_CARD_MODE}") ;;
  esac

  if [[ "${ALMAPAY_LISTEN}" != "${ALMAPAY_LISTEN_FIXED}" ]]; then
    errors+=("ALMAPAY_LISTEN must be ${ALMAPAY_LISTEN_FIXED} in the initial profile (got ${ALMAPAY_LISTEN})")
  fi

  case "${ALMAPAY_ACME_MODE}" in
    http-01) ;;
    dns-01) errors+=("ALMAPAY_ACME_MODE=dns-01 is not implemented in the initial profile") ;;
    *) errors+=("ALMAPAY_ACME_MODE unsupported: ${ALMAPAY_ACME_MODE}") ;;
  esac

  if [[ -n "${ALMAPAY_BACKUP_RETENTION_DAYS}" ]]; then
    if ! [[ "${ALMAPAY_BACKUP_RETENTION_DAYS}" =~ ^[1-9][0-9]*$ ]]; then
      errors+=("ALMAPAY_BACKUP_RETENTION_DAYS must be a positive integer")
    fi
  fi

  case "${ALMAPAY_INCLUDE_CHAIN_DATA_IN_BACKUP}" in
    true|false) ;;
    *) errors+=("ALMAPAY_INCLUDE_CHAIN_DATA_IN_BACKUP must be true or false") ;;
  esac

  if ((${#errors[@]} > 0)); then
    local e
    for e in "${errors[@]}"; do
      almapay_error "config: ${e}"
    done
    almapay_die "configuration validation failed"
  fi
}

almapay_generator_env() {
  # Values consumed by upstream compose generation.
  export BTCPAY_HOST="${ALMAPAY_DOMAIN}"
  export BTCPAY_PROTOCOL="https"
  export BTCPAYGEN_CRYPTO1="btc"
  if [[ "${ALMAPAY_MONERO_MODE}" == "local-pruned" ]]; then
    export BTCPAYGEN_CRYPTO2="xmr"
  else
    unset BTCPAYGEN_CRYPTO2 || true
  fi
  export BTCPAYGEN_REVERSEPROXY="none"
  export BTCPAYGEN_LIGHTNING="none"
  # Exclude default bitcoin (Core 29.x) and tor fragment; add Core 31 + prune.
  export BTCPAYGEN_EXCLUDE_FRAGMENTS="bitcoin;opt-add-tor"
  export BTCPAYGEN_ADDITIONAL_FRAGMENTS="bitcoincore;opt-save-storage-s;opt-mempoolfullrbf"
  export BTCPAY_IMAGE="$(almapay_lock_image_runtime_ref btcpayserver)"
  export NBITCOIN_NETWORK="${ALMAPAY_NETWORK}"
  export NOREVERSEPROXY_HTTP_PORT="${ALMAPAY_LISTEN}"
  export PODMAN_COMPOSE_PROVIDER="${ALMAPAY_COMPOSE_PROVIDER_PATH}"
}

almapay_runtime_env_contents() {
  cat <<EOF
BTCPAY_HOST=${ALMAPAY_DOMAIN}
BTCPAY_PROTOCOL=https
NBITCOIN_NETWORK=${ALMAPAY_NETWORK}
NOREVERSEPROXY_HTTP_PORT=${ALMAPAY_LISTEN}
PODMAN_COMPOSE_PROVIDER=${ALMAPAY_COMPOSE_PROVIDER_PATH}
CREATE_WALLET=false
EOF
  if [[ "${ALMAPAY_MONERO_MODE}" == "local-pruned" ]]; then
    printf 'BTCPAY_CRYPTOS=btc;xmr\n'
  else
    printf 'BTCPAY_CRYPTOS=btc\n'
  fi
}
