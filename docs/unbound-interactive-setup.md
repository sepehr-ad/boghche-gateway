# Boghche Interactive Unbound Setup

## Goal

During the interactive Boghche setup flow, ask the user:

```text
Configure Unbound DNS? [y/N]
```

If enabled:
- install unbound + ca-certificates
- generate `/etc/unbound/unbound.conf.d/boghche.conf`
- bind DNS to localhost and VTI IP
- support DNS-over-TLS upstreams on port 853
- restart unbound only AFTER VTI is ready

---

## Suggested Wizard Flow

```text
Public IP:
Fortigate IP:
PSK:
VTI IP:
...

Configure Unbound DNS? [y/N]
```

If YES:

```text
Enable DNS-over-TLS upstreams? [Y/n]

DNS Listen IP:
[10.12.12.2]

Primary upstream:
[8.8.8.8@853#dns.google]

Secondary upstream:
[8.8.4.4@853#dns.google]
```

---

## Recommended Generated File

Create ONLY:

```text
/etc/unbound/unbound.conf.d/boghche.conf
```

Never overwrite:

```text
/etc/unbound/unbound.conf
```

---

## Suggested Generated Config

```conf
server:
    verbosity: 1

    interface: 127.0.0.1
    interface: 10.12.12.2
    port: 53

    do-ip4: yes
    do-ip6: no

    access-control: 127.0.0.0/8 allow
    access-control: 10.12.12.0/30 allow
    access-control: 192.168.0.0/16 allow
    access-control: 10.20.30.0/30 allow
    access-control: 172.18.0.0/16 allow

    access-control: 0.0.0.0/0 refuse

    hide-identity: yes
    hide-version: yes
    qname-minimisation: yes

    tls-cert-bundle: /etc/ssl/certs/ca-certificates.crt

    cache-min-ttl: 60
    cache-max-ttl: 86400

include: "/etc/unbound/political.conf"

forward-zone:
    name: "."
    forward-tls-upstream: yes

    forward-addr: 8.8.8.8@853#dns.google
    forward-addr: 8.8.4.4@853#dns.google
```

---

## Important Notes

### Install Dependencies

```bash
apt install -y unbound ca-certificates
```

---

### Restart Order

Unbound MUST restart after:
- VTI creation
- VTI IP assignment

Otherwise:

```conf
interface: 10.12.12.2
```

fails to bind.

---

### Validation

```bash
unbound-checkconf
systemctl restart unbound
```

---

## Suggested Config.json Fields

```json
{
  "unbound": true,
  "dns_upstreams": [
    "8.8.8.8@853#dns.google",
    "8.8.4.4@853#dns.google"
  ]
}
```
