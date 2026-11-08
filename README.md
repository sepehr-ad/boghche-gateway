# 🪴 Boghche Gateway

Boghche is a production-oriented IPsec gateway for Ubuntu/Debian with route-based VTI support, policy-based IPsec, NAT, policy routing, secure DNS and an interactive operations console.

## Key VTI defaults

- VTI MTU: `1400`
- TCP MSS: derived automatically as `MTU - 40` (default `1360`)
- VTI/XFRM mark: configurable, default `42`
- StrongSwan route installation: disabled in VTI mode
- StrongSwan `forecast`: disabled in VTI mode
- StrongSwan `connmark`: disabled in VTI mode
- Boghche-managed firewall chains only; no global mangle-table flushes

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

It does not intentionally flush unrelated firewall tables or user-created chains.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/sepehr-ad/boghche-gateway/main/uninstall.sh | sudo bash
```

The uninstaller removes Boghche-managed runtime objects and restores backed-up StrongSwan plugin configuration when available. Boghche backup/telemetry directories are preserved.

## Author

Developed and maintained by **Sepehr Ad**

GitHub: https://github.com/sepehr-ad
