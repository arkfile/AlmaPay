# AlmaPay upstream lockfile and source acquisition.
# shellcheck shell=bash

almapay_lockfile_path() {
  printf '%s\n' "${ALMAPAY_LOCKFILE:-${ALMAPAY_ROOT}/upstream.lock}"
}

almapay_lock_get() {
  # Minimal YAML key reader for flat and one-level nested keys used in tests/ops.
  # Usage: almapay_lock_get btcpayserver_docker.commit
  local key="$1"
  local lock
  lock="$(almapay_lockfile_path)"
  [[ -f "${lock}" ]] || almapay_die "lockfile missing: ${lock}"

  python3 - "${lock}" "${key}" <<'PY' 2>/dev/null || almapay_lock_get_awk "${lock}" "${key}"
import sys
path, key = sys.argv[1], sys.argv[2]
try:
    import yaml  # type: ignore
except Exception:
    sys.exit(2)
with open(path, encoding="utf-8") as f:
    data = yaml.safe_load(f)
cur = data
for part in key.split("."):
    if not isinstance(cur, dict) or part not in cur:
        sys.exit(1)
    cur = cur[part]
if isinstance(cur, (dict, list)):
    sys.exit(1)
print(cur)
PY
}

almapay_lock_get_awk() {
  local lock="$1"
  local key="$2"
  # Fallback for simple leaf keys without requiring PyYAML.
  case "${key}" in
    btcpayserver_docker.commit)
      awk '/^btcpayserver_docker:/{p=1} p&&/commit:/{gsub(/[" ]/, "", $2); print $2; exit}' "${lock}"
      ;;
    images.btcpayserver.reference)
      awk '/^  btcpayserver:/{p=1} p&&/reference:/{gsub(/[" ]/, "", $2); print $2; exit}' "${lock}"
      ;;
    images.bitcoin_core.reference)
      awk '/^  bitcoin_core:/{p=1} p&&/reference:/{gsub(/[" ]/, "", $2); print $2; exit}' "${lock}"
      ;;
    images.btcpayserver.linux_amd64_digest)
      awk '/^  btcpayserver:/{p=1} p&&/linux_amd64_digest:/{gsub(/[" ]/, "", $2); print $2; exit}' "${lock}"
      ;;
    images.bitcoin_core.linux_amd64_digest)
      awk '/^  bitcoin_core:/{p=1} p&&/linux_amd64_digest:/{gsub(/[" ]/, "", $2); print $2; exit}' "${lock}"
      ;;
    runtime.compose_provider)
      awk '/^runtime:/{p=1} p&&/compose_provider:/{gsub(/[" ]/, "", $2); print $2; exit}' "${lock}"
      ;;
    minimum_versions.btcpayserver)
      awk '/^minimum_versions:/{p=1} p&&/btcpayserver:/{gsub(/[" ]/, "", $2); print $2; exit}' "${lock}"
      ;;
    minimum_versions.bitcoin_core)
      awk '/^minimum_versions:/{p=1} p&&/bitcoin_core:/{gsub(/[" ]/, "", $2); print $2; exit}' "${lock}"
      ;;
    *)
      almapay_die "lock key not supported by awk fallback: ${key}"
      ;;
  esac
}

almapay_upstream_dir() {
  printf '%s\n' "${ALMAPAY_DATA_ROOT}/btcpayserver-docker"
}

almapay_fetch_upstream() {
  local commit dir
  commit="$(almapay_lock_get btcpayserver_docker.commit)"
  dir="$(almapay_upstream_dir)"

  almapay_info "fetching btcpayserver-docker @ ${commit}"
  if [[ ! -d "${dir}/.git" ]]; then
    almapay_as_service git clone https://github.com/btcpayserver/btcpayserver-docker.git "${dir}"
  fi

  almapay_as_service bash -lc "
    set -euo pipefail
    cd '$(printf '%q' "${dir}")'
    git fetch --depth 1 origin '${commit}' || git fetch origin '${commit}'
    git checkout --detach '${commit}'
    test \"\$(git rev-parse HEAD)\" = '${commit}'
    test -z \"\$(git status --porcelain)\"
    test \"\$(git remote get-url origin)\" = 'https://github.com/btcpayserver/btcpayserver-docker.git'
  "
}

almapay_assert_lock_status() {
  local status
  status="$(awk '/^status:/{gsub(/[" ]/, "", $2); print $2; exit}' "$(almapay_lockfile_path)")"
  case "${status}" in
    candidate|staging|validated|production)
      printf '%s\n' "${status}"
      ;;
    *)
      almapay_die "upstream.lock status must be candidate, staging, validated, or production"
      ;;
  esac
}

almapay_lock_has_placeholders() {
  grep -Eq 'PENDING|REPLACE' "$(almapay_lockfile_path)"
}

almapay_lock_install_mode() {
  awk '
    /^runtime:/ { in_runtime=1; next }
    in_runtime && /^[^ ]/ { in_runtime=0 }
    in_runtime && /^  install_mode:/ {
      gsub(/[" ]/, "", $2)
      print $2
      exit
    }
  ' "$(almapay_lockfile_path)"
}

almapay_validate_repo_metadata() {
  grep -Eq 'signing_key_fingerprint:[[:space:]]*"?[0-9A-Fa-f]{40}"?$' \
    "$(almapay_lockfile_path)" ||
    almapay_die "lock lacks a verified repository signing-key fingerprint"
  grep -Eq 'repomd_sha256:[[:space:]]*"?[0-9a-f]{64}"?$' \
    "$(almapay_lockfile_path)" ||
    almapay_die "lock lacks a verified repository metadata checksum"
}

almapay_validate_bootstrap_lock_shape() {
  local packages=()
  mapfile -t packages < <(almapay_locked_host_packages)
  ((${#packages[@]} > 0)) ||
    almapay_die "lock has no runtime.host_packages"

  local install_mode
  install_mode="$(almapay_lock_install_mode)"
  if [[ "${install_mode}" == "repos" ]]; then
    almapay_validate_repo_metadata
    return 0
  fi

  almapay_validate_release_lock_shape
}

almapay_require_bootstrap_lock() {
  local status
  status="$(almapay_assert_lock_status)"
  case "${status}" in
    staging|validated|production) ;;
    candidate)
      almapay_die "upstream.lock is candidate-only; run lock-research on this host or promote the lock"
      ;;
  esac
  almapay_validate_bootstrap_lock_shape
}

almapay_require_runtime_lock() {
  almapay_require_bootstrap_lock
  if almapay_lock_has_placeholders; then
    almapay_die "lock contains unresolved PENDING/REPLACE values; rerun lock-research --build-generator"
  fi
  almapay_validate_generator_lock_fields
}

almapay_validate_generator_lock_fields() {
  local digest builder runtime dockerfile
  digest="$(almapay_lock_get btcpayserver_docker.generator.image_digest 2>/dev/null || true)"
  builder="$(almapay_lock_get btcpayserver_docker.generator.builder_base_image 2>/dev/null || true)"
  runtime="$(almapay_lock_get btcpayserver_docker.generator.runtime_base_image 2>/dev/null || true)"
  dockerfile="$(almapay_lock_get btcpayserver_docker.generator.dockerfile_sha256 2>/dev/null || true)"
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    almapay_die "lock generator image_digest is missing or invalid"
  [[ "${builder}" =~ @sha256:[0-9a-f]{64}$ ]] ||
    almapay_die "lock generator builder_base_image is not digest-pinned"
  [[ "${runtime}" =~ @sha256:[0-9a-f]{64}$ ]] ||
    almapay_die "lock generator runtime_base_image is not digest-pinned"
  [[ "${dockerfile}" =~ ^[0-9a-f]{64}$ ]] ||
    almapay_die "lock generator dockerfile_sha256 is missing or invalid"
}

almapay_require_release_lock() {
  almapay_require_runtime_lock
}

almapay_require_yaml() {
  python3 -c 'import yaml' >/dev/null 2>&1 ||
    almapay_die "Python 3 with PyYAML is required (install the exact locked python3-pyyaml package)"
}

almapay_lock_image_field() {
  local image_key="$1"
  local field="$2"
  python3 - "$(almapay_lockfile_path)" "${image_key}" "${field}" <<'PY'
import sys
import yaml

path, key, field = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = yaml.safe_load(handle)
try:
    value = data["images"][key][field]
except (KeyError, TypeError):
    raise SystemExit(f"missing images.{key}.{field} in {path}")
if not isinstance(value, str) or not value:
    raise SystemExit(f"invalid images.{key}.{field} in {path}")
print(value)
PY
}

almapay_lock_image_runtime_ref() {
  local image_key="$1"
  local reference digest repository
  almapay_require_yaml
  reference="$(almapay_lock_image_field "${image_key}" reference)"
  digest="$(almapay_lock_image_field "${image_key}" linux_amd64_digest)"
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    almapay_die "invalid linux/amd64 digest for ${image_key}: ${digest}"
  repository="${reference%:*}"
  printf '%s@%s\n' "${repository}" "${digest}"
}

almapay_locked_runtime_images() {
  almapay_require_yaml
  python3 - "$(almapay_lockfile_path)" <<'PY'
import re
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    data = yaml.safe_load(handle)
for key, item in data.get("images", {}).items():
    reference = item.get("reference", "")
    digest = item.get("linux_amd64_digest", "")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise SystemExit(f"invalid digest for images.{key}")
    repository = reference.rsplit(":", 1)[0]
    print(f"{repository}@{digest}")
PY
}

almapay_locked_host_packages() {
  awk '
    /^  host_packages:$/ { in_packages=1; next }
    in_packages && /^    - / {
      value=$0
      sub(/^    - /, "", value)
      gsub(/^"|"$/, "", value)
      print value
      next
    }
    in_packages { exit }
  ' "$(almapay_lockfile_path)"
}

almapay_locked_package_artifacts() {
  awk '
    function clean(value) {
      gsub(/^"|"$/, "", value)
      return value
    }
    function emit() {
      if (nevra != "") print clean(nevra) "\t" clean(url) "\t" clean(sha)
    }
    /^  package_artifacts:$/ { in_artifacts=1; next }
    in_artifacts && /^    - nevra:/ {
      emit()
      nevra=$0; sub(/^    - nevra:[[:space:]]*/, "", nevra)
      url=""; sha=""
      next
    }
    in_artifacts && /^      source_url:/ {
      url=$0; sub(/^      source_url:[[:space:]]*/, "", url); next
    }
    in_artifacts && /^      sha256:/ {
      sha=$0; sub(/^      sha256:[[:space:]]*/, "", sha); next
    }
    in_artifacts && /^[^ ]/ { emit(); exit }
    END { if (in_artifacts) emit() }
  ' "$(almapay_lockfile_path)" | awk '!seen[$0]++'
}

almapay_validate_release_lock_shape() {
  local package artifact artifact_nevra artifact_url artifact_sha
  local packages=()
  local artifacts=()
  mapfile -t packages < <(almapay_locked_host_packages)
  mapfile -t artifacts < <(almapay_locked_package_artifacts)
  ((${#packages[@]} > 0)) ||
    almapay_die "release lock has no runtime.host_packages"
  ((${#artifacts[@]} == ${#packages[@]})) ||
    almapay_die "release lock must have one package_artifact per host package"

  for package in "${packages[@]}"; do
    local found=0
    for artifact in "${artifacts[@]}"; do
      IFS=$'\t' read -r artifact_nevra artifact_url artifact_sha <<<"${artifact}"
      if [[ "${artifact_nevra}" == "${package}" ]]; then
        found=1
        [[ "${artifact_url}" =~ ^https:// ]] ||
          almapay_die "package artifact URL must be HTTPS for ${package}"
        [[ "${artifact_sha}" =~ ^[0-9a-f]{64}$ ]] ||
          almapay_die "package artifact SHA-256 is invalid for ${package}"
      fi
    done
    ((found == 1)) ||
      almapay_die "package artifact missing for ${package}"
  done

  grep -Eq 'signing_key_fingerprint:[[:space:]]*"?[0-9A-Fa-f]{40}"?$' \
    "$(almapay_lockfile_path)" ||
    almapay_die "release lock lacks a verified repository signing-key fingerprint"
  grep -Eq 'repomd_sha256:[[:space:]]*"?[0-9a-f]{64}"?$' \
    "$(almapay_lockfile_path)" ||
    almapay_die "release lock lacks a verified repository metadata checksum"
}
