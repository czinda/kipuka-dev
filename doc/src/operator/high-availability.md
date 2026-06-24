# High Availability

kipuka provides multi-CA high availability at the application layer. When a Certificate Authority backend becomes unavailable—whether due to HSM failure, Dogtag server downtime, or certificate expiration—kipuka can automatically failover to an alternate CA. This ensures continuous certificate enrollment even when individual CA components fail.

High availability is configured through `[ha]` and `[[ha.group]]` sections in the configuration file.

## Overview

Traditional PKI deployments often rely on infrastructure-level HA (load balancers, database replication) for a single CA. kipuka takes a different approach: it treats each CA as an independent backend and implements application-layer failover logic. This allows:

- **Heterogeneous CA backends**: Mix HSM-backed CAs with file-based CAs, or Dogtag with other implementations
- **Gradual migration**: Route a percentage of traffic to a new CA while maintaining the old one
- **Geographic distribution**: Route requests to the nearest or fastest CA
- **Independent failure domains**: HSM failure doesn't take down file-based backup CAs

When a CA fails, kipuka's circuit breaker immediately stops routing requests to it and redistributes traffic to healthy CAs in the same group. When the failed CA recovers, kipuka automatically reintegrates it based on the configured strategy.

## Failover Strategies

kipuka supports four failover strategies, selectable globally via `[ha]` or per-group via `[[ha.group]]`:

### active-passive

The primary CA handles all requests. If it fails, the secondary takes over. When the primary recovers, traffic automatically returns to it.

**Use when:**
- You have a clear primary CA (e.g., HSM-backed) and want a hot standby
- You need predictable CA assignment for audit or compliance
- Your CAs have different trust levels or security characteristics

**Behavior:**
- All requests routed to the first healthy CA in the group
- On failure, immediately switch to the next CA
- On recovery, immediately switch back to the primary

### round-robin

Requests are distributed evenly across all healthy CAs in the group. Any failure removes that CA from rotation until it recovers.

**Use when:**
- All CAs in the group have equivalent capacity and trust
- You want to distribute load across multiple CAs
- You need to maximize utilization of all CA backends

**Behavior:**
- Each request goes to the next CA in a circular list
- Failed CAs are skipped in the rotation
- Load is balanced evenly across all healthy CAs

### weighted

Requests are distributed according to configured weights (e.g., 80% to CA1, 20% to CA2). Allows proportional load distribution.

**Use when:**
- CAs have different capacities (e.g., HSM vs. software)
- You're migrating from one CA to another gradually
- You want to test a new CA with a small percentage of traffic

**Behavior:**
- Each CA receives traffic proportional to its weight
- Weights are specified per-CA in the group configuration
- If a CA fails, its weight is redistributed to remaining CAs

**Configuration:**
```toml
[[ha.group]]
name = "primary"
ca_ids = ["hsm-ca", "file-ca"]
strategy = "weighted"
weights = { "hsm-ca" = 80, "file-ca" = 20 }
```

### latency-based

Requests are routed to the CA with the lowest recent response time. Self-optimizing for geographically distributed CAs.

**Use when:**
- CAs are in different geographic locations
- Network latency varies significantly between CAs
- You want automatic optimization without manual tuning

**Behavior:**
- kipuka tracks rolling average latency for each CA
- Each request goes to the CA with the lowest average latency
- Latency is measured from health checks and actual signing operations
- Failed CAs are assigned infinite latency

## Circuit Breaker Pattern

kipuka implements a circuit breaker to prevent cascading failures and automatically recover from transient issues. The circuit breaker prevents the system from repeatedly attempting to use a failing CA, which could delay client requests or exhaust resources.

### States

The circuit breaker transitions through five states:

**Healthy**: CA is responding normally. All requests are routed to it according to the failover strategy.

**Degraded**: CA has experienced some failures but remains below the failure threshold. Requests continue to be routed, but the CA is monitored more closely. This state provides early warning of potential issues.

**Unhealthy**: Failure count exceeds `failure_threshold` within the check window. The CA is immediately removed from rotation to prevent client impact.

**CircuitOpen**: After transitioning to Unhealthy, the circuit opens. No requests are sent to this CA. A timer starts for `recovery_timeout` seconds to allow the CA time to recover.

**Recovering**: After `recovery_timeout` expires, a single probe request is sent. If it succeeds, the CA transitions back to Healthy and rejoins rotation. If it fails, the circuit returns to CircuitOpen with an extended timeout (exponential backoff).

### State Transitions

```
Healthy --> Degraded --> Unhealthy --> CircuitOpen --> Recovering --> Healthy
   ^                                      |               |
   |                                      +-------<-------+
   +------------------<-------------------+
```

- **Healthy → Degraded**: First failure detected
- **Degraded → Unhealthy**: Failure count exceeds threshold
- **Unhealthy → CircuitOpen**: Immediate transition; timer starts
- **CircuitOpen → Recovering**: After `recovery_timeout` expires
- **Recovering → Healthy**: Probe succeeds; CA rejoins rotation
- **Recovering → CircuitOpen**: Probe fails; extended timeout begins
- **Degraded → Healthy**: CA recovers before hitting threshold
- **CircuitOpen → Healthy**: Manual operator override (health check passes)

### Configuration

Circuit breaker behavior is tuned via `[ha]`:

```toml
[ha]
check_interval = "10s"        # How often to probe each CA
failure_threshold = 3          # Consecutive failures before marking unhealthy
recovery_timeout = "60s"       # Wait time before probing a failed CA
check_timeout = "5s"           # Max time to wait for health check response
```

- `check_interval`: Frequency of active health checks. Shorter intervals detect failures faster but increase CA load.
- `failure_threshold`: Number of consecutive failures before removing a CA from rotation. Lower values improve responsiveness but may cause flapping; higher values increase tolerance for transient failures.
- `recovery_timeout`: How long to wait before attempting recovery. This gives the CA time to fully restart or for transient issues to resolve. kipuka uses exponential backoff: if the first probe fails, the next timeout is doubled.
- `check_timeout`: Maximum time to wait for a health check response. Should be shorter than `check_interval` to avoid overlapping checks.

## HA Groups

HA groups define sets of CAs that provide redundancy for each other. All CAs in a group should issue from the same root (or cross-certified roots) so clients trust all issuers.

### Configuration

```toml
[[ha.group]]
name = "primary"               # Unique group name
ca_ids = ["hsm-ca", "file-ca"] # Array of [[ca]] id values
strategy = "active-passive"    # Optional: override global strategy
```

- `name`: Unique identifier for this group. Used in logs and metrics.
- `ca_ids`: Array of CA identifiers. Must reference valid `[[ca]]` sections. Order matters for `active-passive` strategy.
- `strategy`: Optional override of the global `[ha]` strategy. Allows different strategies for different groups.

### EST Label Integration

EST labels reference individual CAs via their `id`. When the primary CA in a group fails, the HA system automatically routes requests to the next healthy CA in the group. From the client's perspective, the EST label remains the same—failover is transparent.

Example:

```toml
[[ca]]
id = "hsm-ca"
backend = "dogtag"
# ... HSM configuration ...

[[ca]]
id = "file-ca"
backend = "file"
# ... file configuration ...

[[ha.group]]
name = "production"
ca_ids = ["hsm-ca", "file-ca"]
strategy = "active-passive"

[[est.label]]
name = "device-cert"
ca_id = "hsm-ca"  # References the group leader
profile = "deviceCert"
```

If `hsm-ca` fails, requests to the `device-cert` label automatically use `file-ca` until `hsm-ca` recovers.

## Health Check Configuration

kipupa performs active health checks to detect CA failures and recoveries. Health checks are lightweight signing operations that verify the CA is fully functional—not just network-reachable.

### Health Check Behavior

1. Every `check_interval` seconds, kipuka sends a test signing request to each CA
2. If the CA responds successfully within `check_timeout`, the check passes
3. If the CA fails to respond or returns an error, the check fails
4. After `failure_threshold` consecutive failures, the CA is marked Unhealthy
5. After `recovery_timeout` seconds, kipuka sends a single probe to the failed CA
6. If the probe succeeds, the CA returns to Healthy; if it fails, the timeout doubles

### Tuning Recommendations

**Low-latency environment (local CAs):**
```toml
[ha]
check_interval = "5s"
failure_threshold = 2
recovery_timeout = "30s"
check_timeout = "2s"
```

**High-latency environment (geographically distributed CAs):**
```toml
[ha]
check_interval = "30s"
failure_threshold = 5
recovery_timeout = "120s"
check_timeout = "10s"
```

**Production (balanced):**
```toml
[ha]
check_interval = "10s"
failure_threshold = 3
recovery_timeout = "60s"
check_timeout = "5s"
```

## Example Configurations

### Two-CA Active-Passive with HSM Primary

A production deployment with an HSM-backed primary CA and a file-based backup. Normal traffic uses the HSM; if it fails, the file-based CA provides continuity.

```toml
[ha]
strategy = "active-passive"
check_interval = "10s"
failure_threshold = 3
recovery_timeout = "60s"
check_timeout = "5s"

[[ca]]
id = "hsm-ca"
backend = "dogtag"
[ca.dogtag]
url = "https://pki.example.com:8443"
ca_cert = "/etc/kipuka/pki-ca.pem"
auth_cert = "/etc/kipuka/ra-agent.pem"
auth_key = "pkcs11:token=HSM;object=ra-key"

[[ca]]
id = "backup-ca"
backend = "file"
[ca.file]
ca_cert = "/etc/kipuka/backup-ca.pem"
ca_key = "/etc/kipuka/backup-ca-key.pem"

[[ha.group]]
name = "production"
ca_ids = ["hsm-ca", "backup-ca"]

[[est.label]]
name = "device"
ca_id = "hsm-ca"  # HA group leader
profile = "deviceCert"
```

**Expected behavior:**
- All requests use `hsm-ca` under normal conditions
- If the HSM or Dogtag server fails, traffic immediately switches to `backup-ca`
- When `hsm-ca` recovers, traffic returns to it within one `check_interval`
- Clients see no difference—the `device` label works throughout

### Three-CA Round-Robin for Load Distribution

Three identical CAs in different datacenters. Traffic is distributed evenly to maximize utilization and provide geographic redundancy.

```toml
[ha]
strategy = "round-robin"
check_interval = "15s"
failure_threshold = 3
recovery_timeout = "90s"
check_timeout = "7s"

[[ca]]
id = "ca-east"
backend = "dogtag"
[ca.dogtag]
url = "https://pki-east.example.com:8443"
ca_cert = "/etc/kipuka/ca.pem"
auth_cert = "/etc/kipuka/ra-east.pem"
auth_key = "/etc/kipuka/ra-east-key.pem"

[[ca]]
id = "ca-west"
backend = "dogtag"
[ca.dogtag]
url = "https://pki-west.example.com:8443"
ca_cert = "/etc/kipuka/ca.pem"
auth_cert = "/etc/kipuka/ra-west.pem"
auth_key = "/etc/kipuka/ra-west-key.pem"

[[ca]]
id = "ca-central"
backend = "dogtag"
[ca.dogtag]
url = "https://pki-central.example.com:8443"
ca_cert = "/etc/kipuka/ca.pem"
auth_cert = "/etc/kipuka/ra-central.pem"
auth_key = "/etc/kipuka/ra-central-key.pem"

[[ha.group]]
name = "global"
ca_ids = ["ca-east", "ca-west", "ca-central"]

[[est.label]]
name = "iot"
ca_id = "ca-east"  # Any CA in the group; round-robin applies
profile = "iotDevice"
```

**Expected behavior:**
- Requests are distributed 33/33/33 across the three CAs
- If `ca-east` fails, traffic is redistributed 50/50 to `ca-west` and `ca-central`
- When `ca-east` recovers, it rejoins the rotation
- Each CA operates independently; no shared state required

### Geographic HA with Latency-Based Routing

Two CAs in different regions. kipuka automatically routes requests to the CA with the lowest latency, optimizing performance for geographically distributed clients.

```toml
[ha]
strategy = "latency-based"
check_interval = "20s"
failure_threshold = 4
recovery_timeout = "120s"
check_timeout = "10s"

[[ca]]
id = "ca-us"
backend = "dogtag"
[ca.dogtag]
url = "https://pki-us.example.com:8443"
ca_cert = "/etc/kipuka/ca.pem"
auth_cert = "/etc/kipuka/ra-us.pem"
auth_key = "/etc/kipuka/ra-us-key.pem"

[[ca]]
id = "ca-eu"
backend = "dogtag"
[ca.dogtag]
url = "https://pki-eu.example.com:8443"
ca_cert = "/etc/kipuka/ca.pem"
auth_cert = "/etc/kipuka/ra-eu.pem"
auth_key = "/etc/kipuka/ra-eu-key.pem"

[[ha.group]]
name = "global"
ca_ids = ["ca-us", "ca-eu"]

[[est.label]]
name = "vpn"
ca_id = "ca-us"  # HA group leader; latency-based routing applies
profile = "vpnCert"
```

**Expected behavior:**
- kipuka measures latency to both CAs during health checks
- Requests are automatically routed to the faster CA (e.g., `ca-us` for US clients, `ca-eu` for EU clients)
- If latency increases for one CA (network congestion, overload), traffic shifts to the other
- If one CA fails completely, all traffic uses the remaining CA
- No manual configuration required—self-optimizing based on network conditions

### Weighted Migration from Old to New CA

Gradual migration from an existing CA to a new one. Start with 90% traffic on the old CA, gradually shift to 100% on the new CA, then decommission the old CA.

```toml
[ha]
strategy = "weighted"
check_interval = "10s"
failure_threshold = 3
recovery_timeout = "60s"
check_timeout = "5s"

[[ca]]
id = "old-ca"
backend = "dogtag"
[ca.dogtag]
url = "https://pki-old.example.com:8443"
ca_cert = "/etc/kipuka/old-ca.pem"
auth_cert = "/etc/kipuka/ra-old.pem"
auth_key = "/etc/kipuka/ra-old-key.pem"

[[ca]]
id = "new-ca"
backend = "dogtag"
[ca.dogtag]
url = "https://pki-new.example.com:8443"
ca_cert = "/etc/kipuka/new-ca.pem"
auth_cert = "/etc/kipuka/ra-new.pem"
auth_key = "/etc/kipuka/ra-new-key.pem"

[[ha.group]]
name = "migration"
ca_ids = ["old-ca", "new-ca"]
strategy = "weighted"
weights = { "old-ca" = 90, "new-ca" = 10 }

[[est.label]]
name = "server"
ca_id = "old-ca"
profile = "serverCert"
```

**Migration procedure:**
1. Start with `weights = { "old-ca" = 100, "new-ca" = 0 }` (new CA online but unused)
2. Update to `weights = { "old-ca" = 90, "new-ca" = 10 }` (10% canary traffic)
3. Monitor logs and metrics; if no issues, increase to 80/20, 50/50, 20/80
4. Finish with `weights = { "old-ca" = 0, "new-ca" = 100 }` (full cutover)
5. Remove `old-ca` from the configuration once fully decommissioned

No client reconfiguration required—weights can be adjusted without restarting kipuka.
