# AlmaPay rootless Podman wrappers.
# shellcheck shell=bash

almapay_service_uid() {
  id -u "${ALMAPAY_USER}" 2>/dev/null || almapay_die "service user ${ALMAPAY_USER} does not exist"
}

almapay_runtime_env_exports() {
  local uid
  uid="$(almapay_service_uid)"
  printf 'XDG_RUNTIME_DIR=/run/user/%s\n' "${uid}"
  printf 'PODMAN_COMPOSE_PROVIDER=%s\n' "${ALMAPAY_COMPOSE_PROVIDER_PATH}"
  printf 'HOME=%s\n' "${ALMAPAY_DATA_ROOT}"
}

# Run a command as the almapay service user with rootless Podman environment.
# Never use sudo podman.
almapay_as_service() {
  local uid
  uid="$(almapay_service_uid)"

  if almapay_is_service_user; then
    env \
      XDG_RUNTIME_DIR="/run/user/${uid}" \
      PODMAN_COMPOSE_PROVIDER="${ALMAPAY_COMPOSE_PROVIDER_PATH}" \
      HOME="${ALMAPAY_DATA_ROOT}" \
      "$@"
    return $?
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    # Drop privileges; do not run Podman as root.
    sudo -u "${ALMAPAY_USER}" -H env \
      XDG_RUNTIME_DIR="/run/user/${uid}" \
      PODMAN_COMPOSE_PROVIDER="${ALMAPAY_COMPOSE_PROVIDER_PATH}" \
      HOME="${ALMAPAY_DATA_ROOT}" \
      "$@"
    return $?
  fi

  almapay_die "must run as root (to drop to ${ALMAPAY_USER}) or as ${ALMAPAY_USER}"
}

almapay_assert_no_docker() {
  local cmdline
  cmdline="$*"
  if [[ "${cmdline}" =~ (^|[[:space:]])docker($|[[:space:]]) ]] || \
     [[ "${cmdline}" =~ docker-compose ]] || \
     [[ "${cmdline}" =~ sudo[[:space:]]+podman ]]; then
    almapay_die "refusing Docker or rootful Podman invocation: ${cmdline}"
  fi
}

almapay_podman() {
  almapay_assert_no_docker "podman" "$@"
  almapay_as_service podman "$@"
}

almapay_podman_compose() {
  almapay_assert_no_docker "podman" "compose" "$@"
  almapay_require_compose_provider
  almapay_as_service podman compose "$@"
}

almapay_require_compose_provider() {
  local provider resolved expected_version actual_version
  provider="${PODMAN_COMPOSE_PROVIDER:-${ALMAPAY_COMPOSE_PROVIDER_PATH}}"
  [[ -x "${provider}" ]] || almapay_die "Compose provider missing or not executable: ${provider}"
  resolved="$(basename "$(readlink -f "${provider}" 2>/dev/null || printf '%s' "${provider}")")"
  if [[ "${resolved}" == "docker-compose" ]] || [[ "${provider}" == *docker-compose* ]]; then
    almapay_die "unsupported Compose provider docker-compose; require ${ALMAPAY_COMPOSE_PROVIDER_PATH}"
  fi
  if [[ "${provider}" != "${ALMAPAY_COMPOSE_PROVIDER_PATH}" ]]; then
    almapay_die "Compose provider must be exactly ${ALMAPAY_COMPOSE_PROVIDER_PATH} (got ${provider})"
  fi
  expected_version="$(almapay_lock_get runtime.compose_provider_version)"
  actual_version="$("${provider}" --version 2>&1)"
  [[ "${actual_version}" == *"${expected_version}"* ]] ||
    almapay_die "Compose provider version mismatch: expected ${expected_version}, got $(almapay_redact "${actual_version}")"
}

almapay_compose_file() {
  printf '%s\n' "${ALMAPAY_DATA_ROOT}/compose/docker-compose.generated.yml"
}

almapay_env_file() {
  printf '%s\n' "${ALMAPAY_DATA_ROOT}/.env"
}
