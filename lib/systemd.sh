# AlmaPay user-systemd persistence.
# shellcheck shell=bash

almapay_systemd_unit_path() {
  printf '%s\n' "${ALMAPAY_DATA_ROOT}/.config/systemd/user/almapay.service"
}

almapay_install_systemd_unit() {
  local uid unit compose_file env_file
  almapay_require_service_user
  almapay_require_secrets
  uid="$(almapay_service_uid)"
  unit="$(almapay_systemd_unit_path)"
  compose_file="$(almapay_compose_file)"
  env_file="$(almapay_env_file)"

  mkdir -p "$(dirname "${unit}")"
  cat >"${unit}" <<EOF
[Unit]
Description=AlmaPay BTCPay Server (Podman Compose)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${ALMAPAY_DATA_ROOT}
Environment=XDG_RUNTIME_DIR=/run/user/${uid}
Environment=PODMAN_COMPOSE_PROVIDER=${ALMAPAY_COMPOSE_PROVIDER_PATH}
Environment=HOME=${ALMAPAY_DATA_ROOT}
EnvironmentFile=${ALMAPAY_SECRETS_PATH}
ExecStart=/usr/bin/podman compose -f ${compose_file} --env-file ${env_file} up -d --remove-orphans
ExecStop=/usr/bin/podman compose -f ${compose_file} --env-file ${env_file} down
TimeoutStartSec=600

[Install]
WantedBy=default.target
EOF
  chmod 0644 "${unit}"
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify --user "${unit}" >/dev/null ||
      almapay_die "generated user systemd unit failed validation"
  fi
  almapay_info "wrote user unit: ${unit}"
}

almapay_systemd_reload_enable() {
  local uid
  uid="$(almapay_service_uid)"
  almapay_as_service bash -lc "
    set -euo pipefail
    export XDG_RUNTIME_DIR=/run/user/${uid}
    systemctl --user daemon-reload
    systemctl --user enable almapay.service
  "
}

almapay_systemd_start() {
  local uid
  uid="$(almapay_service_uid)"
  almapay_as_service bash -lc "
    set -euo pipefail
    export XDG_RUNTIME_DIR=/run/user/${uid}
    systemctl --user start almapay.service
  "
}

almapay_systemd_stop() {
  local uid
  uid="$(almapay_service_uid)"
  almapay_as_service bash -lc "
    set -euo pipefail
    export XDG_RUNTIME_DIR=/run/user/${uid}
    systemctl --user stop almapay.service
  "
}

almapay_systemd_status() {
  local uid
  uid="$(almapay_service_uid)"
  almapay_as_service bash -lc "
    export XDG_RUNTIME_DIR=/run/user/${uid}
    systemctl --user status almapay.service --no-pager || true
  "
}
