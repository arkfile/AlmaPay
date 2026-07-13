#!/usr/bin/env bash
# Local unit and fixture integration suite. Does not claim VM/mainnet coverage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

pass() {
  printf 'PASS %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf 'FAIL %s\n' "$1"
  if [[ -s "${TMP_ROOT}/stderr" ]]; then
    sed 's/^/  /' "${TMP_ROOT}/stderr"
  fi
  FAIL=$((FAIL + 1))
}

assert_ok() {
  local name="$1"
  shift
  if ("$@") >"${TMP_ROOT}/stdout" 2>"${TMP_ROOT}/stderr"; then
    pass "${name}"
  else
    fail "${name}"
  fi
}

assert_fail() {
  local name="$1"
  shift
  if ("$@") >"${TMP_ROOT}/stdout" 2>"${TMP_ROOT}/stderr"; then
    fail "${name} (expected failure)"
  else
    pass "${name}"
  fi
}

assert_fail_contains() {
  local name="$1"
  local pattern="$2"
  shift 2
  if ("$@") >"${TMP_ROOT}/stdout" 2>"${TMP_ROOT}/stderr"; then
    fail "${name} (expected failure)"
  elif grep -Eq "${pattern}" "${TMP_ROOT}/stderr"; then
    pass "${name}"
  else
    fail "${name} (wrong failure reason)"
  fi
}

assert_contains() {
  local name="$1"
  local file="$2"
  local pattern="$3"
  if grep -Eq "${pattern}" "${file}"; then
    pass "${name}"
  else
    fail "${name}"
  fi
}

printf '== static analysis ==\n'
assert_ok "shell-syntax" bash -n \
  "${ROOT}/bin/almapay" "${ROOT}"/lib/*.sh "${ROOT}/tests/run.sh" "${ROOT}/scripts/test"
assert_ok "python-syntax" python3 -c '
import pathlib
import sys
for value in sys.argv[1:]:
    path = pathlib.Path(value)
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
' "${ROOT}/scripts/compose_model.py" \
   "${ROOT}/tests/test_compose_model.py" \
   "${ROOT}/tests/test_contract_fixtures.py"
if command -v shellcheck >/dev/null 2>&1; then
  assert_ok "shellcheck" shellcheck -x \
    "${ROOT}/bin/almapay" "${ROOT}"/lib/*.sh "${ROOT}/tests/run.sh" "${ROOT}/scripts/test"
else
  printf 'SKIP shellcheck (not installed locally; required on validated AlmaLinux/CI)\n'
fi

printf '== semantic Compose model ==\n'
if python3 -c 'import yaml' >/dev/null 2>&1; then
  assert_ok "compose-model-tests" python3 "${ROOT}/tests/test_compose_model.py" -v
  assert_ok "generic-contract-fixture-lint" python3 "${ROOT}/tests/test_contract_fixtures.py" -v
else
  fail "PyYAML is required for Compose tests"
fi

printf '== shell library behavior ==\n'
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=../lib/upstream.sh
source "${ROOT}/lib/upstream.sh"
# shellcheck source=../lib/config.sh
source "${ROOT}/lib/config.sh"
# shellcheck source=../lib/podman.sh
source "${ROOT}/lib/podman.sh"
# shellcheck source=../lib/compose.sh
source "${ROOT}/lib/compose.sh"
# shellcheck source=../lib/btcpay.sh
source "${ROOT}/lib/btcpay.sh"
# shellcheck source=../lib/backup.sh
source "${ROOT}/lib/backup.sh"
# shellcheck source=../lib/restore.sh
source "${ROOT}/lib/restore.sh"

assert_fail "reject-docker" almapay_assert_no_docker docker compose up
assert_fail "reject-docker-compose-provider" almapay_assert_no_docker docker-compose up
assert_fail "reject-rootful-podman" almapay_assert_no_docker sudo podman ps
assert_ok "allow-rootless-podman-command" almapay_assert_no_docker podman ps
redacted="$(almapay_redact 'postgresql://user:supersecret@postgres/db password=hunter2')"
if [[ "${redacted}" == *supersecret* || "${redacted}" == *hunter2* ]]; then
  fail "redact-database-credentials"
else
  pass "redact-database-credentials"
fi

VALID_CONFIG="${TMP_ROOT}/almapay.env"
cat >"${VALID_CONFIG}" <<'EOF'
ALMAPAY_DOMAIN=pay.example.com
ALMAPAY_NETWORK=mainnet
ALMAPAY_LISTEN=127.0.0.1:8080
ALMAPAY_BITCOIN_MODE=local-pruned
ALMAPAY_MONERO_MODE=disabled
ALMAPAY_LIGHTNING_MODE=disabled
ALMAPAY_CARD_MODE=disabled
ALMAPAY_ACME_EMAIL=operator@example.com
ALMAPAY_ACME_MODE=http-01
ALMAPAY_BACKUP_TARGET=
ALMAPAY_BACKUP_RETENTION_DAYS=30
ALMAPAY_INCLUDE_CHAIN_DATA_IN_BACKUP=false
EOF
chmod 0600 "${VALID_CONFIG}"
export ALMAPAY_CONFIG="${VALID_CONFIG}"
export ALMAPAY_DATA_ROOT="${TMP_ROOT}/data"
mkdir -p "${ALMAPAY_DATA_ROOT}"
assert_ok "strict-config-load" almapay_load_config
almapay_load_config
assert_ok "valid-mainnet-config" almapay_validate_config

export ALMAPAY_LIGHTNING_MODE=invalid
assert_fail "reject-invalid-lightning" almapay_validate_config
export ALMAPAY_LIGHTNING_MODE=disabled
export ALMAPAY_CARD_MODE=invalid
assert_fail "reject-invalid-card" almapay_validate_config
export ALMAPAY_CARD_MODE=disabled
export ALMAPAY_ACME_MODE=dns-01
assert_fail "reject-unimplemented-dns01" almapay_validate_config
export ALMAPAY_ACME_MODE=http-01
export ALMAPAY_BACKUP_RETENTION_DAYS=0
assert_fail "reject-zero-retention" almapay_validate_config
export ALMAPAY_BACKUP_RETENTION_DAYS=30
export ALMAPAY_INCLUDE_CHAIN_DATA_IN_BACKUP=maybe
assert_fail "reject-invalid-chain-backup-flag" almapay_validate_config
export ALMAPAY_INCLUDE_CHAIN_DATA_IN_BACKUP=false

MALICIOUS_MARKER="${TMP_ROOT}/executed"
MALICIOUS_CONFIG="${TMP_ROOT}/malicious.env"
cat >"${MALICIOUS_CONFIG}" <<EOF
ALMAPAY_DOMAIN=\$(touch ${MALICIOUS_MARKER})
EOF
chmod 0600 "${MALICIOUS_CONFIG}"
assert_ok "config-is-parsed-as-data" almapay_load_env_data "${MALICIOUS_CONFIG}" configuration
if [[ -e "${MALICIOUS_MARKER}" ]]; then
  fail "config-must-not-execute-shell"
else
  pass "config-must-not-execute-shell"
fi

UNKNOWN_CONFIG="${TMP_ROOT}/unknown.env"
printf 'UNKNOWN_KEY=value\n' >"${UNKNOWN_CONFIG}"
chmod 0600 "${UNKNOWN_CONFIG}"
assert_fail "reject-unknown-config-key" almapay_load_env_data "${UNKNOWN_CONFIG}" configuration
DUPLICATE_CONFIG="${TMP_ROOT}/duplicate.env"
printf 'ALMAPAY_DOMAIN=pay.example.com\nALMAPAY_DOMAIN=other.example.com\n' >"${DUPLICATE_CONFIG}"
chmod 0600 "${DUPLICATE_CONFIG}"
assert_fail "reject-duplicate-config-key" almapay_load_env_data "${DUPLICATE_CONFIG}" configuration

VALID_SECRETS="${TMP_ROOT}/valid-secrets.env"
cat >"${VALID_SECRETS}" <<'EOF'
POSTGRES_USER=postgres
POSTGRES_DB=postgres
POSTGRES_PASSWORD=ThisIsASafePasswordValue1234
EOF
chmod 0600 "${VALID_SECRETS}"
assert_ok "validate-protected-secrets" bash -c '
  source "'"${ROOT}"'/lib/common.sh"
  source "'"${ROOT}"'/lib/config.sh"
  ALMAPAY_USER="$(id -un)"
  ALMAPAY_SECRETS_PATH="'"${VALID_SECRETS}"'"
  almapay_require_secrets
'
chmod 0644 "${VALID_SECRETS}"
assert_fail_contains "reject-world-readable-secrets" "mode 0600" bash -c '
  source "'"${ROOT}"'/lib/common.sh"
  source "'"${ROOT}"'/lib/config.sh"
  ALMAPAY_USER="$(id -un)"
  ALMAPAY_SECRETS_PATH="'"${VALID_SECRETS}"'"
  almapay_require_secrets
'
chmod 0600 "${VALID_SECRETS}"
printf 'POSTGRES_PASSWORD=unsafe;password-value-that-is-long\n' >"${VALID_SECRETS}"
assert_fail_contains "reject-interpolation-unsafe-password" "unsafe for systemd" bash -c '
  source "'"${ROOT}"'/lib/common.sh"
  source "'"${ROOT}"'/lib/config.sh"
  ALMAPAY_USER="$(id -un)"
  ALMAPAY_SECRETS_PATH="'"${VALID_SECRETS}"'"
  almapay_require_secrets
'

export ALMAPAY_LOCKFILE="${ROOT}/upstream.lock"
assert_fail "candidate-lock-blocks-runtime" almapay_require_release_lock
export ALMAPAY_LOCKFILE="${ROOT}/tests/fixtures/lock/upstream.validated.yml"
assert_ok "validated-lock-allows-runtime" almapay_require_release_lock
INVALID_RELEASE_LOCK="${TMP_ROOT}/invalid-release-lock.yml"
awk '
  /^  package_artifacts:$/ { skip=1; next }
  skip && /^btcpayserver_docker:/ { skip=0 }
  !skip { print }
' "${ALMAPAY_LOCKFILE}" >"${INVALID_RELEASE_LOCK}"
export ALMAPAY_LOCKFILE="${INVALID_RELEASE_LOCK}"
assert_fail "validated-lock-requires-package-artifacts" almapay_require_release_lock
export ALMAPAY_LOCKFILE="${ROOT}/tests/fixtures/lock/upstream.validated.yml"
assert_ok "locked-image-reference" bash -c \
  'source "'"${ROOT}"'/lib/common.sh"; source "'"${ROOT}"'/lib/upstream.sh"; export ALMAPAY_LOCKFILE="'"${ALMAPAY_LOCKFILE}"'"; [[ "$(almapay_lock_image_runtime_ref bitcoin_core)" == btcpayserver/bitcoin@sha256:cc070dffde3073154b508e95ae64b39f433b41874dd8f2cd49c0d1b4d16a15ff ]]'

assert_ok "version-equal" almapay_version_at_least 2.4.0 2.4.0
assert_ok "version-newer" almapay_version_at_least 2.5.1 2.4.0
assert_fail "version-older" almapay_version_at_least 2.3.9 2.4.0
printf 'b: 2\na: 1\n' >"${TMP_ROOT}/hash-a.yml"
printf 'a: 1\nb: 2\n' >"${TMP_ROOT}/hash-b.yml"
hash_a="$(almapay_compose_semantic_hash "${TMP_ROOT}/hash-a.yml")"
hash_b="$(almapay_compose_semantic_hash "${TMP_ROOT}/hash-b.yml")"
[[ "${hash_a}" == "${hash_b}" ]] &&
  pass "semantic-compose-hash-is-order-independent" ||
  fail "semantic-compose-hash-is-order-independent"
almapay_generator_env
[[ "${NOREVERSEPROXY_HTTP_PORT}" == "127.0.0.1:8080" ]] &&
  pass "generator-loopback-input" || fail "generator-loopback-input"
[[ "${BTCPAYGEN_EXCLUDE_FRAGMENTS}" == *bitcoin* &&
   "${BTCPAYGEN_EXCLUDE_FRAGMENTS}" == *opt-add-tor* ]] &&
  pass "generator-excludes-bitcoin-and-tor" || fail "generator-excludes-bitcoin-and-tor"
[[ "${BTCPAYGEN_ADDITIONAL_FRAGMENTS}" == *bitcoincore* &&
   "${BTCPAYGEN_ADDITIONAL_FRAGMENTS}" == *opt-save-storage-s* &&
   "${BTCPAYGEN_ADDITIONAL_FRAGMENTS}" == *opt-mempoolfullrbf* ]] &&
  pass "generator-required-fragments" || fail "generator-required-fragments"

GENERATOR_SOURCE="${TMP_ROOT}/upstream/docker-compose-generator"
mkdir -p "${GENERATOR_SOURCE}"
cat >"${GENERATOR_SOURCE}/Dockerfile" <<'EOF'
FROM --platform=$BUILDPLATFORM example.invalid/sdk:tag AS builder
RUN echo build
FROM example.invalid/runtime:tag
EOF
GENERATOR_DOCKERFILE_SHA="$(almapay_sha256_file "${GENERATOR_SOURCE}/Dockerfile")"
assert_ok "generator-rewrites-platform-from-correctly" bash -c '
  set -euo pipefail
  source "'"${ROOT}"'/lib/common.sh"
  source "'"${ROOT}"'/lib/compose.sh"
  almapay_upstream_dir() { printf "%s\n" "'"${TMP_ROOT}"'/upstream"; }
  almapay_generator_build_context() { printf "%s\n" "'"${TMP_ROOT}"'/generator-context"; }
  almapay_lock_get() {
    case "$1" in
      btcpayserver_docker.generator.builder_base_image)
        echo "example.invalid/sdk@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;
      btcpayserver_docker.generator.runtime_base_image)
        echo "example.invalid/runtime@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;
      btcpayserver_docker.generator.dockerfile_sha256)
        echo "'"${GENERATOR_DOCKERFILE_SHA}"'" ;;
      *) return 1 ;;
    esac
  }
  almapay_prepare_generator_context
  grep -q "^FROM --platform=\$BUILDPLATFORM example.invalid/sdk@sha256:a\\{64\\} AS builder$" \
    "'"${TMP_ROOT}"'/generator-context/Dockerfile"
  grep -q "^FROM example.invalid/runtime@sha256:b\\{64\\}$" \
    "'"${TMP_ROOT}"'/generator-context/Dockerfile"
'

FAKE_PROVIDER="${TMP_ROOT}/podman-compose"
cat >"${FAKE_PROVIDER}" <<'EOF'
#!/usr/bin/env bash
echo "podman-compose version 1.5.0"
EOF
chmod 0755 "${FAKE_PROVIDER}"
ALMAPAY_COMPOSE_PROVIDER_PATH="${FAKE_PROVIDER}"
PODMAN_COMPOSE_PROVIDER="${FAKE_PROVIDER}"
assert_ok "exact-compose-provider-version" almapay_require_compose_provider
cat >"${FAKE_PROVIDER}" <<'EOF'
#!/usr/bin/env bash
echo "podman-compose version 1.4.0"
EOF
chmod 0755 "${FAKE_PROVIDER}"
assert_fail "reject-compose-provider-version-mismatch" almapay_require_compose_provider
unset PODMAN_COMPOSE_PROVIDER
ALMAPAY_COMPOSE_PROVIDER_PATH="/usr/bin/podman-compose"

if [[ "$(id -u)" -eq 0 ]]; then
  assert_fail "runtime-refuses-root" almapay_refuse_root
else
  pass "runtime-refuses-root (requires root execution to exercise; current run is non-root)"
fi
assert_fail_contains "backup-fails-closed" "backup is not implemented" \
  bash -c 'source "'"${ROOT}"'/lib/common.sh"; source "'"${ROOT}"'/lib/backup.sh"; almapay_require_service_user() { :; }; almapay_backup'
assert_fail_contains "restore-fails-closed" "restore is not implemented" \
  bash -c 'source "'"${ROOT}"'/lib/common.sh"; source "'"${ROOT}"'/lib/restore.sh"; almapay_require_service_user() { :; }; almapay_restore'

FAKE_BIN="${TMP_ROOT}/bin"
mkdir -p "${FAKE_BIN}"
cat >"${FAKE_BIN}/caddy" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "validate" && "$2" == "--config" && -f "$3" ]]
EOF
chmod 0755 "${FAKE_BIN}/caddy"
assert_ok "caddy-render-and-validation" bash -c '
  set -euo pipefail
  source "'"${ROOT}"'/lib/common.sh"
  source "'"${ROOT}"'/lib/caddy.sh"
  almapay_require_service_user() { :; }
  export PATH="'"${FAKE_BIN}"':${PATH}"
  export ALMAPAY_DATA_ROOT="'"${TMP_ROOT}"'/caddy-root"
  export ALMAPAY_DOMAIN=pay.example.com
  export ALMAPAY_ACME_EMAIL=operator@example.com
  export ALMAPAY_ACME_MODE=http-01
  almapay_render_caddy >/dev/null
  grep -q "reverse_proxy 127.0.0.1:8080" "${ALMAPAY_DATA_ROOT}/caddy/Caddyfile.almapay"
  ! grep -Eq "^[[:space:]]*log[[:space:]]" "${ALMAPAY_DATA_ROOT}/caddy/Caddyfile.almapay"
'

assert_contains "systemd-loads-protected-secrets" \
  "${ROOT}/templates/systemd/almapay.service" \
  '^EnvironmentFile=/var/lib/almapay/secrets\.env$'
if grep -q '%i' "${ROOT}/templates/systemd/almapay.service"; then
  fail "systemd-template-does-not-use-instance-as-uid"
else
  pass "systemd-template-does-not-use-instance-as-uid"
fi

if [[ "${ALMAPAY_RUN_REGTEST:-0}" == "1" ]]; then
  assert_ok "bitcoin-regtest-smoke" "${ROOT}/tests/integration/regtest-bitcoin.sh"
else
  printf 'SKIP bitcoin-regtest-smoke (set ALMAPAY_RUN_REGTEST=1 on a rootless Podman host)\n'
fi

printf '\nResults: PASS=%d FAIL=%d\n' "${PASS}" "${FAIL}"
((FAIL == 0))
