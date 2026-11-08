# 🪴 Boghche Gateway

Boghche is a production-oriented IPsec gateway for Ubuntu/Debian with route-based VTI support, policy-based IPsec, NAT, policy routing, secure DNS and an interactive operations console.

## Key VTI defaults

- VTI MTU: `1400`
- TCP MSS: derived automatically as `MTU - 40` (default `1360`)
- Single VTI/XFRM mark: `42`
- StrongSwan route installation: disabled in VTI mode
- StrongSwan `forecast`: disabled in VTI mode
- StrongSwan `connmark`: disabled in VTI mode
- Boghche-managed firewall chains only; no global mangle-table flushes

This release remains intentionally single-tunnel. It does not add multi-tunnel
state or separate `mark_in` / `mark_out` values.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/sepehr-ad/boghche-gateway/main/install.sh | sudo bash
```

Then start the console:

```bash
sudo boghche
```

## Recommended first-time workflow

From the dashboard:

```text
[1] Tunnel
[2] Monitor
[3] Firewall
[4] DNS
[5] Logs
[6] Maintenance
[Q] Quit
```

For a new tunnel:

```text
Tunnel
  → Configure / Apply Tunnel
```

Complete the wizard. When the configuration is saved, Boghche **automatically applies and starts the tunnel**.

You do **not** need to press Start after Configure.

### Tunnel menu behavior

- **Configure / Apply Tunnel** — run the wizard, save config, generate IPsec config, restart/apply services and bring up the tunnel.
- **Start / Apply Current Config** — use an already-saved configuration. Use this after Stop, boot recovery, or when you want to re-apply the existing config.
- **Restart Tunnel** — stop and apply the saved configuration again.
- **Stop Tunnel** — stop IPsec/Boghche and remove the VTI interface.
- **Add Routed Subnet** — append an additional routed/NAT subnet and apply the configuration.
- **Tunnel Status** — show service state, IPsec SAs, VTI interface and routing.

## VTI health expectations

For the default route-based profile:

```text
VTI MTU           1400
TCP MSS           1360
forecast plugin   disabled
connmark plugin   disabled
route table 220   absent/empty
IPsec             1 SA up
```

Useful checks:

```bash
ip link show vti0
iptables -t mangle -vnL BOGHCHE-MSS
ip rule
ip route show table vti
ipsec statusall
```

The Maintenance → Health audit also checks VTI MTU, MSS, stale table-220 state, StrongSwan plugin state and legacy ESP MARK rules.

## Managed NAT sources

When NAT is enabled, new configurations persist this source table in
`/etc/boghche/config.json`:

```text
192.168.0.0/16
172.16.0.0/16
172.18.0.0/16
10.20.30.2/32
```

The configured `vti_remote` address is always added automatically as a `/32`.
For example, `vti_remote: 10.13.13.1` creates NAT for
`10.13.13.1/32`. The Firewall → NAT sources menu can list, add and remove
configured sources and enable or disable NAT. The automatic VTI peer entry is
derived from `vti_remote`, so it follows a tunnel-address change without a
second edit.

Older configs without `nat_sources` are migrated at runtime from the default,
legacy LAN and routed-subnet lists. The next Configure run stores the table in
`config.json`.

## Firewall policy table

Firewall → NAT and Firewall Policies manages an ordered table with these fields:

```text
Source | Destination | Protocol | Port | Action | Comment
```

Supported protocols are `any`, `tcp`, `udp` and `icmp`. A port can be `any`, a
single port such as `443`, or a range such as `8000:8100` for TCP/UDP.

Policy behavior is deliberately small and predictable:

1. Rules are evaluated top to bottom; first match wins.
2. Return traffic in `RELATED,ESTABLISHED` state is accepted.
3. A Source that appears in the policy table becomes source-scoped
   default-deny: unmatched traffic from that Source is blocked.
4. Sources absent from the table retain the previous VTI-to-WAN allow behavior,
   so an upgrade does not unexpectedly cut off every routed LAN.

This means the minimal restriction for the VTI peer is one rule:

```text
Source          Destination    Protocol  Port  Action  Comment
10.13.13.1/32  8.8.8.8/32     any       any   allow   peer DNS only
```

After that rule, any other destination from `10.13.13.1/32` is blocked by the
source default. You may also add an explicit `block` rule for
`10.13.13.1/32 → any` immediately below it when you want the policy table to
show the deny explicitly.

Use **Move policy** to change precedence and **Apply saved tables** to activate
the persisted config. `boghche.service` rebuilds both tables after a restart or
reboot.

Example persisted data:

```json
{
  "nat": true,
  "nat_sources": [
    "192.168.0.0/16",
    "172.16.0.0/16",
    "172.18.0.0/16",
    "10.20.30.2/32"
  ],
  "vti_remote": "10.13.13.1",
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
}
```

The Health audit reports the effective NAT source count, the automatic VTI-peer
NAT rule, chain hooks, policy count and source-default blocks.

## Why forecast/connmark are disabled for VTI

Boghche owns the VTI/XFRM mark and policy-routing lifecycle. StrongSwan plugins that install additional Netfilter MARK handling can conflict with that ownership. In VTI mode Boghche therefore manages the relevant StrongSwan plugin configuration and preserves the original plugin files for restoration during uninstall or when switching away from VTI mode.

## Policy-based mode

Policy-based IPsec remains available from the same wizard. In policy mode, Boghche uses the configured local and remote traffic selectors instead of the VTI `0.0.0.0/0` selectors.

## Managed runtime objects

Boghche owns:

- `vti0` (or the configured VTI interface)
- routing table `vti` / table ID 200
- `BOGHCHE-POSTROUTING`
- `BOGHCHE-MSS`
- `BOGHCHE-FORWARD`
- `/etc/ipsec.conf`
- `/etc/ipsec.secrets`
- Boghche-managed StrongSwan VTI settings

Only these dedicated chains are flushed and rebuilt. Boghche does not change
the global `INPUT`, `OUTPUT` or `FORWARD` policies, and it does not flush
unrelated firewall tables or user-created chains.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/sepehr-ad/boghche-gateway/main/uninstall.sh | sudo bash
```

The uninstaller removes Boghche-managed runtime objects and restores backed-up StrongSwan plugin configuration when available. Boghche backup/telemetry directories are preserved.

## Author

Developed and maintained by **Sepehr Ad**

GitHub: https://github.com/sepehr-ad
