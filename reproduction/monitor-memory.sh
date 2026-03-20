#!/bin/bash
# Memory monitoring script for ZD-2498117 reproduction
# Polls Agent expvar endpoint every 30s and logs key memory stats

AGENT_CONTAINER="repro-zd-2498117-datadog-agent-1"
LOG_FILE="memory_monitor.csv"

echo "timestamp,rss_mb,heap_alloc_mb,heap_inuse_mb,heap_sys_mb,sys_mb,heap_objects,total_alloc_gb,num_gc,gc_cpu_pct" > "$LOG_FILE"

echo "=== Memory Monitor Started ==="
echo "Logging to $LOG_FILE"
echo "Press Ctrl+C to stop"
echo ""

while true; do
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Get RSS from container stats
  RSS_BYTES=$(docker stats --no-stream --format "{{.MemUsage}}" "$AGENT_CONTAINER" 2>/dev/null | awk -F'/' '{print $1}' | xargs)
  RSS_MB="$RSS_BYTES"

  # Get expvar memstats from agent
  MEMSTATS=$(docker exec "$AGENT_CONTAINER" curl -s http://localhost:5000/debug/vars 2>/dev/null)

  if [ -n "$MEMSTATS" ]; then
    HEAP_ALLOC=$(echo "$MEMSTATS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('memstats',{}).get('HeapAlloc',0))" 2>/dev/null)
    HEAP_INUSE=$(echo "$MEMSTATS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('memstats',{}).get('HeapInuse',0))" 2>/dev/null)
    HEAP_SYS=$(echo "$MEMSTATS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('memstats',{}).get('HeapSys',0))" 2>/dev/null)
    SYS=$(echo "$MEMSTATS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('memstats',{}).get('Sys',0))" 2>/dev/null)
    HEAP_OBJ=$(echo "$MEMSTATS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('memstats',{}).get('HeapObjects',0))" 2>/dev/null)
    TOTAL_ALLOC=$(echo "$MEMSTATS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('memstats',{}).get('TotalAlloc',0))" 2>/dev/null)
    NUM_GC=$(echo "$MEMSTATS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('memstats',{}).get('NumGC',0))" 2>/dev/null)
    GC_CPU=$(echo "$MEMSTATS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(round(d.get('memstats',{}).get('GCCPUFraction',0)*100,4))" 2>/dev/null)

    HEAP_ALLOC_MB=$(echo "scale=2; ${HEAP_ALLOC:-0} / 1048576" | bc 2>/dev/null)
    HEAP_INUSE_MB=$(echo "scale=2; ${HEAP_INUSE:-0} / 1048576" | bc 2>/dev/null)
    HEAP_SYS_MB=$(echo "scale=2; ${HEAP_SYS:-0} / 1048576" | bc 2>/dev/null)
    SYS_MB=$(echo "scale=2; ${SYS:-0} / 1048576" | bc 2>/dev/null)
    TOTAL_ALLOC_GB=$(echo "scale=2; ${TOTAL_ALLOC:-0} / 1073741824" | bc 2>/dev/null)

    echo "$TS,$RSS_MB,$HEAP_ALLOC_MB,$HEAP_INUSE_MB,$HEAP_SYS_MB,$SYS_MB,$HEAP_OBJ,$TOTAL_ALLOC_GB,$NUM_GC,$GC_CPU" >> "$LOG_FILE"
    printf "[%s] RSS=%s | HeapAlloc=%sMB | HeapInuse=%sMB | Sys=%sMB | Objects=%s | TotalAlloc=%sGB | GC=%s\n" \
      "$TS" "$RSS_MB" "$HEAP_ALLOC_MB" "$HEAP_INUSE_MB" "$SYS_MB" "$HEAP_OBJ" "$TOTAL_ALLOC_GB" "$NUM_GC"
  else
    echo "[$TS] Agent not reachable yet..."
  fi

  sleep 30
done
