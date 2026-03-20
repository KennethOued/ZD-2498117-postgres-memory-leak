# ZD-2498117 / CONS-8148 — Postgres Check High Memory on CCR Pods

**Ticket**: [ZD-2498117](https://datadog.zendesk.com/agent/tickets/2498117)  
**Jira**: [CONS-8148](https://datadoghq.atlassian.net/browse/CONS-8148)  
**Related**: [SDBM-2278](https://datadoghq.atlassian.net/browse/SDBM-2278) (similar pattern, different customer, Agent 7.73.3)  
**Related**: [CONS-8086](https://datadoghq.atlassian.net/browse/CONS-8086) (engineering review)  
**Investigator**: Kenneth Ouedraogo (TSE2)

---

## 1. Issue

After upgrading Agent from **7.43.1 → 7.74.1** (Helm 3.151.2), CCR pods memory grows to **15–40 GB per pod** within hours.

Customer tried:
- **Doubling CCR replicas** (6 → 12): reduced instances/runner to 26, but **total memory jumped to ~190 GB** ([CONS-8148 comment, Mar 13](https://datadoghq.atlassian.net/browse/CONS-8148))
- **Disabling custom metrics**: memory improved, but **customer says not acceptable** — those metrics are critical

| Metric | Agent 7.43.1 (prod, 6 CCR) | Agent 7.74.1 (dev, 6 CCR) | Agent 7.74.1 (dev, 12 CCR) |
|--------|---------------------------|--------------------------|---------------------------|
| Total CCR memory | ~18 GiB | ~100 GiB | **~190 GiB** |
| Per-pod range | ~3 GiB | ~15–40 GiB | 2–29 GiB |

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
*Source: `postgres_manual_check (2).log`, line 1*

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
*Source: `postgres_manual_check (2).log`, resolved instance config*

### Key memstats from flare (~22.5h uptime)

```
Alloc:         16.9 GB      HeapObjects:  128M
HeapInuse:     21.0 GB      TotalAlloc:   20 TB
HeapSys:       45.4 GB      NumGC:        5,710
Sys:           46.2 GB      GCCPUFraction: 1.9%
```
*Source: `expvar/memstats`*

### Dual config source (confirmed finding)

Customer has two config sources for Postgres:
- **Source A** (Helm `clusterAgent.confd`): `max_relations: 50`, `schemas: [public]`, `dbm: true` — **NOT applied**
- **Source B** (K8s annotations on `pgb-*` services): `max_relations: 300`, `relation_regex: .*`, `dbm: false` — **actually running**

All 52 instances in `status.log` show Source B:
```
postgres:1240cadb26958901 [OK]
  Configuration Source: kube_services:kube_service://stage/pgb-tabby-dev-pg-17-plugins-auth[0]
```
*Source: `status.log`, Running Checks section*


---

## 4. Reproduction

### Setup

Deployed on **minikube** (4 CPU, 12 GB) via Helm:
- Agent **7.74.1** (exact version)
- **52 Postgres instances** with exact Source B config
- Postgres 16, **52 databases × 300 tables** each
- CCR with **no resource limits** (BestEffort)
- 1 CCR replica (all 52 checks on one pod)

### Result: Memory did NOT explode

| Metric | Reproduction (~20 min) | Customer (~22.5h) |
|--------|------------------------|-------------------|
| Container RSS | **~650 MiB – 1.1 GiB (stable)** | **15–37 GB (growing)** |
| HeapAlloc | ~600–930 MB (oscillating) | 16.9 GB |
| HeapObjects | ~9M | 128M |
| TotalAlloc | ~130 GB | 20 TB |
| GCCPUFrac | ~1% | 1.9% |

![Kubernetes Explorer - Reproduction pods](screenshots/repro-k8s-explorer.png)
![container.memory.usage - Reproduction CCR pod](screenshots/repro-container-memory.png)

### What this tells us

1. **Config alone does not trigger the leak.** Same version + same config + same instance count = stable ~1 GB.
2. **The leak is triggered by something we are NOT replicating.**

### What we do NOT know

- Whether the leak needs **12–24+ hours** to manifest (our test ran ~20 min)
- Whether **PGBouncer** as intermediary triggers different behavior (customer connects through `pgb-*` services)
- Customer's **actual Postgres server versions** and real schema complexity
- Whether the leak is in **Go runtime internals** (tagger, metadata, serialization) rather than the check itself — consistent with Aldrick's profile observation that Python check is small contributor

---

## 5. Next Steps

1. **Let reproduction run 12-24h** — check if leak is time-dependent

2. **Request from customer**:
   - pprof heap profile from a CCR pod while memory is high: `kubectl exec <CCR> -- curl -o heap.prof http://localhost:5000/debug/pprof/heap`
   - Postgres server versions for the monitored databases
   - PGBouncer pooling mode (transaction vs session)

3. **Add PGBouncer to reproduction** — customer connects through PGBouncer, we connect directly

4. **Compare with Agent 7.43.1** — same 52-instance setup with old agent to confirm regression

5. **Check findings with TEEs**

---

## Repository Structure

```
.
├── README.md
├── screenshots/
│   ├── repro-k8s-explorer.png
│   └── repro-container-memory.png
└── reproduction/
    ├── docker-compose.yaml
    ├── init-postgres.sh
    ├── monitor-memory.sh
    ├── conf.d/
    │   └── postgres.yaml
    └── k8s/
        ├── datadog-values.yaml          # Helm values (52 instances)
        ├── postgres-deployment.yaml
        └── init-postgres-52.sh
```
