#!/usr/bin/env python3
"""Render and validate AlmaPay's semantic Compose model."""

from __future__ import annotations

import argparse
import copy
import re
import sys
from pathlib import Path
from typing import Any

import yaml


PASSWORD_EXPR = "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
POSTGRES_USER_EXPR = "${POSTGRES_USER:-postgres}"
POSTGRES_DB_EXPR = "${POSTGRES_DB:-postgres}"
EXPECTED_BTCPAY_PORT = "127.0.0.1:8080:49392"
FORBIDDEN_INTERNAL_PORTS = {5432, 32838, 43782, 18081, 18082, 18083}
DEFAULT_DATA_ROOT = "/var/lib/almapay"
DEFAULT_CHAINDATA_ROOT = f"{DEFAULT_DATA_ROOT}/chaindata"

PERSISTENT_VOLUME_MAP = {
    "bitcoin_datadir": ("bitcoin", "/data"),
    "bitcoin_wallet_datadir": ("bitcoin-wallet", "/walletdata"),
    "monero_datadir": ("monero", "/data"),
    "postgres_datadir": ("postgres", "/var/lib/postgresql"),
    "btcpay_datadir": ("btcpay", "/datadir"),
}


class ModelError(ValueError):
    pass


def load_yaml(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        value = yaml.safe_load(handle)
    if not isinstance(value, dict):
        raise ModelError(f"{path}: expected a YAML mapping")
    return value


def locked_images(lock: dict[str, Any]) -> dict[str, str]:
    result: dict[str, str] = {}
    images = lock.get("images")
    if not isinstance(images, dict) or not images:
        raise ModelError("lockfile has no images mapping")
    for key, item in images.items():
        if not isinstance(item, dict):
            raise ModelError(f"images.{key} must be a mapping")
        reference = item.get("reference")
        manifest_digest = item.get("manifest_digest")
        digest = item.get("linux_amd64_digest")
        if not isinstance(reference, str) or ":" not in reference:
            raise ModelError(f"images.{key}.reference is invalid")
        if not isinstance(digest, str) or not re.fullmatch(
            r"sha256:[0-9a-f]{64}", digest
        ):
            raise ModelError(f"images.{key}.linux_amd64_digest is invalid")
        if not isinstance(manifest_digest, str) or not re.fullmatch(
            r"sha256:[0-9a-f]{64}", manifest_digest
        ):
            raise ModelError(f"images.{key}.manifest_digest is invalid")
        repository = reference.rsplit(":", 1)[0]
        if repository in result:
            raise ModelError(f"duplicate locked repository: {repository}")
        result[repository] = f"{repository}@{digest}"
    minimums = lock.get("minimum_versions", {})
    # Validate the readable tags against the declared floors; runtime uses digests.
    for key, minimum_key in (
        ("btcpayserver", "btcpayserver"),
        ("bitcoin_core", "bitcoin_core"),
    ):
        item = images.get(key)
        if not isinstance(item, dict):
            raise ModelError(f"required locked image is missing: {key}")
        tag = item["reference"].rsplit(":", 1)[1]
        minimum = str(minimums.get(minimum_key, ""))
        if version_tuple(tag) < version_tuple(minimum):
            raise ModelError(
                f"images.{key}.reference {tag} is below minimum {minimum}"
            )
    return result


def version_tuple(value: str) -> tuple[int, ...]:
    match = re.match(r"^(\d+)\.(\d+)(?:\.(\d+))?", value)
    if not match:
        raise ModelError(f"invalid semantic version: {value}")
    return tuple(int(part or 0) for part in match.groups())


def allowed_chaindata_root(data_root: str) -> str:
    root = data_root.rstrip("/")
    if root == DEFAULT_DATA_ROOT:
        return DEFAULT_CHAINDATA_ROOT
    return f"{root}/chaindata"


def apply_persistent_data_paths(
    model: dict[str, Any], data_root: str = DEFAULT_DATA_ROOT
) -> dict[str, Any]:
    chaindata_root = allowed_chaindata_root(data_root)
    services = model.get("services")
    if not isinstance(services, dict):
        raise ModelError("Compose model has no services mapping")

    converted_names: set[str] = set()
    for service in services.values():
        if not isinstance(service, dict):
            continue
        volumes = service.get("volumes")
        if not isinstance(volumes, list):
            continue
        rewritten: list[Any] = []
        for volume in volumes:
            if isinstance(volume, str):
                source, sep, target = volume.partition(":")
                if sep and source in PERSISTENT_VOLUME_MAP:
                    subdir, expected_target = PERSISTENT_VOLUME_MAP[source]
                    if target.split(":")[0] != expected_target:
                        raise ModelError(
                            f"unexpected target for {source}: {target}"
                        )
                    host_path = f"{chaindata_root}/{subdir}"
                    option_suffix = ""
                    if ":" in target:
                        option_suffix = target[target.index(":") :]
                    elif expected_target in ("/data", "/walletdata", "/datadir", "/var/lib/postgresql"):
                        option_suffix = ":Z"
                    rewritten.append(f"{host_path}:{expected_target}{option_suffix}")
                    converted_names.add(source)
                    continue
            rewritten.append(volume)
        service["volumes"] = rewritten

    top_level = model.get("volumes")
    if isinstance(top_level, dict):
        for name in converted_names:
            top_level.pop(name, None)
        if not top_level:
            model.pop("volumes", None)
    return model


def environment_dict(service: dict[str, Any], service_name: str) -> dict[str, Any]:
    environment = service.setdefault("environment", {})
    if environment is None:
        environment = {}
        service["environment"] = environment
    if isinstance(environment, list):
        converted: dict[str, Any] = {}
        for entry in environment:
            if not isinstance(entry, str) or "=" not in entry:
                raise ModelError(
                    f"services.{service_name}.environment must use explicit KEY=VALUE entries"
                )
            key, value = entry.split("=", 1)
            converted[key] = value
        service["environment"] = converted
        environment = converted
    if not isinstance(environment, dict):
        raise ModelError(f"services.{service_name}.environment must be a mapping")
    return environment


def render(
    model: dict[str, Any],
    lock: dict[str, Any],
    monero_mode: str | None = None,
    data_root: str = DEFAULT_DATA_ROOT,
) -> dict[str, Any]:
    result = copy.deepcopy(model)
    services = result.get("services")
    if not isinstance(services, dict):
        raise ModelError("Compose model has no services mapping")

    images = locked_images(lock)
    for name, service in services.items():
        if not isinstance(service, dict):
            raise ModelError(f"services.{name} must be a mapping")
        image = service.get("image")
        if not isinstance(image, str):
            raise ModelError(f"services.{name}.image is required")
        if image.startswith("${BTCPAY_IMAGE"):
            repository = "btcpayserver/btcpayserver"
        else:
            repository = image.split("@", 1)[0].rsplit(":", 1)[0]
        if repository not in images:
            raise ModelError(
                f"services.{name}.image repository is not in upstream.lock: {repository}"
            )
        service["image"] = images[repository]
        service.pop("links", None)
        if isinstance(service.get("labels"), dict):
            service["labels"] = {
                key: value
                for key, value in service["labels"].items()
                if not str(key).startswith("traefik.")
            }
            if not service["labels"]:
                service.pop("labels")

    for required in ("postgres", "btcpayserver", "nbxplorer"):
        if required not in services:
            raise ModelError(f"required service missing: {required}")

    postgres = services["postgres"]
    postgres_env = environment_dict(postgres, "postgres")
    postgres_env["POSTGRES_HOST_AUTH_METHOD"] = "scram-sha-256"
    postgres_env["POSTGRES_PASSWORD"] = PASSWORD_EXPR
    postgres_env["POSTGRES_USER"] = POSTGRES_USER_EXPR
    postgres_env["POSTGRES_DB"] = POSTGRES_DB_EXPR
    postgres["command"] = [
        "postgres",
        "-c",
        "password_encryption=scram-sha-256",
        "-c",
        "random_page_cost=1.0",
        "-c",
        "shared_preload_libraries=pg_stat_statements",
    ]

    btcpay_connection = (
        f"User ID={POSTGRES_USER_EXPR};Password={PASSWORD_EXPR};"
        "Host=postgres;Port=5432;Application Name=btcpayserver;"
        "Database=btcpayserver${NBITCOIN_NETWORK:-regtest}"
    )
    nbxplorer_connection = (
        f"User ID={POSTGRES_USER_EXPR};Password={PASSWORD_EXPR};"
        "Host=postgres;Port=5432;Application Name=nbxplorer;MaxPoolSize=20;"
        "Database=nbxplorer${NBITCOIN_NETWORK:-regtest}"
    )
    explorer_connection = (
        f"User ID={POSTGRES_USER_EXPR};Password={PASSWORD_EXPR};"
        "Host=postgres;Port=5432;Application Name=btcpayserver;MaxPoolSize=80;"
        "Database=nbxplorer${NBITCOIN_NETWORK:-regtest}"
    )
    btcpay = services["btcpayserver"]
    btcpay_environment = environment_dict(btcpay, "btcpayserver")
    btcpay_environment["BTCPAY_POSTGRES"] = btcpay_connection
    btcpay_environment["BTCPAY_EXPLORERPOSTGRES"] = explorer_connection
    for key in (
        "BTCPAY_SSHCONNECTION",
        "BTCPAY_SSHTRUSTEDFINGERPRINTS",
        "BTCPAY_SSHKEYFILE",
        "BTCPAY_SSHAUTHORIZEDKEYS",
    ):
        btcpay_environment.pop(key, None)
    btcpay_environment["BTCPAY_DOCKERDEPLOYMENT"] = "false"
    btcpay["volumes"] = [
        volume
        for volume in btcpay.get("volumes", [])
        if "SSH" not in str(volume).upper() and "/.ssh" not in str(volume).lower()
    ]
    environment_dict(services["nbxplorer"], "nbxplorer")[
        "NBXPLORER_POSTGRES"
    ] = nbxplorer_connection
    if monero_mode == "disabled" and (
        "monerod" in services or "monerod_wallet" in services
    ):
        raise ModelError("Monero services are present while ALMAPAY_MONERO_MODE=disabled")
    if monero_mode == "local-pruned" and not {
        "monerod",
        "monerod_wallet",
    }.issubset(services):
        raise ModelError("local-pruned Monero requires monerod and monerod_wallet services")
    apply_persistent_data_paths(result, data_root)
    return result


def short_port(port: Any) -> tuple[str | None, int | None, int | None]:
    if isinstance(port, int):
        return None, port, port
    if isinstance(port, dict):
        host_ip = port.get("host_ip")
        published = port.get("published")
        target = port.get("target")
        return (
            str(host_ip) if host_ip is not None else None,
            int(published) if published is not None else None,
            int(target) if target is not None else None,
        )
    if not isinstance(port, str):
        raise ModelError(f"unsupported port syntax: {port!r}")
    value = port.split("/", 1)[0]
    if value == EXPECTED_BTCPAY_PORT:
        return "127.0.0.1", 8080, 49392
    if value.startswith("["):
        match = re.fullmatch(r"\[([^\]]+)\]:(\d+):(\d+)", value)
        if not match:
            raise ModelError(f"unsupported port syntax: {port}")
        return match.group(1), int(match.group(2)), int(match.group(3))
    pieces = value.rsplit(":", 2)
    if len(pieces) == 3:
        return pieces[0], int(pieces[1]), int(pieces[2])
    if len(pieces) == 2:
        return None, int(pieces[0]), int(pieces[1])
    return None, int(pieces[0]), int(pieces[0])


def volume_source(volume: Any) -> tuple[str | None, str | None]:
    if isinstance(volume, str):
        pieces = volume.split(":")
        if len(pieces) >= 2:
            return pieces[0], pieces[1]
        return None, pieces[0]
    if isinstance(volume, dict):
        return volume.get("source"), volume.get("target")
    raise ModelError(f"unsupported volume syntax: {volume!r}")


def as_text(value: Any) -> str:
    if isinstance(value, list):
        return "\n".join(str(item) for item in value)
    return str(value or "")


def validate(
    model: dict[str, Any],
    lock: dict[str, Any],
    data_root: str = DEFAULT_DATA_ROOT,
) -> list[str]:
    errors: list[str] = []
    chaindata_root = allowed_chaindata_root(data_root)
    services = model.get("services")
    if not isinstance(services, dict):
        return ["Compose model has no services mapping"]
    expected_images = set(locked_images(lock).values())
    btcpay_port_count = 0

    for name, service in services.items():
        if not isinstance(service, dict):
            errors.append(f"services.{name} must be a mapping")
            continue
        image = service.get("image")
        if image not in expected_images:
            errors.append(f"{name}: image is not the exact locked linux/amd64 digest: {image}")
        if service.get("privileged") is True:
            errors.append(f"{name}: privileged containers are prohibited")
        if service.get("build") is not None:
            errors.append(f"{name}: runtime image builds are prohibited")
        if service.get("links"):
            errors.append(f"{name}: legacy Compose links are prohibited")
        if service.get("cap_add"):
            errors.append(f"{name}: added capabilities are not allowed in the initial profile")
        for namespace in ("network_mode", "pid", "ipc"):
            if service.get(namespace) == "host":
                errors.append(f"{name}: host {namespace} is prohibited")

        ports = service.get("ports") or []
        if not isinstance(ports, list):
            errors.append(f"{name}: ports must be a list")
            ports = []
        for port in ports:
            try:
                host_ip, published, target = short_port(port)
            except (ModelError, TypeError, ValueError) as exc:
                errors.append(f"{name}: {exc}")
                continue
            if (
                name == "btcpayserver"
                and host_ip == "127.0.0.1"
                and published == 8080
                and target == 49392
            ):
                btcpay_port_count += 1
                continue
            errors.append(f"{name}: unexpected host-published port: {port}")
            if published in FORBIDDEN_INTERNAL_PORTS or target in FORBIDDEN_INTERNAL_PORTS:
                errors.append(f"{name}: internal service port is host-published: {port}")

        for volume in service.get("volumes") or []:
            try:
                source, _target = volume_source(volume)
            except ModelError as exc:
                errors.append(f"{name}: {exc}")
                continue
            if not source:
                continue
            lowered = str(source).lower()
            if lowered.startswith(f"{chaindata_root}/"):
                continue
            if (
                lowered.startswith("/")
                or "docker.sock" in lowered
                or "podman.sock" in lowered
                or lowered in {"/", "/root"}
                or "/.ssh" in lowered
                or lowered.startswith("/root/")
            ):
                errors.append(f"{name}: dangerous host mount: {source}")

        try:
            environment = environment_dict(service, str(name))
        except ModelError as exc:
            errors.append(str(exc))
            environment = {}
        for key, value in environment.items():
            upper = str(key).upper()
            text = str(value)
            if "SSH" in upper and ("KEY" in upper or "CONNECTION" in upper):
                errors.append(f"{name}: BTCPay host SSH integration is prohibited ({key})")
            if "docker.sock" in text.lower() or "podman.sock" in text.lower():
                errors.append(f"{name}: container-engine socket reference in {key}")

    if btcpay_port_count != 1:
        errors.append(
            f"BTCPay must have exactly one {EXPECTED_BTCPAY_PORT} mapping "
            f"(found {btcpay_port_count})"
        )

    postgres = services.get("postgres", {})
    if isinstance(postgres, dict):
        pg_env = environment_dict(postgres, "postgres")
        if pg_env.get("POSTGRES_HOST_AUTH_METHOD") != "scram-sha-256":
            errors.append("postgres: POSTGRES_HOST_AUTH_METHOD must be scram-sha-256")
        if pg_env.get("POSTGRES_PASSWORD") != PASSWORD_EXPR:
            errors.append("postgres: protected POSTGRES_PASSWORD placeholder missing")

    for name in ("btcpayserver", "nbxplorer"):
        service = services.get(name, {})
        if isinstance(service, dict):
            env = environment_dict(service, name)
            key = "BTCPAY_POSTGRES" if name == "btcpayserver" else "NBXPLORER_POSTGRES"
            if PASSWORD_EXPR not in str(env.get(key, "")):
                errors.append(f"{name}: authenticated PostgreSQL connection string missing")
            if name == "btcpayserver" and PASSWORD_EXPR not in str(
                env.get("BTCPAY_EXPLORERPOSTGRES", "")
            ):
                errors.append(
                    "btcpayserver: authenticated NBXplorer PostgreSQL connection string missing"
                )

    bitcoind = services.get("bitcoind")
    if not isinstance(bitcoind, dict):
        errors.append("required bitcoind service is missing")
    else:
        env = environment_dict(bitcoind, "bitcoind")
        if str(env.get("CREATE_WALLET", "")).lower() != "false":
            errors.append("bitcoind: CREATE_WALLET must be false")
        args = as_text(env.get("BITCOIN_EXTRA_ARGS"))
        for required in (
            "rpcport=43782",
            "rpcbind=0.0.0.0:43782",
            "rpcallowip=0.0.0.0/0",
            "port=39388",
            "whitelist=0.0.0.0/0",
            "maxmempool=500",
            "mempoolfullrbf=1",
            "prune=50000",
        ):
            if required not in args:
                errors.append(f"bitcoind: BITCOIN_EXTRA_ARGS missing {required}")

    for name, service in services.items():
        if not isinstance(service, dict):
            continue
        image = str(service.get("image", ""))
        if image.startswith("btcpayserver/monero@") and str(name).lower() == "monerod":
            command = as_text(service.get("command"))
            if "--prune-blockchain" not in command:
                errors.append(f"{name}: Monero local-pruned profile lacks --prune-blockchain")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("render", "validate"))
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--monero-mode", choices=("disabled", "local-pruned"), default=None
    )
    parser.add_argument("--data-root", default=DEFAULT_DATA_ROOT)
    args = parser.parse_args()

    try:
        model = load_yaml(args.input)
        lock = load_yaml(args.lock)
        if args.action == "render":
            if args.output is None:
                raise ModelError("--output is required for render")
            rendered = render(model, lock, args.monero_mode, args.data_root)
            errors = validate(rendered, lock, args.data_root)
            if errors:
                raise ModelError("\n".join(errors))
            with args.output.open("w", encoding="utf-8") as handle:
                yaml.safe_dump(rendered, handle, sort_keys=False)
        else:
            errors = validate(model, lock, args.data_root)
            if errors:
                raise ModelError("\n".join(errors))
    except (OSError, yaml.YAMLError, ModelError) as exc:
        print(f"compose-model: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
