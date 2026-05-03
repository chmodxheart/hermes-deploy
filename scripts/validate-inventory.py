#!/usr/bin/env python3
"""Validate the homelab service inventory JSON file.

Usage example: python3 scripts/validate-inventory.py inventory/services.json
"""

import json
import sys
from pathlib import Path

ALLOWED_TRIAGE = set("candidate maybe stay blocked unknown".split())
TOP_LEVEL_KEYS = set("schema_version generated_from hosts services".split())
HOST_KEYS = set("id platform source_path owner".split())
SERVICE_KEYS = set(
    "id name platform owner source_path namespace ingress_dns storage secrets backups "
    "monitoring dependencies ports criticality resource_context migration notes".split()
)

def fail(message):
    print(f"error: {message}")
    return 1

def require_keys(value, required, path, exact=False):
    missing = sorted(required - set(value))
    if missing:
        return f"{path} missing required keys: {', '.join(missing)}"
    extra = sorted(set(value) - required)
    if exact and extra:
        return f"{path} has unknown keys: {', '.join(extra)}"
    return None

def validate_object(value, path, required=None, exact=False):
    if not isinstance(value, dict):
        return f"{path} must be an object"
    if required is None:
        return None
    return require_keys(value, required, path, exact)

def validate_resource_context(service, path):
    return validate_object(
        service["resource_context"], f"{path}.resource_context", {"requested", "observed", "notes"}
    )

def validate_migration(service, path):
    migration = service["migration"]
    error = validate_object(migration, f"{path}.migration")
    if error:
        return error
    if migration.get("triage") not in ALLOWED_TRIAGE:
        return f"{path}.migration.triage must be one of {sorted(ALLOWED_TRIAGE)}"
    rationale = migration.get("rationale")
    if not isinstance(rationale, str) or not rationale.strip():
        return f"{path}.migration.rationale must be a non-empty string"
    return None

def validate_service(service, index):
    path = f"services[{index}]"
    error = validate_object(service, path, SERVICE_KEYS, exact=True)
    if error:
        return error
    for error in (validate_resource_context(service, path), validate_migration(service, path)):
        if error:
            return error
    return None

def validate(inventory):
    error = validate_object(inventory, "inventory", TOP_LEVEL_KEYS)
    if error:
        return error
    if not isinstance(inventory["hosts"], list):
        return "hosts must be a list"
    if not isinstance(inventory["services"], list):
        return "services must be a list"
    for index, host in enumerate(inventory["hosts"]):
        error = validate_object(host, f"hosts[{index}]", HOST_KEYS)
        if error:
            return error
    for index, service in enumerate(inventory["services"]):
        error = validate_service(service, index)
        if error:
            return error
    return None

def main(argv):
    if len(argv) != 2:
        return fail("usage: validate-inventory.py inventory/services.json")
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
