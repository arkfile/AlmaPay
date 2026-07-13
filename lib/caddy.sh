# AlmaPay Caddy source rendering and install guidance.
# shellcheck shell=bash

almapay_caddy_template() {
  printf '%s\n' "${ALMAPAY_ROOT}/templates/caddy/Caddyfile"
}

almapay_caddy_rendered_path() {
  printf '%s\n' "${ALMAPAY_DATA_ROOT}/caddy/Caddyfile.almapay"
}

almapay_render_caddy() {
  local out domain email mode template
  almapay_require_service_user
  domain="${ALMAPAY_DOMAIN}"
  email="${ALMAPAY_ACME_EMAIL:-}"
  mode="${ALMAPAY_ACME_MODE:-http-01}"
  out="$(almapay_caddy_rendered_path)"
  template="$(almapay_caddy_template)"
  mkdir -p "$(dirname "${out}")"

  [[ "${mode}" == "http-01" ]] ||
    almapay_die "only HTTP-01 is implemented in the initial profile"

  [[ -f "${template}" ]] || almapay_die "Caddy source template missing: ${template}"
  python3 - "${template}" "${out}" "${domain}" "${email}" "${ALMAPAY_LISTEN_FIXED}" <<'PY'
import sys
from pathlib import Path

source, destination, domain, email, upstream = sys.argv[1:]
text = Path(source).read_text(encoding="utf-8")
if not email:
    text = text.replace("\temail @@ACME_EMAIL@@\n", "")
replacements = {
    "@@DOMAIN@@": domain,
    "@@ACME_EMAIL@@": email,
    "@@UPSTREAM@@": upstream,
}
for token, value in replacements.items():
    text = text.replace(token, value)
if "@@" in text:
    raise SystemExit("unresolved Caddy template token")
Path(destination).write_text(
    "# Rendered by AlmaPay; install as root only after review.\n" + text,
    encoding="utf-8",
)
PY

  chmod 0640 "${out}"
  almapay_info "rendered Caddy source: ${out}"

  command -v caddy >/dev/null 2>&1 ||
    almapay_die "locked Caddy executable is required to validate rendered configuration"
  caddy validate --config "${out}" >/dev/null ||
    almapay_die "rendered Caddy configuration failed validation"
  almapay_info "caddy validate: ok"

  cat <<EOF
Next (as root, after review):
  install -m 0644 ${out} /etc/caddy/Caddyfile
  systemctl reload caddy
EOF
}
