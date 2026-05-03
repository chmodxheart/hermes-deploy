#!/usr/bin/env python3
"""Validate the homelab service inventory JSON file."""

import json
import sys
from pathlib import Path


ALLOWED_TRIAGE = {"candidate", "maybe", "stay", "blocked", "unknown"}
TOP_LEVEL_KEYS = {"schema_version", "generated_from", "hosts", "services"}
HOST_KEYS = {"id", "platform", "source_path", "owner"}
SERVICE_KEYS = {
    "id",
    "name",
    "platform",
    "owner",
    "source_path",
    "namespace",
    "ingress_dns",
    "storage",
    "secrets",
    "backups",
    "monitoring",
    "dependencies",
    "ports",
    "criticality",
    "resource_context",
    "migration",
    "notes",
}


def fail(message):
    print(f"error: {message}")
    return 1


def require_object(value, path):
    if not isinstance(value, dict):
        return f"{path} must be an object"
    return None


def require_keys(value, required, path, exact=False):
    missing = sorted(required - set(value))
    if missing:
        return f"{path} missing required keys: {', '.join(missing)}"
    extra = sorted(set(value) - required)
    if exact and extra:
        return f"{path} has unknown keys: {', '.join(extra)}"
    return None


def validate_host(host, index):
    path = f"hosts[{index}]"
    error = require_object(host, path)
    if error:
        return error
    return require_keys(host, HOST_KEYS, path)


def validate_resource_context(service, path):
    context = service["resource_context"]
    error = require_object(context, f"{path}.resource_context")
    if error:
        return error
    return require_keys(context, {"requested", "observed", "notes"}, f"{path}.resource_context")


def validate_migration(service, path):
    migration = service["migration"]
    error = require_object(migration, f"{path}.migration")
    if error:
        return error
    triage = migration.get("triage")
    if triage not in ALLOWED_TRIAGE:
        return f"{path}.migration.triage must be one of {sorted(ALLOWED_TRIAGE)}"
    rationale = migration.get("rationale")
    if not isinstance(rationale, str) or not rationale.strip():
        return f"{path}.migration.rationale must be a non-empty string"
    return None


def validate_service(service, index):
    path = f"services[{index}]"
    error = require_object(service, path)
    if error:
        return error
    error = require_keys(service, SERVICE_KEYS, path, exact=True)
    if error:
        return error
    error = validate_resource_context(service, path)
    if error:
        return error
    return validate_migration(service, path)


def validate(inventory):
    error = require_object(inventory, "inventory")
    if error:
        return error
    error = require_keys(inventory, TOP_LEVEL_KEYS, "inventory")
    if error:
        return error
    if not isinstance(inventory["hosts"], list):
        return "hosts must be a list"
    if not isinstance(inventory["services"], list):
        return "services must be a list"
    for index, host in enumerate(inventory["hosts"]):
        error = validate_host(host, index)
        if error:
            return error
    for index, service in enumerate(inventory["services"]):
        error = validate_service(service, index)
        if error:
            return error
    return None


def main(argv):
    if len(argv) != 2:
        return fail("usage: validate-inventory.py <inventory.json>")
    try:
        inventory = json.loads(Path(argv[1]).read_text())
    except OSError as error:
        return fail(str(error))
    except json.JSONDecodeError as error:
        return fail(f"invalid JSON: {error}")
    error = validate(inventory)
    if error:
        return fail(error)
    print("OK: inventory valid")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
