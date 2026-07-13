# AlmaPay application backup gate.
# shellcheck shell=bash

almapay_backup() {
  almapay_require_service_user
  almapay_die "backup is not implemented: AlmaPay will not create a misleading config-only archive; production and update remain blocked until logical database, application/plugin, custody material, encryption, manifest authentication, and restore verification are implemented"
}
