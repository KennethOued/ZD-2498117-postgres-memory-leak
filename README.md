# ZD-2498117 / CONS-8148 — Postgres Check High Memory Usage on CCR Pods

**Ticket**: ZD-2498117  
**Jira**: CONS-8148  
**Related**: SDBM-2278 (similar pattern on another customer)  
**Status**: Under investigation — Reproduction in progress  
**Investigator**: Kenneth Ouedraogo (TSE2)

---

## 1. Issue

After upgrading the Datadog Agent from **7.43.1** to **7.74.1** (Helm chart 3.151.2), Cluster Check Runner (CCR) pods exhibit **extreme memory consumption** — growing from normal operating levels to **15–37 GB per pod** within hours, eventually consuming nearly all available node memory.

The customer disabled custom metrics collection as a temporary workaround, which reduced memory usage, but this is **not acceptable** as those metrics are critical for their monitoring.

### Symptoms
- CCR pods memory usage: **~15 GB → 37 GB** within 3 hours of pod start
- Heap allocation: **~16.9 GB live**, with **~20 TB cumulative allocations** in 24h
- **128 million live heap objects**
- GC running **5,710 cycles** in 24h, consuming ~1.9% CPU
- HeapSys at **45.4 GB** (virtual memory reserved by Go runtime)
- QoS: **BestEffort** (no resource limits) → pods grow until OOMKilled or node starves

### Comparison with old version
| Metric | Agent 7.43.1 (prod-k8s) | Agent 7.74.1 (develop-k8s) |
|--------|------------------------|---------------------------|
| CCR pods | 6 pods | 6 pods |
| Avg memory/pod | ~100–200 MB | **10–37 GB** |
| Memory multiplier | baseline | **~100x increase** |
| Postgres instances | ~52 | ~52 |

---

## 2. Customer Environment Details

### Infrastructure
- **Cloud**: GCP (Google Kubernetes Engine)
- **Cluster**: `tabby-dev-gke` (develop-k8s), region `europe-west3`
- **Node pool**: `monitoring-pool-v1`, machine type `n2d-standard-16` (16 vCPU, 64 GB RAM)
- **Kubernetes**: GKE (containerd runtime)

### Datadog Stack
- **Agent version**: 7.74.1
- **Helm chart**: datadog/datadog 3.151.2
- **Postgres integration**: 23.3.3
- **Cluster Agent**: 7.74.1
- **CCR pods**: 6 replicas, **no resource limits** (BestEffort QoS)

### Postgres Check Configuration

**Critical finding**: The customer has **two configuration sources** providing Postgres check instances:

#### Source A — Helm `clusterAgent.confd` (intended config)
Defined in `values.yaml` under `clusterAgent.confd.postgres.yaml`:
- `dbm: true`
- `database_autodiscovery: true`
- `relation_regex: .` with `schemas: [public]`
- `max_relations: 50`
- `collect_schemas: { enabled: true }`
- `min_collection_interval: 30`
- Global custom queries for replication slots and autovacuum

#### Source B — Kubernetes Service Annotations (actual running config)
Defined via `ad.datadoghq.com` annotations on `pgb-*` PGBouncer services:
- `dbm: false`
- **`relation_regex: .*`** (matches ALL relations, no schema filter)
- **`max_relations: 300`**
- `collect_count_metrics: true`
- Custom queries for blocked queries and corrupted indexes
- **52 instances** loaded from this source

**The flare confirms that ALL 52 running Postgres instances come from Source B (annotations), NOT Source A (Helm confd).** This means the customer's config improvements (lower max_relations, schema filtering, DBM) were never applied to the running checks.

### Key memstats from flare
```
Alloc:        16.9 GB    (live heap)
HeapInuse:    21.0 GB    (in-use heap spans)
HeapSys:      45.4 GB    (heap virtual memory)
Sys:          46.2 GB    (total virtual memory)
HeapObjects:  128M       (live objects)
TotalAlloc:   20 TB      (cumulative allocations in ~24h)
NumGC:        5,710      (GC cycles)
GCCPUFraction: 1.9%
```

---

## 3. Hypothesis

The extreme memory consumption is caused by a **combination of factors**:

1. **Agent version regression (7.73.x / 7.74.x)**: A memory leak or inefficient allocation pattern was introduced in the Postgres check between Agent 7.43.1 and 7.74.1. The ~100x increase per pod strongly suggests a code-level regression, not just a config issue.

2. **Aggressive relation scanning config**: `relation_regex: .*` with `max_relations: 300` and **no schema filter** causes the check to scan and cache metadata for every table, index, toast table, and sequence across all schemas in each database. With 300 relations × 52 instances, this produces massive in-memory relation caches.

3. **High instance count on single pod**: 52 Postgres check instances running on a single CCR pod multiplies the memory impact of any per-instance leak or cache bloat.

4. **BestEffort QoS**: No memory limits allow pods to grow unbounded instead of being OOMKilled early, masking the issue until node-level pressure occurs.

5. **Config source mismatch**: The customer's improvements (Source A: `max_relations: 50`, `schemas: [public]`) are not being applied because Source B (annotations) is what the agent actually loads. The outdated annotation config with `max_relations: 300` and `relation_regex: .*` amplifies the regression.

### Supporting evidence from SDBM-2278
A separate customer reported a nearly identical pattern:
- Agent upgrade to 7.73.3
- Postgres check with `relation_regex: .` 
- Memory leak on CCR pods
- Same regression window

---

## 4. Reproduction Steps

### Prerequisites
- Docker & Docker Compose
- A Datadog API key (set as `DD_API_KEY` env var)

### Setup

```bash
cd reproduction/

# 1. Start the environment (Postgres 16 + Agent 7.74.1)
export DD_API_KEY="your_api_key_here"
docker compose up -d

# 2. Wait for Postgres init (~2-3 minutes for 10 DBs × 300 tables)
docker compose logs -f postgres

# 3. Verify checks are running
docker exec repro-zd-2498117-datadog-agent-1 agent status | grep -A5 "postgres"

# 4. Monitor memory over time
chmod +x monitor-memory.sh
./monitor-memory.sh
```

### What the reproduction deploys
| Component | Details |
|-----------|---------|
| Postgres | v16 with 10 databases, 300 tables each (3,000 relations total) |
| Agent | `gcr.io/datadoghq/agent:7.74.1` (exact customer version) |
| Config | Source B config: `relation_regex: .*`, `max_relations: 300`, `dbm: false` |
| Instances | 10 (scaled down from 52, but enough to reproduce the pattern) |
| Memory limits | None (BestEffort, same as customer) |
| Custom queries | Same blocked_query and corrupted_index queries |

### Expected behavior (if regression confirmed)
- Memory should grow continuously over time without stabilizing
- HeapAlloc and TotalAlloc should show aggressive growth
- Compare with Agent 7.43.1 by changing the image tag to observe the difference

### Comparison test
```bash
# Re-run with old agent version to compare
# In docker-compose.yaml, change:
#   image: gcr.io/datadoghq/agent:7.43.1
docker compose down -v && docker compose up -d
./monitor-memory.sh
```

---

## 5. Findings

### Finding 1: Dual Configuration Source Conflict
The customer has Postgres checks configured from **two independent sources**:
- **Source A** (Helm `clusterAgent.confd`): Contains the updated, optimized config
- **Source B** (Kubernetes service annotations on `pgb-*` services): Contains the old, aggressive config

The agent flare proves that **only Source B is active**. All 52 instances show:
```
Configuration Source: kube_services:kube_service://stage/pgb-tabby-dev-pg-*[0]
```

The customer's Helm YAML improvements (Source A) are **never loaded** because the annotation-based instances take precedence / are separate checks.

### Finding 2: Memory Regression Between Agent Versions
Comparing the same workload (52 Postgres instances) between clusters:
- **prod-k8s** (Agent 7.43.1): CCR pods use ~100-200 MB each
- **develop-k8s** (Agent 7.74.1): CCR pods use ~10-37 GB each

This is a **~100x increase** that cannot be explained by config differences alone. The prod cluster actually has a larger infrastructure but uses orders of magnitude less memory.

### Finding 3: Extreme Allocation Churn
The `TotalAlloc` of **~20 TB in 24 hours** indicates the agent is allocating and discarding enormous amounts of memory on each check run. With 52 instances running every 15s (default interval), each check cycle is generating massive temporary allocations that stress the GC.

### Finding 4: Pattern Match with SDBM-2278
Another customer (SDBM-2278) reported the same regression on Agent 7.73.3 with `relation_regex: .` — confirming this is not isolated to this customer.

---

## 6. Results

### Current Status: Reproduction In Progress

### Confirmed Issues
| # | Issue | Severity | Status |
|---|-------|----------|--------|
| 1 | Config source mismatch (Source B active, Source A ignored) | High | Confirmed |
| 2 | Memory regression in Agent 7.73.x/7.74.x Postgres check | Critical | Suspected, pending repro |
| 3 | BestEffort QoS allowing unbounded growth | Medium | Confirmed |
| 4 | Aggressive relation scanning (300 relations × 52 instances × no schema filter) | High | Confirmed |

### Recommended Actions for Customer
1. **Immediate**: Update the Kubernetes service annotations on `pgb-*` services to match Source A config:
   - Set `max_relations: 50`
   - Add `schemas: ["public"]` to `relation_regex`
   - Set `dbm: true` if DBM is desired
2. **Immediate**: Set resource limits on CCR pods to prevent node starvation
3. **Short-term**: Remove duplicate config (either annotations OR Helm confd, not both)
4. **Pending**: Agent version fix (tracked via CONS-8148 / SDBM-2278)

### Next Steps
- [ ] Complete local reproduction with Agent 7.74.1
- [ ] Run comparison test with Agent 7.43.1
- [ ] If regression confirmed, escalate with reproduction data to engineering
- [ ] Share findings with TEE (Akira) on CONS-8148

---

## Repository Structure

```
.
├── README.md                          # This file
└── reproduction/
    ├── docker-compose.yaml            # Agent 7.74.1 + Postgres 16
    ├── init-postgres.sh               # Creates 10 DBs × 300 tables
    ├── conf.d/
    │   └── postgres.yaml              # Source B config (exact customer match)
    └── monitor-memory.sh              # Memory monitoring script
```
