# ZD-2498117 / CONS-8148 — Postgres Check High Memory on CCR Pods

**Ticket**: ZD-2498117 | **Jira**: CONS-8148 | **Related**: SDBM-2278  
**Investigator**: Kenneth Ouedraogo (TSE2)

---

## 1. Issue

After upgrading Agent from **7.43.1 → 7.74.1** (Helm 3.151.2), CCR pods grow to **15–37 GB** within hours, eventually starving the node. Customer disabled custom metrics as workaround, which is not acceptable.

| Metric | Agent 7.43.1 (prod) | Agent 7.74.1 (dev) |
|--------|---------------------|-------------------|
| Avg memory/CCR pod | ~100–200 MB | **10–37 GB** |
| Postgres instances | ~52 | ~52 |

---

## 2. Customer Environment

- **Infra**: GKE, `n2d-standard-16` (64 GB), `europe-west3`
- **Agent**: 7.74.1, Helm chart 3.151.2, Postgres check 23.3.3
- **CCR**: 6 replicas, **no resource limits** (BestEffort QoS)
- **Config source actually in use**: Kubernetes service annotations (`kube_services`) — NOT Helm `confd`

### Confirmed active config (from flare)

All 52 instances loaded from annotations on `pgb-*` services:

```yaml
relation_regex: ".*"     # matches ALL relations (tables, indexes, toast, sequences)
max_relations: 300        # per database
dbm: false
collect_count_metrics: true
custom_queries: [blocked_query, corrupted_index]
# NO schema filter
```

### Customer memstats (from flare, ~22.5h uptime)

```
HeapAlloc:     16.9 GB
HeapSys:       45.4 GB
Sys:           46.2 GB
HeapObjects:   128M
TotalAlloc:    20 TB
NumGC:         5,710
GCCPUFraction: 1.9%
```

---

## 3. Confirmed Findings

### Finding 1: Config source mismatch

Customer updated Helm `confd` (Source A: `max_relations: 50`, `schemas: [public]`, `dbm: true`), but the actual running checks come from **Kubernetes service annotations** (Source B). The Helm changes were **never applied**.

### Finding 2: Aggressive relation scanning

`relation_regex: .*` with `max_relations: 300` and no schema filter scans every table, index, toast table, and sequence across all schemas. With 52 instances, this is 52 × 300 = 15,600 relations being cached and processed every check cycle.

### Finding 3: BestEffort QoS

No resource limits on CCR pods allow unbounded memory growth.

---

## 4. Reproduction

### Setup

Deployed on **minikube** (4 CPU, 12 GB RAM) using Helm with:
- Agent **7.74.1** (exact customer version)
- **52 Postgres instances** with exact Source B config
- Postgres 16 with **52 databases × 300 tables** each
- CCR with **no resource limits** (BestEffort, like customer)
- 1 CCR replica (to concentrate all 52 checks on one pod)

### Result: Memory did NOT explode

| Metric | Reproduction (52 inst, ~20 min) | Customer (52 inst, ~22.5h) |
|--------|---------------------------------|---------------------------|
| Container RSS | **~650 MiB – 1.1 GiB (stable)** | **15–37 GB (growing)** |
| HeapAlloc | ~600–930 MB (oscillating) | 16.9 GB |
| HeapObjects | ~9M | 128M |
| TotalAlloc | ~28 GB | 20 TB |
| GCCPUFrac | ~1% | 1.9% |

The CCR pod stabilized around **~1 GB** and did not exhibit the unbounded growth seen on the customer's side.

### What this tells us

- **The config alone does not cause the leak.** Same Agent version + same config + same instance count = stable ~1 GB.
- **The leak is triggered by something we are NOT replicating.** Possible factors:
  - Real production database scale/complexity (larger schemas, more data, more active connections)
  - PGBouncer as intermediary (customer connects through `pgb-*` services, not directly to Postgres)
  - Long runtime (customer pods run for 22+ hours; our test ran ~20 min)
  - Specific Postgres version or configuration on the customer's servers
  - Network latency / connection pooling behavior with remote Postgres instances

### What we do NOT know

- Whether the leak manifests only after hours of runtime
- Whether PGBouncer intermediary is a factor
- What specific Postgres server versions the customer runs
- Whether the customer's databases have significantly more complex schemas than our 300-table simulation

---

## 5. Next Steps

1. **Ask the customer**:
   - Postgres server versions for the monitored databases
   - Approximate number of tables/indexes per database
   - Whether PGBouncer is configured with transaction or session pooling mode
   - If they can share a pprof heap profile (`/debug/pprof/heap`) from a CCR pod while memory is high

2. **Longer reproduction**: Let the current setup run for 12-24 hours to check if the leak is time-dependent

3. **Test with PGBouncer**: Add PGBouncer between Agent and Postgres in the reproduction to check if the connection proxy pattern triggers the leak

4. **Compare with Agent 7.43.1**: Run the same 52-instance setup with `gcr.io/datadoghq/agent:7.43.1` to establish a baseline and confirm the version regression

5. **Escalate to engineering** with:
   - This reproduction (config + setup)
   - The customer's flare memstats
   - Request for code-level review of Postgres check memory handling changes between 7.43.1 and 7.74.1
   - Reference SDBM-2278 as a similar report

---

## Repository Structure

```
.
├── README.md
└── reproduction/
    ├── docker-compose.yaml              # Docker Compose repro (10 instances)
    ├── init-postgres.sh                 # Creates 10 DBs × 300 tables
    ├── conf.d/
    │   └── postgres.yaml                # Source B config (10 instances)
    ├── monitor-memory.sh                # Memory monitoring → CSV
    └── k8s/
        ├── datadog-values.yaml          # Helm values (52 instances, CCR, BestEffort)
        ├── postgres-deployment.yaml     # Postgres K8s deployment
        └── init-postgres-52.sh          # Creates 52 DBs × 300 tables
```
