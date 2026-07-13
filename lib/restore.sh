# AlmaPay application restore gate.
# shellcheck shell=bash

almapay_restore() {
  almapay_require_service_user
  almapay_die "restore is not implemented: no archive will be extracted until authenticated manifests, traversal-safe extraction, empty-target enforcement, database/application restoration, and post-restore verification are implemented and tested"
}
