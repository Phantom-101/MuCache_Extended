#ifndef FLAME_RPC_FLAME_C_API_H_
#define FLAME_RPC_FLAME_C_API_H_

/*
 * Plain-C API for flame RPC — CGO / FFI bindings.
 *
 * This API is a thin wrapper around the existing:
 *   flame::benchmark::TrustedCopierServiceBenchmark  (client / server side)
 *   flame::benchmark::TCSPoolManager                  (daemon side)
 *   flame::rpc::CounterQueue*, flame::rpc::Doorbell   (inside)
 *
 * Named-shm (shm_open) replaces memfd_create so independent processes can
 * connect by name without fd passing.
 *
 * Model: ONE channel name = ONE bidirectional RPC pipe between a client
 * and a server, mediated by a daemon.  Internally the daemon creates two
 * shm regions: <name>_cd and <name>_ds.
 *
 * Lifecycle:
 *   1. Daemon: flame_daemon_create() + flame_daemon_run() (blocks)
 *   2. Client: flame_client_connect() then send / recv in pairs
 *   3. Server: flame_server_connect() then recv / send in pairs
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    Tcs,
    CounterQueue,
    CounterQueueNoCopies
} FlameMode;

typedef struct FlameClient_ FlameClient;
typedef struct FlameServer_ FlameServer;
typedef struct FlameDaemon_ FlameDaemon;

/* ── Daemon ───────────────────────────────────────────────────────────────── */

/*
 * Create both shm regions (<name>_cd and <name>_ds) and initialize the
 * TCSPoolManager. Window_size is the per-side buffer count (default 256).
 * Blocking: nonzero = use futex doorbells, 0 = pure polling.
 *
 * Returns NULL on error (e.g. region already exists — unlink first).
 */
FlameDaemon* flame_daemon_create(FlameMode mode,
                                 const char* name,
                                 size_t      msg_size,
                                 uint32_t    window_size,
                                 int         blocking);

/*
 * Run the copy loop (client→server and server→client).
 * Blocks until flame_daemon_stop() is called from another thread.
 */
void flame_daemon_run(FlameDaemon* d);

/* Signal the run loop to exit (safe from another thread). */
void flame_daemon_stop(FlameDaemon* d);

/* Remove <name>_cd and <name>_ds from /dev/shm/. Call after stop. */
void flame_daemon_unlink(FlameDaemon* d);

/* Free the handle (also munmaps both regions). */
void flame_daemon_destroy(FlameDaemon* d);

/* ── Client ───────────────────────────────────────────────────────────────── */

/*
 * Open <name>_cd (daemon must have created it) and attach as the client.
 * msg_size and window_size must match the daemon's configuration.
 */
FlameClient* flame_client_connect(FlameMode mode,
                                  const char* name,
                                  size_t      msg_size,
                                  uint32_t    window_size,
                                  int         blocking);

/*
 * Send `len` bytes (copied into a shm-backed buffer). If `len` > msg_size
 * the call fails. Blocks (or spin-polls) until a send slot is free.
 * Returns 0 on success, -1 on error.
 */
int flame_client_send(FlameClient* c, const void* buf, size_t len);

/*
 * Receive one response. Copies up to `max_len` bytes into `buf` and writes
 * the actual length to *out_len. Blocks until a response arrives.
 * Returns 0 on success, -1 on error.
 */
int flame_client_recv(FlameClient* c, void* buf, size_t max_len, size_t* out_len);

void flame_client_destroy(FlameClient* c);

/* ── Server ───────────────────────────────────────────────────────────────── */

FlameServer* flame_server_connect(FlameMode mode,
                                  const char* name,
                                  size_t      msg_size,
                                  uint32_t    window_size,
                                  int         blocking);

int flame_server_recv(FlameServer* s, void* buf, size_t max_len, size_t* out_len);
int flame_server_send(FlameServer* s, const void* buf, size_t len);

void flame_server_destroy(FlameServer* s);

#ifdef __cplusplus
}
#endif

#endif
