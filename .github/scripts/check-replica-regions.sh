#!/usr/bin/env bash
# Fails if a region in regions.json (other than the primary) is missing from
# any secret's ReplicaRegions in bootstrap.yaml. Static: needs no AWS, so it
# runs before anyone is asked to approve. deploy-stackset.sh separately
# checks that the replicas actually exist in AWS before adding a region.
#
# Usage: check-replica-regions.sh <regions.json> <bootstrap.yaml>
# Needs PyYAML on the python3 it finds.
set -euo pipefail

REGIONS_FILE=${1:?regions.json}
BOOTSTRAP=${2:?bootstrap.yaml}
PRIMARY_REGION=${PRIMARY_REGION:-us-east-1}

python3 -I - "$REGIONS_FILE" "$BOOTSTRAP" "$PRIMARY_REGION" <<'PY'
import json
import sys

import yaml

regions_file, bootstrap, primary = sys.argv[1:4]


class Loader(yaml.SafeLoader):
    pass


# CloudFormation short-form tags (!Ref, !Sub, ...) are irrelevant here.
Loader.add_multi_constructor("!", lambda loader, suffix, node: None)

with open(regions_file) as f:
    regions = json.load(f)
with open(bootstrap) as f:
    template = yaml.load(f, Loader=Loader)

errors = []
if not isinstance(regions, list) or not regions or not all(isinstance(r, str) for r in regions):
    errors.append(f"{regions_file} must be a non-empty JSON array of region names")
elif primary not in regions:
    errors.append(f"{regions_file} must include the primary region {primary}")
elif len(set(regions)) != len(regions):
    errors.append(f"{regions_file} lists a region more than once")

secrets = {
    name: res
    for name, res in template["Resources"].items()
    if res["Type"] == "AWS::SecretsManager::Secret"
}
if not secrets:
    errors.append(f"{bootstrap} defines no secrets")

if not errors:
    needed = {r for r in regions if r != primary}
    for name, res in secrets.items():
        replicated = {r["Region"] for r in res["Properties"].get("ReplicaRegions", [])}
        missing = sorted(needed - replicated)
        if missing:
            errors.append(
                f"{bootstrap}: {name} has no replica in {', '.join(missing)} "
                f"(listed in {regions_file}). Add them to ReplicaRegions and deploy "
                f"the bootstrap stack by hand first."
            )

if errors:
    for e in errors:
        print(f"::error::{e}")
    sys.exit(1)
print(f"OK: every region in {regions_file} has its secrets replicated in {bootstrap}")
PY
