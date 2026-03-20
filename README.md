# ZD-2498117 / CONS-8148 — Postgres Check High Memory on CCR Pods

**Ticket**: [ZD-2498117](https://datadog.zendesk.com/agent/tickets/2498117)  
**Jira**: [CONS-8148](https://datadoghq.atlassian.net/browse/CONS-8148)  
**Related**: [SDBM-2278](https://datadoghq.atlassian.net/browse/SDBM-2278) (similar pattern, different customer, Agent 7.73.3)  
**Related**: [CONS-8086](https://datadoghq.atlassian.net/browse/CONS-8086)  
**Investigator**: Kenneth Ouedraogo (TSE2)

---

## 1. Issue

After upgrading Agent from **7.43.1 → 7.74.1** (Helm 3.151.2), CCR pods memory grows to **15–40 GB per pod** within hours.

Customer tried:
- **Doubling CCR replicas** (6 → 12): instances/runner dropped to 26, but **total memory jumped to ~190 GB** ([CONS-8148, Mar 13](https://datadoghq.atlassian.net/browse/CONS-8148))
- **Disabling custom metrics**: memory improved, but **customer says not acceptable** — those metrics are critical

| Metric | Agent 7.43.1 (prod, 6 CCR) | Agent 7.74.1 (dev, 6 CCR) | Agent 7.74.1 (dev, 12 CCR) |
|--------|---------------------------|--------------------------|---------------------------|
| Total CCR memory | ~18 GiB | ~100 GiB | **~190 GiB** |
| Per-pod range | ~3 GiB | ~15–40 GiB | 2–29 GiB |

![Customer CCR pods on develop-k8s](screenshots/customer-ccr-memory-develop-k8s.png)
*Customer's Kubernetes Explorer showing CCR pods using 14–30 GiB each on cluster `develop-k8s`*

---

## 2. Environment

- **Cloud**: GKE, `n2d-standard-16` (64 GB), `europe-west3`
- **Agent**: 7.74.1, Helm 3.151.2, Postgres check 23.3.3
- **CCR**: BestEffort QoS (no resource limits)
- **Cluster**: `tabby-dev-gke` (develop-k8s)

### Config actually in use (from flare)

All 52 instances sourced from **Kubernetes service annotations** on `pgb-*` services (NOT from Helm `confd`):

```
Configuration Source: kube_services:kube_service://stage/pgb-tabby-dev-pg-5-dp-ex-feeds-statistics[0]
```
*Source: https://datadog.zendesk.com/attachments/token/gubgvKqRDHs7KeBMBh9Wmp0Cv/?name=postgres_manual_check.log

Resolved config per instance:
```yaml
relation_regex: ".*"        # matches ALL relations — no schema filter
max_relations: 300           # default, not capped
dbm: false
collect_count_metrics: true
collect_database_size_metrics: true
custom_queries:              # 2 custom queries per instance
  - blocked_query (pg_blocking_pids join)
  - corrupted_index (pg_index WHERE NOT indisvalid)
```

### Dual config source (confirmed)

- **Source A** (Helm `clusterAgent.confd`): `max_relations: 50`, `schemas: [public]`, `dbm: true` — **NOT applied**
- **Source B** (K8s annotations on `pgb-*` services): `max_relations: 300`, `relation_regex: .*`, `dbm: false` — **actually running**

### Key memstats from flare (~22.5h uptime)

https://datadog.zendesk.com/attachments/token/oexbPgM9tAywbck3JCP6mCuU1/?name=datadog-agent-2026-03-19T16-37-50Z-info.zip
```
Alloc:         16.9 GB      HeapObjects:  128M
HeapInuse:     21.0 GB      TotalAlloc:   20 TB
HeapSys:       45.4 GB      NumGC:        5,710
Sys:           46.2 GB      GCCPUFraction: 1.9%
```
*Source: `expvar/memstats`*

---

## 4. Reproduction

### Setup

Deployed on **minikube** (4 CPU, 12 GB) via Helm:
- Agent **7.74.1** (exact version)
- **52 Postgres instances** with exact Source B config
- Postgres 16, **52 databases × 300 tables** each
- CCR with **no resource limits** (BestEffort)
- 1 CCR replica (all 52 checks on one pod)

### Test 1: Source A (Helm confd) delivery

Checks loaded from `file:/etc/datadog-agent/conf.d/postgres.yaml[N]`

| Metric | Baseline | T+5min | T+10min |
|--------|----------|--------|---------|
| Container RSS | — | 1,154 Mi | **1,214 Mi** |
| HeapAlloc | 845 MB | 600 MB | 930 MB |
| TotalAlloc | 59.9 GB | 86.6 GB | 130 GB |

**Result: Stable ~1.2 GiB. No explosion.**

### Test 2: Source B (kube_services annotations) delivery — same as customer

52 annotated `pgb-*` services with `ad.datadoghq.com` annotations.
Checks loaded from `kube_services:kube_service://repro/pgb-repro-*[0]` — matching customer's `kube_services:kube_service://stage/pgb-tabby-dev-pg-*[0]`.

| Metric | Baseline | T+5min | T+10min |
|--------|----------|--------|---------|
| Container RSS | 1,218 Mi | 1,191 Mi | **1,163 Mi** |
| HeapAlloc | 527 MB | 560 MB | 849 MB |
| TotalAlloc | 41.6 GB | 68.8 GB | 98.1 GB |
| GCCPUFrac | 0.82% | 0.86% | 0.84% |

**Result: Stable ~1.2 GiB. No explosion. Same as Source A.**

### Comparison: Reproduction vs Customer

| Metric | Repro Source A | Repro Source B | Customer |
|--------|---------------|---------------|----------|
| Container RSS | ~1.2 GiB (stable) | ~1.2 GiB (stable) | **15–37 GB (growing)** |
| HeapAlloc | ~930 MB | ~849 MB | **16.9 GB** |
| HeapObjects | ~9M | ~9M | **128M** |
| GCCPUFrac | ~1% | ~0.84% | **1.9%** |

![Reproduction pods in K8s Explorer](screenshots/repro-k8s-explorer.png)
![Reproduction container.memory.usage](screenshots/repro-container-memory.png)

---

## 5. Conclusions

### Confirmed
- Config source mismatch: Source A (Helm confd) not applied, Source B (annotations) is active
- BestEffort QoS allows unbounded growth
- Python check is small contributor in Go profiles → leak is in Go runtime

### Ruled out by reproduction
- **Config parameters** (relation_regex, max_relations, custom queries) do not trigger the leak alone
- **Config delivery method** (confd vs kube_services annotations) makes no difference
- **Instance count** (52 instances on 1 CCR pod) does not trigger the leak in ~10min

### Not yet determined
- Whether the leak is **time-dependent** (needs hours/days to manifest)
- What specific factor in the customer's real environment triggers the leak
- Exact Go code path responsible (needs pprof heap profile from customer)

---

## 6. Next Steps

1. **Let reproduction run 12-24h** to check if the leak is time-dependent

2. **Request pprof heap profile** from customer while memory is high ?
   ```bash
   kubectl exec <CCR> -- curl -o heap.prof http://localhost:5000/debug/pprof/heap
   ```
   

3. **Compare with Agent 7.43.1** — same 52-instance setup with old version to confirm regression

4. **Double check with TEEs** 

---

## Repository Structure

```
.
├── README.md
├── screenshots/
│   ├── customer-ccr-memory-develop-k8s.png   # Customer's actual CCR memory
│   ├── repro-k8s-explorer.png                # Reproduction K8s Explorer
│   └── repro-container-memory.png            # Reproduction container.memory
└── reproduction/
    ├── docker-compose.yaml                   # Docker Compose repro (10 inst)
    ├── init-postgres.sh
    ├── monitor-memory.sh
    ├── conf.d/
    │   └── postgres.yaml
    └── k8s/
        ├── datadog-values.yaml               # Helm values Source A (confd)
        ├── datadog-values-source-b.yaml      # Helm values Source B (no confd)
        ├── pgb-services-annotated.yaml       # 52 annotated K8s services
        ├── postgres-deployment.yaml
        └── init-postgres-52.sh
```
