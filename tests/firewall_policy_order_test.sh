#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${ROOT_DIR}/lib/firewall_policy.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
CONFIG="${TEST_DIR}/config.json"

printf '%s\n' '{
  "vti_remote": "10.13.13.1",
  "nat_sources": [
    "192.168.0.0/16",
    "172.16.0.0/16",
    "172.18.0.0/16",
    "10.20.30.2/32"
  ],
  "firewall_policies": [
    {
      "source": "10.13.13.1/32",
      "destination": "8.8.8.8/32",
      "protocol": "any",
      "port": "any",
      "action": "allow",
      "comment": "peer DNS only"
    },
    {
      "source": "10.13.13.1/32",
      "destination": "any",
      "protocol": "any",
      "port": "any",
      "action": "block",
      "comment": "block other peer traffic"
    }
  ]
}' > "$CONFIG"

boghche_firewall_validate_config "$CONFIG"

mapfile -t PLAN < <(boghche_firewall_plan "$CONFIG")
[ "${#PLAN[@]}" -eq 4 ]
[[ "${PLAN[0]}" == $'policy\t1\t10.13.13.1/32\t8.8.8.8/32\tany\tany\tallow\tpeer DNS only' ]]
[[ "${PLAN[1]}" == $'policy\t2\t10.13.13.1/32\tany\tany\tany\tblock\tblock other peer traffic' ]]
[[ "${PLAN[2]}" == $'source-default\t0\t10.13.13.1/32\tany\tany\tany\tblock\timplicit default' ]]
[[ "${PLAN[3]}" == $'unmanaged-default\t0\tany\tany\tany\tany\tallow\tlegacy-compatible default' ]]

mapfile -t NAT_SOURCES < <(boghche_effective_nat_sources "$CONFIG")
[ "${#NAT_SOURCES[@]}" -eq 5 ]
printf '%s\n' "${NAT_SOURCES[@]}" | grep -Fxq '10.13.13.1/32'

printf '%s\n' '{"firewall_policies":[]}' > "$CONFIG"
mapfile -t PLAN < <(boghche_firewall_plan "$CONFIG")
[ "${#PLAN[@]}" -eq 1 ]
[[ "${PLAN[0]}" == unmanaged-default$'\t'* ]]

printf '%s\n' '{
  "firewall_policies": [{
    "source": "10.13.13.1/32",
    "destination": "8.8.8.8/32",
    "protocol": "icmp",
    "port": "53",
    "action": "allow"
  }]
}' > "$CONFIG"
if boghche_firewall_validate_config "$CONFIG" >/dev/null 2>&1; then
  echo "invalid protocol/port pair was accepted" >&2
  exit 1
fi

echo "firewall policy ordering and VTI peer NAT: PASS"
