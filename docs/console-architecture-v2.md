# Boghche Console Architecture V2

## Goal

Transform Boghche from a shell utility into a task-oriented VPN gateway console.

The new architecture separates:

- Dashboard rendering
- Monitoring telemetry
- Firewall management
- DNS management
- Tunnel operations
- Maintenance operations

---

# Main Console Layout

```text
[1] Tunnel
[2] Monitor
[3] Firewall
[4] DNS
[5] Logs
[6] Maintenance
[Q] Quit
```

The landing page becomes monitoring-first.

No configuration actions appear on the dashboard.

---

# Dashboard Responsibilities

The dashboard should ONLY display:

- Tunnel state
- XFRM state
- Replay/mismatch counters
- SA counters
- Interface RX/TX
- Top talkers
- System health
- DNS health
- Active alerts

No shell command dumps.

No giant menus.

No scrolling.

---

# Tunnel Service

Responsible for:

- Configure tunnel
- Start tunnel
- Stop tunnel
- Restart tunnel
- Generate IPSec config
- Add routed subnet
- Repair VTI routing
- Tunnel diagnostics

---

# Monitor Service

Responsible for telemetry only.

## Required telemetry

- Active SAs
- Replay counters
- XfrmInTmplMismatch
- Interface traffic
- Tunnel bytes
- Packet counters
- Top talkers
- System load
- RAM/CPU
- DNS query counters
- Health alerts

No raw linux dumps.

---

# Firewall Service

Firewall becomes task-oriented.

## Tunnel Traffic

- Allow subnet through tunnel
- Block subnet
- Add routed network
- Remove routed network
- View active routed networks

## NAT Management

- Add NAT subnet
- Remove NAT subnet
- Enable masquerade
- Disable masquerade
- View active NAT rules

## IPSec/VTI

- Repair forwarding
- Detect rp_filter issues
- Detect nft/legacy conflicts
- Detect ESP drops

## UFW Integration

- Enable/disable integration
- Add managed allow policy
- Add managed deny policy
- Show Boghche-managed rules only

---

# DNS Service

Replace "Unbound" naming with DNS-oriented UX.

## DNS Service Responsibilities

- Configure DNS-over-TLS
- Generate DNS config
- Restart DNS
- Test DNS resolution
- Select upstream providers
- View DNS query counters
- Validate DNS configuration

The user should not need to know Unbound internals.

---

# Maintenance Service

Replace generic "Tools" naming.

## Responsibilities

- Validate install
- Sync installed files
- Backup config
- Restore config
- Reset generated files
- View versions
- Repair services
- Cleanup telemetry retention

---

# Telemetry Engine

The metrics engine must become self-healing.

## Requirements

- Auto-create directories
- Daily file rotation
- 2GB capped retention
- No stderr warnings
- Safe awk parsing
- Graceful empty-state handling
- Rolling top talkers database

---

# Renderer Goals

- Single-screen fit
- Stable ANSI rendering
- Compact NOC layout
- No scroll overflow
- Fixed-width cards
- Engineering-grade telemetry density
- Operational hierarchy

---

# Architectural Direction

Boghche should evolve toward:

- VPN appliance console
- NOC/SOC dashboard
- Stateful service management
- Managed firewall ownership
- Self-healing telemetry
- Production-grade UX
