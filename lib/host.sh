# AlmaPay host inspection (doctor) and privileged bootstrap.
# shellcheck shell=bash

almapay_doctor_report() {
  local status="ok"
  local line

  almapay_info "doctor: beginning host prerequisite inspection (read-only)"

  # OS
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" == "almalinux" ]]; then
      local major="${VERSION_ID%%.*}"
      if [[ "${major}" -ge 10 ]]; then
        almapay_info "os: AlmaLinux ${VERSION_ID} (major>=10)"
      else
        almapay_error "os: AlmaLinux major ${major} below 10"
        status="fail"
      fi
    else
      almapay_error "os: expected AlmaLinux, got ID=${ID:-unknown}"
      status="fail"
    fi
  else
    almapay_error "os: /etc/os-release missing"
    status="fail"
  fi

  # Architecture / CPU level
  local arch
  arch="$(uname -m)"
  if [[ "${arch}" == "x86_64" ]]; then
    almapay_info "arch: x86_64"
  else
    almapay_error "arch: expected x86_64, got ${arch}"
    status="fail"
  fi
  if command -v /lib64/ld-linux-x86-64.so.2 >/dev/null 2>&1; then
    line="$(/lib64/ld-linux-x86-64.so.2 --help 2>&1 | grep -F 'x86-64-v3' || true)"
    if [[ "${line}" == *"supported, searched"* ]]; then
      almapay_info "cpu: x86-64-v3 (supported, searched)"
    else
      almapay_warn "cpu: x86-64-v3 not reported as (supported, searched); production profile requires it"
      status="fail"
    fi
  else
    almapay_warn "cpu: unable to query glibc hardware capabilities"
  fi

  # cgroup v2
  if [[ -f /sys/fs/cgroup/cgroup.controllers ]] || mount | grep -q 'cgroup2'; then
    almapay_info "cgroup: v2 present"
  else
    almapay_error "cgroup: v2 required"
    status="fail"
  fi

  # SELinux
  if command -v getenforce >/dev/null 2>&1; then
    local selinux
    selinux="$(getenforce 2>/dev/null || echo unknown)"
    if [[ "${selinux}" == "Enforcing" ]]; then
      almapay_info "selinux: Enforcing"
    else
      almapay_error "selinux: production requires Enforcing (got ${selinux})"
      status="fail"
    fi
  else
    almapay_warn "selinux: getenforce not found"
    status="fail"
  fi

  # User namespaces / newuidmap
  if [[ -x /usr/bin/newuidmap ]] && [[ -x /usr/bin/newgidmap ]]; then
    almapay_info "userns: newuidmap/newgidmap present"
  else
    almapay_error "userns: newuidmap/newgidmap missing"
    status="fail"
  fi

  if id "${ALMAPAY_USER}" >/dev/null 2>&1; then
    almapay_info "user: ${ALMAPAY_USER} exists"
    if grep -Eq "^${ALMAPAY_USER}:" /etc/subuid 2>/dev/null && grep -Eq "^${ALMAPAY_USER}:" /etc/subgid 2>/dev/null; then
      if almapay_validate_subid_file /etc/subuid &&
         almapay_validate_subid_file /etc/subgid; then
        almapay_info "subids: non-overlapping ranges present for ${ALMAPAY_USER}"
      else
        almapay_error "subids: overlapping or invalid subordinate ID ranges"
        status="fail"
      fi
    else
      almapay_error "subids: /etc/subuid or /etc/subgid missing ${ALMAPAY_USER}"
      status="fail"
    fi
  else
    almapay_warn "user: ${ALMAPAY_USER} not created yet (run bootstrap-host)"
  fi

  # Podman / compose
  if command -v podman >/dev/null 2>&1; then
    if id "${ALMAPAY_USER}" >/dev/null 2>&1; then
      almapay_info "podman: $(almapay_as_service podman --version 2>/dev/null | head -n1)"
      if almapay_as_service podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null |
        grep -qx true; then
        almapay_info "podman: rootless operation works as ${ALMAPAY_USER}"
      else
        almapay_error "podman: rootless operation failed as ${ALMAPAY_USER}"
        status="fail"
      fi
    else
      almapay_info "podman executable is installed; runtime version deferred until ${ALMAPAY_USER} exists"
    fi
  else
    almapay_error "podman: not installed"
    status="fail"
  fi
  if [[ -x "${ALMAPAY_COMPOSE_PROVIDER_PATH}" ]]; then
    almapay_info "compose-provider: ${ALMAPAY_COMPOSE_PROVIDER_PATH}"
    local provider_output expected_provider_version
    provider_output="$("${ALMAPAY_COMPOSE_PROVIDER_PATH}" --version 2>/dev/null || true)"
    expected_provider_version="$(awk '/^  compose_provider_version:/{gsub(/"/,"",$2); print $2; exit}' "$(almapay_lockfile_path)")"
    if [[ "${provider_output}" == *podman* &&
          -n "${expected_provider_version}" &&
          "${provider_output}" == *"${expected_provider_version}"* ]]; then
      almapay_info "compose-provider: identity/version matches ${expected_provider_version}"
    else
      almapay_error "compose-provider: identity/version does not match lock"
      status="fail"
    fi
  else
    almapay_error "compose-provider: ${ALMAPAY_COMPOSE_PROVIDER_PATH} missing"
    status="fail"
  fi

  if python3 -c 'import yaml' >/dev/null 2>&1; then
    almapay_info "PyYAML: available"
  else
    almapay_error "PyYAML: unavailable"
    status="fail"
  fi
  if command -v caddy >/dev/null 2>&1; then
    almapay_info "Caddy: installed"
  else
    almapay_error "Caddy: not installed"
    status="fail"
  fi
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    almapay_info "firewalld: active"
  else
    almapay_error "firewalld: not active"
    status="fail"
  fi

  local occupied_port
  if command -v ss >/dev/null 2>&1; then
    for occupied_port in 80 443; do
      if ss -H -lnt 2>/dev/null |
        awk -v port="${occupied_port}" '$4 ~ ":" port "$" {found=1} END {exit !found}'; then
        almapay_warn "host port ${occupied_port} is in use; confirm it belongs to host Caddy"
      else
        almapay_info "host port ${occupied_port}: available"
      fi
    done
  else
    almapay_error "ss: unavailable for listener checks"
    status="fail"
  fi

  local memory_kib swap_kib
  memory_kib="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
  swap_kib="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)"
  almapay_info "memory: ${memory_kib:-unknown} KiB; swap: ${swap_kib:-unknown} KiB"
  if [[ "${memory_kib:-0}" -lt 4194304 ]]; then
    almapay_warn "memory is below the 4 GiB minimum planning floor"
    status="fail"
  fi

  if getent ahosts github.com >/dev/null 2>&1; then
    almapay_info "outbound DNS: works"
  else
    almapay_error "outbound DNS lookup failed"
    status="fail"
  fi
  if command -v curl >/dev/null 2>&1 &&
     curl --fail --silent --show-error --head --max-time 15 \
       https://github.com/ >/dev/null 2>&1; then
    almapay_info "outbound HTTPS: works"
  else
    almapay_error "outbound HTTPS check failed"
    status="fail"
  fi

  # Data root filesystem hints
  if [[ -d "${ALMAPAY_DATA_ROOT}" ]]; then
    almapay_info "data-root: ${ALMAPAY_DATA_ROOT} exists"
    local filesystem
    filesystem="$(findmnt -n -o FSTYPE --target "${ALMAPAY_DATA_ROOT}" 2>/dev/null || true)"
    almapay_info "data-root filesystem: ${filesystem:-unknown}"
    if [[ "${filesystem}" == "xfs" ]] && command -v xfs_info >/dev/null 2>&1; then
      if ! xfs_info "${ALMAPAY_DATA_ROOT}" 2>/dev/null | grep -Eq 'ftype=1'; then
        almapay_error "data-root: XFS requires ftype=1"
        status="fail"
      fi
    fi
    local available_kib available_inodes
    available_kib="$(df -Pk "${ALMAPAY_DATA_ROOT}" | awk 'NR==2 {print $4}')"
    available_inodes="$(df -Pi "${ALMAPAY_DATA_ROOT}" | awk 'NR==2 {print $4}')"
    almapay_info "data-root capacity: ${available_kib:-unknown} KiB and ${available_inodes:-unknown} inodes available"
  else
    almapay_warn "data-root: ${ALMAPAY_DATA_ROOT} missing (bootstrap-host creates it)"
  fi

  if id "${ALMAPAY_USER}" >/dev/null 2>&1; then
    local uid
    uid="$(id -u "${ALMAPAY_USER}")"
    if [[ -d "/run/user/${uid}" ]]; then
      almapay_info "user runtime directory: /run/user/${uid}"
    else
      almapay_error "user runtime directory missing: /run/user/${uid}"
      status="fail"
    fi
    if loginctl show-user "${ALMAPAY_USER}" -p Linger --value 2>/dev/null |
      grep -qx yes; then
      almapay_info "linger: enabled for ${ALMAPAY_USER}"
    else
      almapay_error "linger: not enabled for ${ALMAPAY_USER}"
      status="fail"
    fi
  fi

  if command -v timedatectl >/dev/null 2>&1; then
    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes; then
      almapay_info "time synchronization: active"
    else
      almapay_warn "time synchronization is not confirmed"
      status="fail"
    fi
  fi

  # Ports
  if command -v ss >/dev/null 2>&1; then
    if ss -lnt | grep -Eq ':8080\b' && ! ss -lnt | grep -Eq '127\.0\.0\.1:8080'; then
      almapay_warn "ports: something listening on 8080 outside loopback-only expectation"
    fi
  fi

  if [[ "${status}" == "ok" ]]; then
    almapay_info "doctor: all critical checks passed"
    return 0
  fi
  almapay_error "doctor: one or more prerequisites unmet"
  return 1
}

almapay_validate_subid_file() {
  local file="$1"
  python3 - "${file}" "${ALMAPAY_USER}" <<'PY'
import sys

path, expected_user = sys.argv[1:]
ranges = []
expected = []
with open(path, encoding="utf-8") as handle:
    for line_number, raw in enumerate(handle, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            user, start, count = line.split(":")
            start_i, count_i = int(start), int(count)
        except ValueError:
            raise SystemExit(f"{path}:{line_number}: invalid subordinate-ID entry")
        if count_i <= 0:
            raise SystemExit(f"{path}:{line_number}: count must be positive")
        end_i = start_i + count_i - 1
        for other_user, other_start, other_end in ranges:
            if max(start_i, other_start) <= min(end_i, other_end):
                raise SystemExit(
                    f"{path}:{line_number}: {user} overlaps {other_user}"
                )
        ranges.append((user, start_i, end_i))
        if user == expected_user:
            expected.append((start_i, count_i))
if len(expected) != 1 or expected[0][1] < 65536:
    raise SystemExit(f"{path}: expected one >=65536 range for {expected_user}")
PY
}

almapay_allocate_subid() {
  local file="$1"
  python3 - "${file}" "${ALMAPAY_USER}" <<'PY'
import sys

path, user = sys.argv[1:]
ranges = []
with open(path, encoding="utf-8") as handle:
    for raw in handle:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        owner, start, count = line.split(":")
        if owner == user:
            raise SystemExit(0)
        ranges.append((int(start), int(start) + int(count) - 1))
candidate = 100000
size = 65536
while any(max(candidate, start) <= min(candidate + size - 1, end)
          for start, end in ranges):
    candidate += size
with open(path, "a", encoding="utf-8") as handle:
    handle.write(f"{user}:{candidate}:{size}\n")
PY
}

almapay_download_file() {
  local url="$1"
  local destination="$2"
  if command -v curl >/dev/null 2>&1; then
    curl --fail --silent --show-error --location \
      --proto '=https' --tlsv1.2 \
      --output "${destination}" "${url}"
    return
  fi
  local python=""
  if command -v python3 >/dev/null 2>&1; then
    python="$(command -v python3)"
  elif [[ -x /usr/libexec/platform-python ]]; then
    python=/usr/libexec/platform-python
  else
    almapay_die "curl or platform Python is required to fetch locked package artifacts"
  fi
  "${python}" - "${url}" "${destination}" <<'PY'
import ssl
import sys
import urllib.request

url, destination = sys.argv[1:]
if not url.startswith("https://"):
    raise SystemExit("package artifact URL must use HTTPS")
context = ssl.create_default_context()
with urllib.request.urlopen(url, context=context, timeout=60) as response:
    with open(destination, "wb") as handle:
        while chunk := response.read(1024 * 1024):
            handle.write(chunk)
PY
}

almapay_install_locked_packages() {
  local cache=/var/cache/almapay/packages
  local artifact nevra url sha rpm_path actual_sha actual_nevra signature_result
  local rpm_paths=()
  install -d -o root -g root -m 0700 "${cache}"

  while IFS= read -r artifact; do
    IFS=$'\t' read -r nevra url sha <<<"${artifact}"
    rpm_path="${cache}/${sha}.rpm"
    if [[ ! -f "${rpm_path}" ]]; then
      almapay_info "fetching locked package artifact ${nevra}"
      almapay_download_file "${url}" "${rpm_path}.partial"
      mv "${rpm_path}.partial" "${rpm_path}"
    fi
    actual_sha="$(almapay_sha256_file "${rpm_path}")"
    [[ "${actual_sha}" == "${sha}" ]] ||
      almapay_die "package artifact checksum mismatch for ${nevra}"
    signature_result="$(LC_ALL=C rpmkeys --checksig --verbose "${rpm_path}")" ||
      almapay_die "package artifact signature verification failed for ${nevra}"
    [[ "${signature_result}" == *"signatures OK"* ]] ||
      almapay_die "package artifact is not signed by a trusted RPM key: ${nevra}"
    actual_nevra="$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "${rpm_path}")"
    [[ "${actual_nevra}" == "${nevra}" ]] ||
      almapay_die "package artifact identity ${actual_nevra} differs from lock ${nevra}"
    rpm_paths+=("${rpm_path}")
  done < <(almapay_locked_package_artifacts)

  ((${#rpm_paths[@]} > 0)) || almapay_die "no locked RPM artifacts available"
  # Disable repositories: the lock must include the complete dependency closure.
  dnf -y --disablerepo='*' --setopt=install_weak_deps=False \
    install "${rpm_paths[@]}" ||
    almapay_die "offline installation of the locked package closure failed"
}

almapay_bootstrap_host() {
  if [[ "$(id -u)" -ne 0 ]]; then
    almapay_die "bootstrap-host must run as root"
  fi

  almapay_info "bootstrap-host: installing host prerequisites (idempotent)"
  almapay_require_release_lock

  local packages=()
  mapfile -t packages < <(almapay_locked_host_packages)
  ((${#packages[@]} > 0)) || almapay_die "no locked host packages found"
  almapay_install_locked_packages
  local package installed
  for package in "${packages[@]}"; do
    installed="$(rpm -q --qf '%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' "${package}" 2>/dev/null ||
      rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "${package}" 2>/dev/null ||
      true)"
    [[ -n "${installed}" ]] ||
      almapay_die "locked package did not install: ${package}"
  done

  getent group "${ALMAPAY_USER}" >/dev/null || groupadd -r "${ALMAPAY_USER}"
  if ! id "${ALMAPAY_USER}" >/dev/null 2>&1; then
    useradd -r -g "${ALMAPAY_USER}" -d "${ALMAPAY_DATA_ROOT}" -s /sbin/nologin \
      -c "AlmaPay BTCPay Podman runtime" "${ALMAPAY_USER}"
  fi

  install -d -o "${ALMAPAY_USER}" -g "${ALMAPAY_USER}" -m 0750 "${ALMAPAY_DATA_ROOT}"
  install -d -o "${ALMAPAY_USER}" -g "${ALMAPAY_USER}" -m 0750 "${ALMAPAY_DATA_ROOT}/compose"
  install -d -o "${ALMAPAY_USER}" -g "${ALMAPAY_USER}" -m 0700 "${ALMAPAY_DATA_ROOT}/secrets"
  install -d -o "${ALMAPAY_USER}" -g "${ALMAPAY_USER}" -m 0750 "${ALMAPAY_DATA_ROOT}/backups"

  if { ! grep -Eq "^${ALMAPAY_USER}:" /etc/subuid ||
       ! grep -Eq "^${ALMAPAY_USER}:" /etc/subgid; } &&
     [[ -d "${ALMAPAY_DATA_ROOT}/.local/share/containers/storage" ]]; then
    almapay_die "subordinate IDs are missing but rootless storage already exists; stop all affected containers and perform an operator-reviewed podman system migrate as ${ALMAPAY_USER}"
  fi
  almapay_allocate_subid /etc/subuid
  almapay_allocate_subid /etc/subgid
  almapay_validate_subid_file /etc/subuid ||
    almapay_die "invalid /etc/subuid allocation"
  almapay_validate_subid_file /etc/subgid ||
    almapay_die "invalid /etc/subgid allocation"

  loginctl enable-linger "${ALMAPAY_USER}"

  # firewalld: preserve detected SSH listener, add only required services.
  if ! systemctl is-active --quiet firewalld; then
    systemctl enable --now firewalld ||
      almapay_die "firewalld could not be started safely"
  fi
  if systemctl is-active --quiet firewalld; then
    local ssh_port zone
    local zones=()
    local ssh_ports=()
    mapfile -t zones < <(firewall-cmd --get-active-zones |
      awk '/^[^[:space:]]/ {print $1}')
    ((${#zones[@]} == 1)) ||
      almapay_die "expected exactly one active firewalld zone; review multi-zone policy manually"
    zone="${zones[0]}"
    if command -v sshd >/dev/null 2>&1; then
      mapfile -t ssh_ports < <(sshd -T 2>/dev/null |
        awk '$1 == "port" {print $2}' | sort -nu)
    fi
    if ((${#ssh_ports[@]} == 0)); then
      mapfile -t ssh_ports < <(ss -H -lntp |
        awk '/sshd/ {print $4}' |
        sed -E 's/.*:([0-9]+)$/\1/' | sort -nu)
    fi
    if ((${#ssh_ports[@]} == 0)) &&
       systemctl is-active --quiet sshd.socket 2>/dev/null; then
      mapfile -t ssh_ports < <(systemctl show sshd.socket -p Listen --value |
        grep -Eo ':[0-9]+' | tr -d ':' | sort -nu)
    fi
    ((${#ssh_ports[@]} > 0)) ||
      almapay_die "unable to determine SSH listener ports; refusing firewall changes"
    firewall-cmd --permanent --zone="${zone}" --add-service=http
    firewall-cmd --permanent --zone="${zone}" --add-service=https
    for ssh_port in "${ssh_ports[@]}"; do
      if [[ "${ssh_port}" == "22" ]]; then
        firewall-cmd --permanent --zone="${zone}" --add-service=ssh
      else
        firewall-cmd --permanent --zone="${zone}" --add-port="${ssh_port}/tcp"
      fi
    done
    firewall-cmd --reload
    if firewall-cmd --zone="${zone}" --query-port=8080/tcp >/dev/null 2>&1; then
      almapay_die "firewall exposes prohibited port 8080"
    fi
    almapay_info "firewalld zone ${zone}: http/https allowed; SSH ports ${ssh_ports[*]} preserved; 8080 not opened"
  fi

  almapay_info "bootstrap-host: complete. Next: copy config, create secrets.env, run almapay install as operator."
}
