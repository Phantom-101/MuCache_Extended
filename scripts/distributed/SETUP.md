# Two-machine setup guide

Step-by-step from a fresh pair of CloudLab nodes to a passing
`check_setup.sh` and a first benchmark run.

All shell blocks are copy-paste. Substitute hostnames/usernames where
they differ from the defaults below.

## 0. Role assignment

| role | host                       | what runs here                        |
|------|----------------------------|---------------------------------------|
| **A** | `er012.utah.cloudlab.us`  | request client (`oha`), Redis backend |
| **B** | `er064.utah.cloudlab.us`  | microservices + flame daemons         |

Keep this mapping consistent: everything below assumes A=er012 and
B=er064. If you swap them, override `NODE0_HOST` / `NODE1_HOST`
in `env.sh` or export them before each command.

## 1. SSH prerequisites

From your **laptop** (the terminal you drive experiments from):

```bash
# Verify you can log in to both.
ssh tengj@er012.utah.cloudlab.us    # = A
ssh tengj@er064.utah.cloudlab.us    # = B
```

The orchestrator runs **on A** and SSHes to **B**, so A needs
key-based, non-interactive access to B. On **A**:

```bash
# On A: create a key if you don't already have one
test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519

# On A: push the public key to B
ssh-copy-id tengj@er064.utah.cloudlab.us

# On A: confirm it's password-less
ssh -o BatchMode=yes tengj@er064.utah.cloudlab.us "hostname"
#   -> er064.utah.cloudlab.us  (or the short hostname)
```

## 2. Install dependencies on **both** machines

Run this on **A** and then again on **B**:

```bash
sudo apt-get update
sudo apt-get install -y build-essential redis-server curl rsync git pkg-config libzmq3-dev

# oha (HTTP load generator) — prebuilt binary is easiest
curl -L -o /tmp/oha https://github.com/hatoo/oha/releases/latest/download/oha-linux-amd64
sudo install /tmp/oha /usr/local/bin/oha
oha --version

# Go 1.19+ (the Makefile expects /usr/local/go/bin/go)
if ! /usr/local/go/bin/go version >/dev/null 2>&1; then
    curl -L -o /tmp/go.tgz https://go.dev/dl/go1.21.6.linux-amd64.tar.gz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf /tmp/go.tgz
fi
/usr/local/go/bin/go version
```

Stop the system redis (we'll run our own bound to 0.0.0.0 on A):

```bash
sudo systemctl disable --now redis-server 2>/dev/null || true
```

## 3. Clone the two repos on **both** machines

On **A** and then **B**:

```bash
sudo mkdir -p /mydata && sudo chown "$USER" /mydata
cd /mydata

# This repo
git clone git@github.com:tengjiang/MuCache_Extended.git
cd MuCache_Extended
git checkout distributed
cd ..

# flame-benchmark (tcs_api branch — the shared-memory RPC we use)
git clone git@github.com:samkumar/flame-benchmark.git
cd flame-benchmark
git checkout tcs_api
```

> If you don't have GitHub SSH access from these nodes, use the HTTPS
> URL (`https://github.com/…`) instead.

## 4. Build everything

On **A** and **B** (you can also build only on A and `rsync` to B —
see step 6):

```bash
# flame_daemon → /mydata/flame-benchmark/bin/flame_daemon
cd /mydata/flame-benchmark
make -j
ls -la bin/flame_daemon

# MuCache binaries → /mydata/MuCache_Extended/bin/*
cd /mydata/MuCache_Extended
make -j
ls bin/ | wc -l          # expect ~40 (3 benches × {nocm,flame} × services)
```

## 5. Network / firewall

Machine **B** must reach **A** on the Redis port, and **A** must reach
**B** on the frontend ports. On CloudLab all intra-experiment traffic
is normally unblocked, but verify:

```bash
# On B: confirm A is reachable
ping -c1 er012.utah.cloudlab.us

# On A: confirm B is reachable
ping -c1 er064.utah.cloudlab.us
```

If you have a CloudLab **experiment network** (check `ip -4 addr` for
a `10.10.1.x` or similar address), prefer those IPs — they are lower
latency and do not go through the control plane:

```bash
# On A, look up the experiment-network IPs of both nodes
ip -4 addr show | grep -E 'inet 10\.'   # note A's
ssh tengj@er064.utah.cloudlab.us "ip -4 addr show | grep -E 'inet 10\\.'"

# Then, when running benchmarks, override:
export NODE0_IP=10.10.1.1
export N1_PUBLIC_IP=10.10.1.2
```

## 6. (Optional) build only on A and sync to B

If builds are slow and you'd rather iterate on A:

```bash
# On A, after `make` succeeds:
cd /mydata/MuCache_Extended
bash scripts/distributed/sync_to_B.sh
```

`sync_to_B.sh` rsyncs the source tree + `bin/` from A → B, skipping
`.git`, `logs/`, and `latency_results/`.

## 7. Preflight check

On **A**:

```bash
cd /mydata/MuCache_Extended
bash scripts/distributed/check_setup.sh
```

Expected output — every row `[ok]`:

```
Configuration:
  NODE0_HOST = er012.utah.cloudlab.us  (128.110.220.12)
  NODE1_HOST = er064.utah.cloudlab.us  (128.110.220.64)
  ...

A-side (this host):
  [ok]   repo present on A
  [ok]   bin/chain_service1_nocm
  [ok]   oha installed
  [ok]   redis-server installed
  [ok]   curl installed

B-side (via ssh):
  [ok]   ssh to B (BatchMode)
  [ok]   repo present on B
  [ok]   bin/chain_service1_flame on B
  [ok]   flame_daemon on B

Network B → A reachability:
  [ok]   B can ping A (128.110.220.12)

[dist …] ALL CHECKS PASSED — ready to run benchmarks.
```

Any `[FAIL]` → fix the matching step above, then re-run.

## 8. First benchmark (smallest: chain / nocm)

On **A**:

```bash
cd /mydata/MuCache_Extended
bash scripts/distributed/run_chain.sh nocm
```

You should see:

1. Redis start on A.
2. `Starting chain services on B...` (one ssh).
3. `Populating chain keys...` (100 HTTP writes A → B).
4. `Benchmark (3000 req, 20 concurrent)...` followed by an oha
   latency-percentile table.
5. `Collecting service logs from B...` → a printed block with the
   per-service LATENCY REPORTs.
6. `Stopping services on B...` — teardown.

Results land in:

```
latency_results/distributed/
├── chain_nocm.txt            # per-service latency reports
├── chain_nocm_oha.txt        # full oha output
└── start_chain_nocm.log      # captured B-side startup log
```

If that looks right, repeat with `flame` to exercise the shared-memory
path:

```bash
bash scripts/distributed/run_chain.sh flame
```

## 9. All benchmarks

Once chain works for both modes, run the full sweep:

```bash
bash scripts/distributed/run_all.sh
# = 3 benchmarks × 2 modes = 6 runs, ~5–10 min depending on N_REQUESTS
```

Subsetting is supported:

```bash
bash scripts/distributed/run_all.sh "chain hotel"           # skip boutique
bash scripts/distributed/run_all.sh "boutique" "flame"      # boutique/flame only
```

Tune the load:

```bash
N_REQUESTS=10000 CONCURRENCY=50 bash scripts/distributed/run_all.sh
```

## 10. Teardown / cleanup

Redis on A is left running between runs (intentional — each run flushes
it). When you're done:

```bash
# On A
pkill -x redis-server

# On B (safer to go through the helper)
ssh tengj@er064.utah.cloudlab.us "bash /mydata/MuCache_Extended/scripts/distributed/stop_N1.sh"
```

## Troubleshooting

- **`ssh to B (BatchMode)` fails** — re-run `ssh-copy-id` from A, and
  try once interactively: `ssh tengj@er064.utah.cloudlab.us true`.
- **Services on B never come up (heartbeat timeout)** — the most
  common cause is the services on B failing to reach Redis on A.
  `ssh tengj@er064 'tail /mydata/MuCache_Extended/logs/chain/service1.log'`
  will show the connection error. Fix the firewall or switch to the
  experiment network IP (step 5).
- **`Key Not Found` panic in a leaf service** — your populate step
  didn't land. Confirm A can reach B's frontend + the populate
  endpoints (`curl -v http://$N1_PUBLIC_IP:4103/heartbeat` for boutique
  currency, etc.).
- **`flame_daemon` exits immediately on B** — stale `/dev/shm/*` files
  from a previous run. `stop_N1.sh` cleans these; run it once, then
  retry. If it happens repeatedly, the daemon may be crashing on a
  size/alignment issue — check `logs/<bench>/flame_daemon_*.log` on B.
- **`pkill -f` self-killing in older scripts** — only affects
  `scripts/local/start_hotel.sh` / `start_boutique.sh`. The distributed
  scripts use `killall <exact-binary>` and are not affected.

## Checklist (the short version)

- [ ] Step 1: A can `ssh -o BatchMode=yes` to B, no password.
- [ ] Step 2: `oha`, `redis-server`, `/usr/local/go/bin/go` on both.
- [ ] Step 3: `/mydata/MuCache_Extended` on both, branch = `distributed`.
- [ ] Step 3: `/mydata/flame-benchmark` on both, branch = `tcs_api`.
- [ ] Step 4: both `bin/flame_daemon` and `MuCache_Extended/bin/*` built.
- [ ] Step 5: B can ping A, A can ping B.
- [ ] Step 7: `check_setup.sh` is all green.
- [ ] Step 8: `run_chain.sh nocm` prints an oha latency table.
- [ ] Step 9: `run_all.sh` completes and writes 6 files into
      `latency_results/distributed/`.

When all six are checked: push the branch.
