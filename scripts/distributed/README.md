# Distributed benchmark setup (three-node)

Splits MuCache_Extended across three nodes so the network bottleneck is
realistic while the flame (shared-memory) hops stay intra-node:

```
  ┌──────── Node 0  (this host) ────────┐
  │                                     │
  │   oha (load generator)              │
  │   driver scripts (run_*, sweep_*)   │
  │                                     │
  └──────────────┬──────────────────────┘
                 │  HTTP (over network)
                 ▼
  ┌──────── Node 1  (microservice tier) ────────┐
  │                                             │
  │   frontend  ──▶ service2/service3/…         │
  │     nocm:  localhost HTTP                   │
  │     flame: shared-memory (tcs_api channels) │
  │   flame_daemon (one per channel)            │
  │                                             │
  └──────────────┬──────────────────────────────┘
                 │  Redis proto (experiment net)
                 ▼
  ┌──────── Node 2  (Redis backend) ─────┐
  │                                      │
  │   redis-server :6379                 │
  │                                      │
  └──────────────────────────────────────┘
```

Per-request flow: `N0 ──HTTP──▶ N1 (frontend → services, HTTP|shm) ──Redis──▶ N2`.

## Hosts / config

All scripts source `scripts/distributed/env.sh`. Override via env vars
before invoking. Defaults match the current Wisconsin cluster:

| var                 | default                              | role                                  |
|---------------------|--------------------------------------|---------------------------------------|
| `NODE1_HOST`        | `c220g5-111311.wisc.cloudlab.us`     | services                              |
| `NODE2_HOST`        | `c220g5-111306.wisc.cloudlab.us`     | redis                                 |
| `N1_PUBLIC_IP`      | resolved from `NODE1_HOST`           | what N0 dials for the frontend        |
| `N2_INTERNAL_IP`    | `10.10.1.3` (experiment net)         | what N1 dials for redis               |
| `SSH_USER`          | `$USER`                              | ssh login on N1, N2                   |
| `REPO_ROOT`         | `/mydata/MuCache_Extended`           | same path on N1                       |
| `FLAME_BIN`         | `/mydata/flame-benchmark/bin/flame_daemon` | flame daemon binary             |
| `REDIS_PORT`        | `6379`                               |                                       |
| `N_REQUESTS`        | `3000` (run_*) / `100000` (sweep_*)  | oha `-n`                              |
| `CONCURRENCY`       | `20`                                 | oha `-c` (single-shot runs)           |
| `CONCURRENCIES`     | `25 50 75 100 125 150 175 200`       | space-separated list (sweeps only)    |

Example overrides:

```bash
N1_PUBLIC_IP=10.10.1.2 \
N_REQUESTS=10000 CONCURRENCIES="10 20 50 100" \
    bash scripts/distributed/sweep_boutique.sh
```

## Smoke test

From N0:

```bash
bash scripts/distributed/check_setup.sh
```

Verifies ssh to N1 and N2, paths, binaries, and N1↔N2 reachability.

## Single-shot runs

```bash
bash scripts/distributed/run_chain.sh    nocm     # baseline HTTP
bash scripts/distributed/run_chain.sh    flame    # shm inter-service
bash scripts/distributed/run_hotel.sh    nocm
bash scripts/distributed/run_hotel.sh    flame
bash scripts/distributed/run_boutique.sh nocm
bash scripts/distributed/run_boutique.sh flame
```

Each:

1. Starts redis on N2 (bound 0.0.0.0).
2. SSHes to N1 and starts services + flame daemons.
3. Populates from N0 via HTTP to N1.
4. oha-benchmarks from N0.
5. Greps LATENCY REPORT blocks from N1 logs.
6. Tears down N1 (redis on N2 stays up).

Output → `latency_results/distributed/`.

## Throughput–latency sweeps

```bash
bash scripts/distributed/sweep_chain.sh
bash scripts/distributed/sweep_hotel.sh
bash scripts/distributed/sweep_boutique.sh
```

Each loops `(nocm, flame) × CONCURRENCIES`, writes per-run oha output to
`results/<bench>_distributed/<mode>_c<n>.txt` and a tidy CSV at
`results/<bench>_distributed/summary.csv`:

```
mode,concurrency,requests,p50_ms,p95_ms,p99_ms,rps,success_rate
nocm,25,100000,0.83ms,2.1ms,3.4ms,29840,100.00%
nocm,50,100000,1.50ms,3.0ms,5.9ms,33255,100.00%
flame,25,100000,0.51ms,1.1ms,1.8ms,48972,100.00%
…
```

That CSV is the input for the throughput–latency plot (throughput=`rps`,
latency=`p50_ms`/`p99_ms`, separate lines per `mode`).

## Files

| file                          | runs on        | role                                  |
|-------------------------------|----------------|---------------------------------------|
| `env.sh`                      | sourced        | hosts/IPs + `ssh_n1`/`ssh_n2`/`rsync_to_n1` |
| `check_setup.sh`              | N0             | preflight                             |
| `sync_to_N1.sh`               | N0             | rsync repo (incl. `bin/`) to N1       |
| `start_redis_N2.sh`           | N0 → ssh N2    | redis-server bound to 0.0.0.0         |
| `start_{chain,hotel,boutique}_N1.sh` | N0 → ssh N1 | services + flame daemons        |
| `stop_N1.sh`                  | N0 → ssh N1    | kill services + clean `/dev/shm`      |
| `run_{chain,hotel,boutique}.sh` | N0           | full one-shot benchmark drive         |
| `run_all.sh`                  | N0             | loop over benches × modes (single-c)  |
| `sweep_{chain,hotel,boutique}.sh` | N0         | multi-concurrency sweep + CSV         |

## Notes / gotchas

- **Redis on N2** binds `0.0.0.0:6379` with `--protected-mode no`. If
  your cluster restricts the port, override `N2_INTERNAL_IP` /
  `REDIS_PORT`, or use the experiment-network address.
- **Shared memory is local to N1**. Flame daemons and `/dev/shm/*`
  regions live on N1 only. The N0–N1 link is HTTP; the N1–N2 link is
  Redis proto over TCP.
- **N0 → N1 path**: defaults to the public IP. If N0 is colocated with
  N1 on the same experiment network later, override `N1_PUBLIC_IP` to
  the experiment-network IP for higher bandwidth.
- **killall vs pkill**: distributed scripts use `killall <exact-binary>`
  because `pkill -f <pattern>` self-kills under some shells where the
  running script's argv matches the pattern.
