# AlmaPay host lock research — write a staging lock for this VPS.
# shellcheck shell=bash

ALMAPAY_HOST_PACKAGE_NAMES=(
  podman
  podman-compose
  caddy
  python3
  python3-pyyaml
  git
  curl
  jq
  shadow-utils
  firewalld
  container-selinux
)

almapay_lock_research_template_path() {
  printf '%s\n' "${ALMAPAY_ROOT}/upstream.lock"
}

almapay_rpm_nevra() {
  local name="$1"
  rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "${name}" 2>/dev/null ||
    almapay_die "package is not installed: ${name}"
}

almapay_lock_research_repo_metadata() {
  local repomd="" keyid=""
  if command -v dnf >/dev/null 2>&1; then
    repomd="$(python3 - <<'PY'
import glob
import hashlib

candidates = sorted(glob.glob("/var/cache/dnf/*/repodata/repomd.xml"))
if not candidates:
    raise SystemExit(1)
with open(candidates[-1], "rb") as handle:
    print(hashlib.sha256(handle.read()).hexdigest())
PY
    )" || true
  fi
  keyid="$(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' gpg-pubkey 2>/dev/null |
    while read -r entry; do
      summary="$(rpm -q --qf '%{SUMMARY}\n' "${entry}" 2>/dev/null || true)"
      if [[ "${summary}" == *AlmaLinux* || "${summary}" == *almalinux* ]]; then
        sed -E 's/^gpg-pubkey-//; s/-[0-9a-f]+$//' <<<"${entry}"
        break
      fi
    done)"
  [[ -n "${repomd}" && "${repomd}" =~ ^[0-9a-f]{64}$ ]] ||
    almapay_die "unable to determine repository repomd checksum; run dnf makecache as root"
  [[ -n "${keyid}" && "${keyid}" =~ ^[0-9A-Fa-f]{40}$ ]] ||
    almapay_die "unable to determine AlmaLinux signing-key fingerprint"
  printf '%s\t%s\n' "${keyid^^}" "${repomd}"
}

almapay_lock_research_install_packages() {
  almapay_require_cmd dnf
  almapay_info "lock-research: installing host package set from AlmaLinux repositories"
  dnf install -y "${ALMAPAY_HOST_PACKAGE_NAMES[@]}" ||
    almapay_die "dnf install of the AlmaPay host package set failed"
}

almapay_lock_research_gather_packages() {
  local name
  for name in "${ALMAPAY_HOST_PACKAGE_NAMES[@]}"; do
    almapay_rpm_nevra "${name}"
  done
}

almapay_lock_research_write_base() {
  local output="$1"
  local template packages repo_key repo_repomd
  template="$(almapay_lock_research_template_path)"
  [[ -f "${template}" ]] || almapay_die "candidate template lock missing: ${template}"

  mapfile -t packages < <(almapay_lock_research_gather_packages)
  IFS=$'\t' read -r repo_key repo_repomd <<<"$(almapay_lock_research_repo_metadata)"

  python3 - "${template}" "${output}" "${repo_key}" "${repo_repomd}" "${packages[@]}" <<'PY'
import sys
from pathlib import Path

import yaml

template_path, output_path, repo_key, repo_repomd, *packages = sys.argv
with open(template_path, encoding="utf-8") as handle:
    data = yaml.safe_load(handle)

data["status"] = "staging"
runtime = data.setdefault("runtime", {})
runtime["install_mode"] = "repos"
runtime["host_packages"] = packages
runtime["package_artifacts"] = []
runtime["package_repositories"] = [
    {
        "id": "almalinux-enabled-base",
        "signing_key_fingerprint": repo_key,
        "repomd_sha256": repo_repomd,
    }
]

for package in packages:
    if package.startswith("podman-compose-"):
        runtime["compose_provider_nevra"] = package
    if package.startswith("podman-"):
        runtime["podman_nevra"] = package

Path(output_path).parent.mkdir(parents=True, exist_ok=True)
with open(output_path, "w", encoding="utf-8") as handle:
    yaml.safe_dump(data, handle, sort_keys=False, default_flow_style=False)
PY

  chmod 0640 "${output}"
  almapay_info "lock-research: wrote staging host lock ${output}"
}

almapay_build_generator_for_lock() {
  local lock="$1"
  export ALMAPAY_LOCKFILE="${lock}"
  almapay_fetch_upstream
  almapay_prepare_generator_context
  almapay_pull_generator_bases
  podman build --pull=never --timestamp 0 \
    -t localhost/almapay/docker-compose-generator:pinned \
    -f "$(almapay_generator_build_context)/Dockerfile" \
    "$(almapay_generator_build_context)"
  podman image inspect --format '{{if .Digest}}{{.Digest}}{{else}}{{.Id}}{{end}}' \
    localhost/almapay/docker-compose-generator:pinned
}

almapay_lock_research_merge_generator() {
  local lock="$1"
  local dockerfile_hash builder runtime builder_digest runtime_digest image_digest
  almapay_require_service_user
  export ALMAPAY_LOCKFILE="${lock}"

  almapay_fetch_upstream
  dockerfile_hash="$(almapay_sha256_file "$(almapay_upstream_dir)/docker-compose-generator/Dockerfile")"
  mapfile -t _from_refs < <(python3 - "$(almapay_upstream_dir)/docker-compose-generator/Dockerfile" <<'PY'
import re
import sys
from pathlib import Path

for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    match = re.match(r"^\s*FROM\s+(?:--platform=\S+\s+)?(\S+)", line, re.I)
    if match:
        print(match.group(1))
PY
  )
  ((${#_from_refs[@]} == 2)) || almapay_die "generator Dockerfile must contain exactly two FROM instructions"
  builder="${_from_refs[0]}"
  runtime="${_from_refs[1]}"

  if [[ "${builder}" != *@sha256:* ]]; then
    almapay_info "lock-research: pulling generator builder base ${builder}"
    podman pull "${builder}"
    builder_digest="$(podman inspect --format '{{.Digest}}' "${builder}" 2>/dev/null ||
      podman inspect --format '{{.Id}}' "${builder}")"
    builder="${builder%%@*}@${builder_digest}"
  fi
  if [[ "${runtime}" != *@sha256:* ]]; then
    almapay_info "lock-research: pulling generator runtime base ${runtime}"
    podman pull "${runtime}"
    runtime_digest="$(podman inspect --format '{{.Digest}}' "${runtime}" 2>/dev/null ||
      podman inspect --format '{{.Id}}' "${runtime}")"
    runtime="${runtime%%@*}@${runtime_digest}"
  fi

  python3 - "${lock}" "${dockerfile_hash}" "${builder}" "${runtime}" <<'PY'
import sys
import yaml

path, dockerfile_hash, builder, runtime = sys.argv[1:5]
with open(path, encoding="utf-8") as handle:
    data = yaml.safe_load(handle)
gen = data.setdefault("btcpayserver_docker", {}).setdefault("generator", {})
gen["dockerfile_sha256"] = dockerfile_hash
gen["builder_base_image"] = builder
gen["runtime_base_image"] = runtime
with open(path, "w", encoding="utf-8") as handle:
    yaml.safe_dump(data, handle, sort_keys=False, default_flow_style=False)
PY

  image_digest="$(almapay_build_generator_for_lock "${lock}")"
  python3 - "${lock}" "${image_digest}" <<'PY'
import sys
import yaml

path, image_digest = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    data = yaml.safe_load(handle)
data["btcpayserver_docker"]["generator"]["image_digest"] = image_digest
with open(path, "w", encoding="utf-8") as handle:
    yaml.safe_dump(data, handle, sort_keys=False, default_flow_style=False)
PY
  almapay_info "lock-research: recorded generator digest in ${lock}"
}

almapay_lock_research() {
  local output="${ALMAPAY_HOST_LOCK_PATH}"
  local install_packages=0
  local build_generator=0

  while ((${#@} > 0)); do
    case "$1" in
      --write)
        shift
        output="${1:-}"
        [[ -n "${output}" ]] || almapay_die "--write requires a path"
        shift
        ;;
      --install-packages)
        install_packages=1
        shift
        ;;
      --build-generator)
        build_generator=1
        shift
        ;;
      *)
        almapay_die "unknown lock-research argument: $1"
        ;;
    esac
  done

  if [[ "${install_packages}" -eq 1 ]]; then
    [[ "$(id -u)" -eq 0 ]] ||
      almapay_die "lock-research --install-packages requires root"
    almapay_lock_research_install_packages
  fi

  if ! almapay_lock_research_gather_packages >/dev/null 2>&1; then
    almapay_die "host packages missing; rerun as root with --install-packages"
  fi

  almapay_lock_research_write_base "${output}"
  almapay_info "lock-research: export ALMAPAY_LOCKFILE=${output} for later commands"

  if [[ "${build_generator}" -eq 1 ]]; then
    almapay_require_service_user
    almapay_lock_research_merge_generator "${output}"
  fi
}
