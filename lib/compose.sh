# AlmaPay Compose generation, rendering, pulling, and semantic validation.
# shellcheck shell=bash

almapay_compose_workdir() {
  printf '%s\n' "${ALMAPAY_DATA_ROOT}/compose"
}

almapay_compose_generated_raw() {
  printf '%s\n' "$(almapay_upstream_dir)/Generated/docker-compose.generated.yml"
}

almapay_compose_model_script() {
  printf '%s\n' "${ALMAPAY_ROOT}/scripts/compose_model.py"
}

almapay_compose_security_validate() {
  local compose_file="$1"
  [[ -f "${compose_file}" ]] ||
    almapay_die "compose file missing: ${compose_file}"
  almapay_require_yaml
  python3 "$(almapay_compose_model_script)" validate \
    --input "${compose_file}" \
    --lock "$(almapay_lockfile_path)" ||
    almapay_die "rendered Compose failed semantic security validation"
  almapay_info "compose semantic security validation passed: ${compose_file}"
}

almapay_render_compose_model() {
  local source_file="$1"
  local output_file="$2"
  local temporary
  almapay_require_yaml
  temporary="$(mktemp "$(dirname "${output_file}")/.compose.XXXXXX")"
  if ! python3 "$(almapay_compose_model_script)" render \
    --input "${source_file}" \
    --lock "$(almapay_lockfile_path)" \
    --monero-mode "${ALMAPAY_MONERO_MODE}" \
    --output "${temporary}"; then
    rm -f "${temporary}"
    almapay_die "failed to render the AlmaPay Compose model"
  fi
  chmod 0640 "${temporary}"
  mv "${temporary}" "${output_file}"
}

almapay_compose_semantic_hash() {
  local compose_file="$1"
  python3 - "${compose_file}" <<'PY'
import hashlib
import json
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    model = yaml.safe_load(handle)
canonical = json.dumps(
    model, sort_keys=True, separators=(",", ":"), ensure_ascii=True
).encode()
print(hashlib.sha256(canonical).hexdigest())
PY
}

almapay_generator_build_context() {
  printf '%s\n' "${ALMAPAY_DATA_ROOT}/generator-build-context"
}

almapay_prepare_generator_context() {
  local source context dockerfile builder runtime expected_hash actual_hash
  source="$(almapay_upstream_dir)/docker-compose-generator"
  context="$(almapay_generator_build_context)"
  dockerfile="${context}/Dockerfile"
  builder="$(almapay_lock_get btcpayserver_docker.generator.builder_base_image)"
  runtime="$(almapay_lock_get btcpayserver_docker.generator.runtime_base_image)"
  expected_hash="$(almapay_lock_get btcpayserver_docker.generator.dockerfile_sha256)"

  [[ "${builder}" =~ @sha256:[0-9a-f]{64}$ ]] ||
    almapay_die "generator builder base image is not digest-pinned"
  [[ "${runtime}" =~ @sha256:[0-9a-f]{64}$ ]] ||
    almapay_die "generator runtime base image is not digest-pinned"
  [[ "${expected_hash}" =~ ^[0-9a-f]{64}$ ]] ||
    almapay_die "generator Dockerfile checksum is unresolved"
  [[ -f "${source}/Dockerfile" ]] ||
    almapay_die "generator Dockerfile missing: ${source}/Dockerfile"
  actual_hash="$(almapay_sha256_file "${source}/Dockerfile")"
  [[ "${actual_hash}" == "${expected_hash}" ]] ||
    almapay_die "pinned generator Dockerfile checksum mismatch"

  rm -rf "${context}"
  cp -a "${source}" "${context}"
  python3 - "${dockerfile}" "${builder}" "${runtime}" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
builder, runtime = sys.argv[2:]
text = path.read_text(encoding="utf-8")
lines = text.splitlines()
from_indices = [i for i, line in enumerate(lines) if re.match(r"^\s*FROM\s+", line, re.I)]
if len(from_indices) != 2:
    raise SystemExit(f"expected exactly two FROM instructions, found {len(from_indices)}")
for index, image in zip(from_indices, (builder, runtime)):
    match = re.match(
        r"^(\s*FROM\s+(?:--platform=\S+\s+)?)(\S+)(.*)$",
        lines[index],
        re.I,
    )
    if not match:
        raise SystemExit("unable to parse FROM instruction")
    lines[index] = f"{match.group(1)}{image}{match.group(3)}"
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

almapay_pull_generator_bases() {
  local builder runtime
  builder="$(almapay_lock_get btcpayserver_docker.generator.builder_base_image)"
  runtime="$(almapay_lock_get btcpayserver_docker.generator.runtime_base_image)"
  almapay_info "pulling digest-pinned generator base images"
  podman pull "${builder}"
  podman pull "${runtime}"
}

almapay_build_generator() {
  local image expected_digest actual_digest
  almapay_require_service_user
  almapay_require_release_lock
  almapay_fetch_upstream
  almapay_prepare_generator_context
  image="localhost/almapay/docker-compose-generator:pinned"
  expected_digest="$(almapay_lock_get btcpayserver_docker.generator.image_digest)"
  [[ "${expected_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    almapay_die "generator image digest is unresolved"

  almapay_pull_generator_bases
  almapay_info "building generator from pinned source and digest-pinned bases"
  podman build \
    --pull=never \
    --timestamp 0 \
    -t "${image}" \
    -f "$(almapay_generator_build_context)/Dockerfile" \
    "$(almapay_generator_build_context)"
  actual_digest="$(podman image inspect --format '{{if .Digest}}{{.Digest}}{{else}}{{.Id}}{{end}}' "${image}")"
  [[ "${actual_digest}" == "${expected_digest}" ]] ||
    almapay_die "built generator digest ${actual_digest} does not match lock ${expected_digest}"
}

# Candidate-lock research step. It never edits or promotes the lock.
almapay_research_generator() {
  local status dockerfile actual_hash image actual_digest
  almapay_require_service_user
  status="$(almapay_assert_lock_status)"
  [[ "${status}" == "candidate" ]] ||
    almapay_die "research-generator is only for candidate locks"
  almapay_fetch_upstream
  dockerfile="$(almapay_upstream_dir)/docker-compose-generator/Dockerfile"
  actual_hash="$(almapay_sha256_file "${dockerfile}")"
  printf 'dockerfile_sha256: "%s"\n' "${actual_hash}"
  python3 - "${dockerfile}" <<'PY'
import re
import sys
from pathlib import Path

for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    match = re.match(r"^\s*FROM\s+(?:--platform=\S+\s+)?(\S+)", line, re.I)
    if match:
        print(f"upstream_base_reference: {match.group(1)}")
PY

  if ! almapay_lock_has_placeholders; then
    almapay_die "candidate lock unexpectedly has no placeholders; validate and promote it instead"
  fi
  if [[ "$(almapay_lock_get btcpayserver_docker.generator.dockerfile_sha256)" != "${actual_hash}" ]]; then
    almapay_warn "record and review dockerfile_sha256, then rerun after pinning both base-image digests"
    return 0
  fi
  almapay_prepare_generator_context
  almapay_pull_generator_bases
  image="localhost/almapay/docker-compose-generator:pinned"
  podman build --pull=never --timestamp 0 -t "${image}" \
    -f "$(almapay_generator_build_context)/Dockerfile" \
    "$(almapay_generator_build_context)"
  actual_digest="$(podman image inspect --format '{{if .Digest}}{{.Digest}}{{else}}{{.Id}}{{end}}' "${image}")"
  printf 'image_digest: "%s"\n' "${actual_digest}"
  almapay_warn "review and record the generator digest; this command did not modify upstream.lock"
}

almapay_ensure_generator() {
  local image expected_digest actual_digest
  image="localhost/almapay/docker-compose-generator:pinned"
  expected_digest="$(almapay_lock_get btcpayserver_docker.generator.image_digest)"
  if ! podman image exists "${image}"; then
    almapay_build_generator
    return
  fi
  actual_digest="$(podman image inspect --format '{{if .Digest}}{{.Digest}}{{else}}{{.Id}}{{end}}' "${image}")"
  [[ "${actual_digest}" == "${expected_digest}" ]] ||
    almapay_die "local generator digest differs from upstream.lock; remove it and rebuild"
}

almapay_run_generator() {
  local upstream generator_image
  local podman_args=()
  upstream="$(almapay_upstream_dir)"
  generator_image="localhost/almapay/docker-compose-generator:pinned"
  almapay_generator_env
  mkdir -p "${upstream}/Generated"
  rm -f "${upstream}/Generated/pull-images.sh" \
    "${upstream}/Generated/save-images.sh"

  podman_args=(
    run --rm --network none --read-only
    --tmpfs /tmp:rw,noexec,nosuid,nodev
    -v "${upstream}/Generated:/app/Generated:Z"
    -v "${upstream}/docker-compose-generator/docker-fragments:/app/docker-fragments:ro,Z"
    -v "${upstream}/docker-compose-generator/crypto-definitions.json:/app/crypto-definitions.json:ro,Z"
    -e "BTCPAY_HOST=${BTCPAY_HOST}"
    -e "BTCPAY_PROTOCOL=${BTCPAY_PROTOCOL}"
    -e "BTCPAYGEN_CRYPTO1=${BTCPAYGEN_CRYPTO1}"
    -e "BTCPAYGEN_REVERSEPROXY=${BTCPAYGEN_REVERSEPROXY}"
    -e "BTCPAYGEN_LIGHTNING=${BTCPAYGEN_LIGHTNING}"
    -e "BTCPAYGEN_EXCLUDE_FRAGMENTS=${BTCPAYGEN_EXCLUDE_FRAGMENTS}"
    -e "BTCPAYGEN_ADDITIONAL_FRAGMENTS=${BTCPAYGEN_ADDITIONAL_FRAGMENTS}"
    -e "BTCPAY_IMAGE=${BTCPAY_IMAGE}"
    -e "NBITCOIN_NETWORK=${NBITCOIN_NETWORK}"
    -e "NOREVERSEPROXY_HTTP_PORT=${NOREVERSEPROXY_HTTP_PORT}"
  )
  if [[ -n "${BTCPAYGEN_CRYPTO2:-}" ]]; then
    podman_args+=(-e "BTCPAYGEN_CRYPTO2=${BTCPAYGEN_CRYPTO2}")
  fi
  podman_args+=("${generator_image}")
  podman "${podman_args[@]}"

  rm -f "${upstream}/Generated/pull-images.sh" \
    "${upstream}/Generated/save-images.sh"
}

almapay_generate_compose() {
  local workdir raw final previous
  almapay_require_service_user
  almapay_require_release_lock
  almapay_require_secrets
  workdir="$(almapay_compose_workdir)"
  final="${workdir}/docker-compose.generated.yml"
  previous="${final}.prev"
  mkdir -p "${workdir}"

  almapay_fetch_upstream
  almapay_ensure_generator
  almapay_run_generator
  raw="$(almapay_compose_generated_raw)"
  [[ -f "${raw}" ]] || almapay_die "generator did not produce ${raw}"

  if [[ -f "${final}" ]]; then
    cp -a "${final}" "${previous}"
  fi
  almapay_render_compose_model "${raw}" "${final}"
  almapay_compose_security_validate "${final}"
  almapay_compose_semantic_hash "${final}" >"${final}.sha256"
  chmod 0640 "${final}.sha256"

  almapay_runtime_env_contents >"$(almapay_env_file)"
  chmod 0640 "$(almapay_env_file)"
  if [[ -f "${previous}" ]]; then
    diff -u "${previous}" "${final}" || true
  fi
  almapay_info "wrote validated Compose model: ${final}"
}

almapay_pull_locked_images() {
  local image
  almapay_require_service_user
  almapay_require_release_lock
  while IFS= read -r image; do
    [[ -n "${image}" ]] || continue
    almapay_info "pulling locked image ${image}"
    podman pull "${image}"
  done < <(almapay_locked_runtime_images)
}
