# Boghche Appliance Workflow Migration

## Objective

Migrate Boghche from a shell-oriented VPN toolkit into a workflow-oriented gateway appliance.

The focus of V2 is:

- user intent driven UX
- operational workflows
- managed firewall ownership
- DNS service abstraction
- maintenance automation
- telemetry-first monitoring

---

# New Service Modules

The console should be decomposed into:

```text
lib/services/
├── tunnel_service.sh
├── monitor_service.sh
├── firewall_service.sh
├── dns_service.sh
└── maintenance_service.sh
```

Each module owns:

- rendering
- workflows
- validation
- backend actions
- recovery logic

---

# Firewall V2

Firewall becomes:

```text
Access Control Center
```

## Primary workflows

### Allow Access

Examples:

- Allow IP -> subnet
- Allow subnet through tunnel
- Allow TCP/UDP port
- Allow LAN segment

### Block Access

Examples:

- Block host
- Block subnet
- Block service port
- Disable internet access

### NAT Management

- Enable NAT for subnet
- Disable NAT for subnet
- View managed NAT rules
- Repair NAT forwarding

### Tunnel Policies

- Restrict VTI access
- Allow LAN ↔ Tunnel
- Repair forwarding
- Validate routing

### Managed Rules

The user should only see:

- Boghche-owned rules
- named policies
- human-readable actions

Never raw nftables dumps in primary UI.

---

# DNS V2

DNS becomes:

```text
DNS Service Center
```

## Primary workflows

### Secure DNS

- Enable DoT
- Disable DoT
- Enforce tunnel-only DNS

### Providers

- Google
- Cloudflare
- Quad9
- Custom upstream

### DNS Policies

- Restrict client resolvers
- Force DNS through tunnel
- Block public DNS leaks

### DNS Analytics

- Query counters
- Top clients
- Failed lookups
- Latency

### DNS Repair

- Rebuild config
- Restart safely
- Validate configuration

Users should manage DNS behavior, not Unbound internals.

---

# Maintenance V2

Maintenance becomes:

```text
Gateway Maintenance Center
```

## Primary workflows

### Backup

- Backup config
- Backup policies
- Backup telemetry state

### Restore

- Restore appliance state
- Restore DNS settings
- Restore firewall policies

### Recovery

- Repair VTI
- Repair XFRM
- Repair forwarding
- Repair DNS

### Validation

- Health audit
- rp_filter validation
- nft conflict detection
- IPSec policy validation

### Cleanup

- Cleanup telemetry
- Rotate stats
- Rebuild generated files

---

# Monitor V2

Monitor becomes:

```text
Operations Center
```

## Telemetry

- Active SAs
- Replay counters
- Xfrm mismatch alerts
- Interface throughput
- Tunnel throughput
- DNS counters
- Top talkers
- Health alerts
- Resource telemetry

The monitor should become:

```text
SOC/NOC style telemetry dashboard
```

instead of shell command wrappers.

---

# Dashboard V2

The dashboard becomes:

```text
Operational appliance landing page
```

## Requirements

- compact layout
- high telemetry density
- no scrolling
- stable ANSI rendering
- visual operational hierarchy
- live counters
- alert visibility
- appliance-style navigation

---

# UX Direction

The user should express:

```text
intent
```

Examples:

- allow this IP
- block this subnet
- enable secure DNS
- repair tunnel
- backup gateway

The appliance should translate those workflows into backend mechanics.

The user should not need to understand:

- nftables syntax
- raw iptables chains
- Unbound internals
- XFRM implementation details
- Linux routing internals

---

# Architectural Goal

Boghche evolves toward:

- VPN appliance console
- managed gateway platform
- operational dashboard
- self-healing telemetry system
- workflow-driven network management
