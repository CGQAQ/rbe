#!/usr/bin/env bash
#
# manage.sh — NativeLink RBE cluster manager for Chromium + Siso builds on macOS.
#
# Turns Mac Minis into a Remote Build Execution cluster:
#   - master node: CAS + Action Cache + scheduler (clients and workers connect here)
#   - worker node: executes compile actions, streams artifacts to/from the master CAS
#
# Quick start:
#   Mac Mini #1 (master):  ./manage.sh install && ./manage.sh init master && ./manage.sh start
#   Mac Mini #2 (worker):  ./manage.sh install && ./manage.sh init worker --master <master-ip> && ./manage.sh start
#   Dev machine:           ./manage.sh siso-setup /path/to/chromium/src --master <master-ip>
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths & constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$SCRIPT_DIR/.nativelink"
SERVER_DATA_DIR="$SCRIPT_DIR/.nativelink-server"
WORKER_DATA_DIR="$SCRIPT_DIR/.nativelink-worker"

BIN_DIR="$STATE_DIR/bin"
SRC_DIR="$STATE_DIR/src"
CONF_DIR="$STATE_DIR/conf"
LOG_DIR="$STATE_DIR/logs"
RUN_DIR="$STATE_DIR/run"
ENV_FILE="$STATE_DIR/cluster.env"
NATIVELINK_BIN="$BIN_DIR/nativelink"

LAUNCHD_LABEL_PREFIX="com.rbe-ftw.nativelink"

# Pinned NativeLink version (git tag). Override with NATIVELINK_VERSION in cluster.env.
DEFAULT_NATIVELINK_VERSION="v1.6.2"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m[rbe-ftw]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[rbe-ftw]\033[0m WARN: %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[rbe-ftw]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: ./manage.sh <command> [args]

Cluster node commands:
  install [--from-source]      Install NativeLink into .nativelink/bin
                               (prebuilt release binary, falls back to cargo build)
  init master [opts]           Configure this machine as the master (CAS + scheduler)
  init worker --master <host>  Configure this machine as a worker
  init both [opts]             Master + a local worker on the same machine
  config                       Regenerate config files from .nativelink/cluster.env
  start | stop | restart       Manage the node's NativeLink process(es)
  status                       Show process / port status
  logs [master|worker] [-f]    Show (or follow) logs
  service install|uninstall|status
                               Run via launchd (auto-start at login, keep-alive)
  doctor                       Health checks (ports, connectivity, limits, disk)
  env                          Show the active cluster configuration

Chromium client commands:
  ramdisk                      Mount RAM disk for worker scratch (set WORKER_DATA_DIR=/Volumes/NLRam/worker)
  siso-setup <chromium-src> [--master <host>]
                               Write .sisoenv / backend.star / rewrapper_mac.cfg
                               into a Chromium checkout so Siso uses this cluster
  siso-env [--master <host>]   Print the Chromium/Siso setup without writing files

init master options:
  --bind <ip>          Bind address                        (default 0.0.0.0)
  --cas-port <port>    Client-facing gRPC port             (default 50051)
  --worker-port <port> Worker API / health port            (default 50061)
  --cas-size-gb <n>    CAS disk budget in GB               (default 200)
  --ac-size-gb <n>     Action-cache disk budget in GB      (default 10)
  --instance <name>    REAPI instance name                 (default main)

init worker options:
  --master <host>      Master hostname/IP (required)
  --cas-port <port>    Master client gRPC port             (default 50051)
  --worker-port <port> Master worker API port              (default 50061)
  --name <name>        Worker name                         (default: hostname)
  --slots <n>          Concurrent actions                  (default: CPU count)
  --fast-cache-gb <n>  Local CAS cache budget in GB        (default 50)
  --instance <name>    REAPI instance name — must match the master's (default main)

init both accepts all of the above (worker connects to the master locally).

siso-setup / siso-env options:
  --master <host[:port]>  Master address (port defaults to the cluster's --cas-port)
  --instance <name>       Override instance name (when run off-cluster)
  --cas-port <port>       Override master client port
EOF
}

require_env() {
  [ -f "$ENV_FILE" ] || die "Not initialized. Run './manage.sh init master' or './manage.sh init worker --master <host>' first."
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  : "${ROLE:?corrupt $ENV_FILE: ROLE missing}"
}

mkdirs() {
  mkdir -p "$BIN_DIR" "$CONF_DIR" "$LOG_DIR" "$RUN_DIR"
}

# Roles that run on this node, in start order.
node_roles() {
  case "$ROLE" in
    master) echo "master" ;;
    worker) echo "worker" ;;
    both)   echo "master worker" ;;
    *) die "Unknown ROLE '$ROLE' in $ENV_FILE" ;;
  esac
}

node_roles_reversed() {
  case "$ROLE" in
    both) echo "worker master" ;;
    *)    node_roles ;;
  esac
}

has_role() { # $1=role
  case " $(node_roles) " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

config_path_for() { echo "$CONF_DIR/$1.json5"; }
pid_file_for()    { echo "$RUN_DIR/$1.pid"; }
log_file_for()    { echo "$LOG_DIR/$1.log"; }

# Best-effort LAN IP of this machine (for printing client instructions).
local_lan_ip() {
  local ip=""
  local iface
  iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')" || true
  if [ -n "${iface:-}" ]; then
    ip="$(ipconfig getifaddr "$iface" 2>/dev/null)" || true
  fi
  if [ -z "$ip" ]; then
    ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)" || true
  fi
  echo "${ip:-}"
}

# The master address as seen from OTHER machines.
master_address_for_clients() {
  if [ "${1:-}" != "" ]; then
    echo "$1"
  elif [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    case "$ROLE" in
      worker) echo "$MASTER_HOST" ;;
      *)      local_lan_ip ;;
    esac
  else
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# install: prebuilt release binary, falling back to a cargo source build
# ---------------------------------------------------------------------------
nativelink_version() {
  local v="$DEFAULT_NATIVELINK_VERSION"
  if [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    v="${NATIVELINK_VERSION:-$DEFAULT_NATIVELINK_VERSION}"
  fi
  echo "$v"
}

binary_works() {
  [ -x "$NATIVELINK_BIN" ] && "$NATIVELINK_BIN" --version >/dev/null 2>&1
}

install_prebuilt() {
  local version="$1"
  local arch; arch="$(uname -m)"
  if [ "$(uname -s)" != "Darwin" ] || [ "$arch" != "arm64" ]; then
    warn "No prebuilt NativeLink binary for $(uname -s)/$arch — building from source instead."
    return 1
  fi
  local asset="nativelink-${version#v}-aarch64-apple-darwin.tar.gz"
  local url="https://github.com/TraceMachina/nativelink/releases/download/$version/$asset"
  local tmp; tmp="$(mktemp -d)"
  log "Downloading $asset from GitHub releases..."
  if ! curl -fL --retry 3 -o "$tmp/$asset" "$url"; then
    warn "Download failed: $url"
    rm -rf "$tmp"
    return 1
  fi
  tar -xzf "$tmp/$asset" -C "$tmp" nativelink
  xattr -d com.apple.quarantine "$tmp/nativelink" 2>/dev/null || true
  install -m 0755 "$tmp/nativelink" "$NATIVELINK_BIN"
  rm -rf "$tmp"
  # The release binary is nix-built; verify it actually runs on this machine
  # (it may link dylibs from /nix/store that don't exist here).
  if ! binary_works; then
    warn "Prebuilt binary does not run on this machine (likely /nix/store dylib deps):"
    otool -L "$NATIVELINK_BIN" 2>/dev/null | sed 's/^/    /' >&2 || true
    rm -f "$NATIVELINK_BIN"
    return 1
  fi
  return 0
}

install_from_source() {
  local version="$1"
  command -v git >/dev/null || die "git is required"
  command -v cargo >/dev/null || die "Rust toolchain required. Install via https://rustup.rs and re-run."
  command -v protoc >/dev/null || die "protoc is required to build NativeLink. Install with: brew install protobuf"

  log "Fetching NativeLink $version source..."
  if [ -d "$SRC_DIR/.git" ]; then
    git -C "$SRC_DIR" fetch --depth 1 origin tag "$version" 2>/dev/null || git -C "$SRC_DIR" fetch --tags origin
    git -C "$SRC_DIR" checkout -q "$version"
  else
    git clone --depth 1 --branch "$version" https://github.com/TraceMachina/nativelink "$SRC_DIR"
  fi

  log "Building nativelink (release). The first build takes a while..."
  (cd "$SRC_DIR" && cargo build --release --bin nativelink)
  install -m 0755 "$SRC_DIR/target/release/nativelink" "$NATIVELINK_BIN"
}

cmd_install() {
  mkdirs
  local from_source=0
  [ "${1:-}" = "--from-source" ] && from_source=1
  local version; version="$(nativelink_version)"

  if binary_works && "$NATIVELINK_BIN" --version 2>/dev/null | grep -q "${version#v}"; then
    log "nativelink $version already installed at $NATIVELINK_BIN"
    return 0
  fi

  if [ "$from_source" = 1 ] || ! install_prebuilt "$version"; then
    install_from_source "$version"
  fi
  binary_works || die "Installed binary does not run. Try './manage.sh install --from-source'."
  log "Installed: $("$NATIVELINK_BIN" --version 2>/dev/null | head -1)"
}

# ---------------------------------------------------------------------------
# init: write cluster.env, then generate configs
# ---------------------------------------------------------------------------
cmd_init() {
  local role="${1:-}"; shift || true
  case "$role" in master|worker|both) ;; *) usage; die "init requires a role: master, worker, or both" ;; esac

  local bind_ip="0.0.0.0"
  local master_host=""
  local cas_port=50051
  local worker_port=50061
  local cas_size_gb=200
  local ac_size_gb=10
  local fast_cache_gb=50
  local worker_name; worker_name="$(hostname -s | sed 's/[^A-Za-z0-9._-]/-/g')"
  local slots; slots="$(sysctl -n hw.ncpu)"
  local instance_name="main"

  while [ $# -gt 0 ]; do
    case "$1" in
      --bind)          bind_ip="$2"; shift 2 ;;
      --master)        master_host="$2"; shift 2 ;;
      --cas-port)      cas_port="$2"; shift 2 ;;
      --worker-port)   worker_port="$2"; shift 2 ;;
      --cas-size-gb)   cas_size_gb="$2"; shift 2 ;;
      --ac-size-gb)    ac_size_gb="$2"; shift 2 ;;
      --fast-cache-gb) fast_cache_gb="$2"; shift 2 ;;
      --name)          worker_name="$2"; shift 2 ;;
      --slots)         slots="$2"; shift 2 ;;
      --instance)      instance_name="$2"; shift 2 ;;
      *) die "Unknown option for init: $1" ;;
    esac
  done

  case "$role" in
    master|both)
      # If the master binds a specific address, the co-located worker ('both')
      # and doctor must dial that address — 127.0.0.1 only works for 0.0.0.0.
      if [ "$bind_ip" != "0.0.0.0" ] && [ "$bind_ip" != "127.0.0.1" ]; then
        master_host="$bind_ip"
      else
        master_host="127.0.0.1"
      fi
      ;;
    worker) [ -n "$master_host" ] || die "init worker requires --master <host-or-ip-of-master>" ;;
  esac
  [ -n "$instance_name" ] || die "--instance must not be empty"
  case "$instance_name" in *[!A-Za-z0-9._-]*) die "--instance may only contain [A-Za-z0-9._-]" ;; esac
  case "$worker_name" in *[!A-Za-z0-9._-]*) die "--name may only contain [A-Za-z0-9._-]" ;; esac

  # Re-init may change the role: stop processes/services from the previous
  # configuration so nothing is left orphaned under the old role.
  if [ -f "$ENV_FILE" ]; then
    local r
    for r in worker master; do
      if launchd_loaded "$r"; then
        launchctl unload "$(plist_path_for "$r")" 2>/dev/null || true
        rm -f "$(plist_path_for "$r")"
        warn "removed previous launchd service for $r — re-run './manage.sh service install' if wanted"
      fi
      if proc_running "$r"; then stop_role "$r"; fi
    done
  fi

  mkdirs
  cat > "$ENV_FILE" <<EOF
# Generated by manage.sh init — edit and run './manage.sh config' to regenerate configs.
ROLE="$role"
MASTER_HOST="$master_host"
BIND_IP="$bind_ip"
CAS_PORT="$cas_port"
WORKER_PORT="$worker_port"
CAS_SIZE_GB="$cas_size_gb"
AC_SIZE_GB="$ac_size_gb"
FAST_CACHE_GB="$fast_cache_gb"
WORKER_NAME="$worker_name"
WORKER_SLOTS="$slots"
INSTANCE_NAME="$instance_name"
NATIVELINK_VERSION="$DEFAULT_NATIVELINK_VERSION"
EOF
  log "Wrote $ENV_FILE"
  cmd_config

  echo ""
  log "Next steps:"
  echo "    ./manage.sh install     # if not done yet"
  echo "    ./manage.sh start"
  echo "    ./manage.sh doctor"
  if [ "$role" != "worker" ]; then
    local ip; ip="$(local_lan_ip)"
    echo ""
    echo "  Point Chromium checkouts at this master with:"
    echo "    ./manage.sh siso-setup /path/to/chromium/src --master ${ip:-<this-machine-ip>}"
  fi
}

cmd_config() {
  require_env
  mkdirs
  if has_role master; then generate_master_config; else rm -f "$(config_path_for master)"; fi
  if has_role worker; then generate_worker_config; else rm -f "$(config_path_for worker)"; fi
}

# ---------------------------------------------------------------------------
# NativeLink config generation
#
# Schema matches NativeLink v1.6.2 (list-form stores/schedulers/services).
# Platform-property contract with Chromium/Siso (see siso-setup):
#   Siso sends:            OSFamily=Mac, label:action_default=1 (or
#                          label:action_large=1 for links), cpu_count=1
#   Workers advertise:     OSFamily=Mac, both labels, cpu_count=<slots>
#   cpu_count is a "minimum" property: each action consumes 1 slot of the
#   worker's advertised capacity, giving per-worker concurrency control.
# ---------------------------------------------------------------------------
generate_master_config() {
  local out; out="$(config_path_for master)"
  mkdir -p "$SERVER_DATA_DIR/cas/content" "$SERVER_DATA_DIR/cas/tmp" \
           "$SERVER_DATA_DIR/ac/content" "$SERVER_DATA_DIR/ac/tmp"
  cat > "$out" <<EOF
// Generated by manage.sh — do not edit by hand; edit .nativelink/cluster.env
// and run './manage.sh config' instead.
{
  stores: [
    {
      // Content-addressable store: compile inputs/outputs, lz4-compressed at rest.
      name: "CAS_MAIN_STORE",
      compression: {
        compression_algorithm: {
          lz4: {},
        },
        backend: {
          filesystem: {
            content_path: "$SERVER_DATA_DIR/cas/content",
            temp_path: "$SERVER_DATA_DIR/cas/tmp",
            eviction_policy: {
              max_bytes: "${CAS_SIZE_GB}gb",
            },
          },
        },
      },
    },
    {
      name: "AC_FILESYSTEM_STORE",
      filesystem: {
        content_path: "$SERVER_DATA_DIR/ac/content",
        temp_path: "$SERVER_DATA_DIR/ac/tmp",
        eviction_policy: {
          max_bytes: "${AC_SIZE_GB}gb",
        },
      },
    },
    {
      // Only serve action-cache hits whose output blobs still exist in the CAS,
      // so CAS eviction can never produce broken cache hits.
      name: "AC_MAIN_STORE",
      completeness_checking: {
        backend: {
          ref_store: { name: "AC_FILESYSTEM_STORE" },
        },
        cas_store: {
          ref_store: { name: "CAS_MAIN_STORE" },
        },
      },
    },
  ],
  schedulers: [
    {
      name: "MAIN_SCHEDULER",
      simple: {
        // Default worker_timeout_s is 5s; a worker saturated by concurrent
        // clang actions (and CAS input downloads) can miss keep-alives that
        // long and gets evicted, killing all its in-flight actions. 60s
        // tolerates load spikes; genuinely dead workers still get pruned.
        worker_timeout_s: 60,
        // Chromium compiles routinely outlive the 60s defaults below. If an
        // operation dies while the Execute stream is briefly interrupted,
        // siso's WaitExecution reconnect gets NotFound and re-runs the
        // action from scratch — an endless execute/orphan loop where the
        // worker finishes work no client can ever collect.
        client_action_timeout_s: 3600,
        retain_completed_for_s: 600,
        max_job_retries: 10,
        // A worker occupied by a long compile + result upload must not have
        // its action recycled to the queue mid-upload (default ~5min was
        // causing an endless execute/requeue loop under load).
        max_action_executing_timeout_s: 1800,
        supported_platform_properties: {
          // Consumable worker capacity: each Chromium action requests
          // cpu_count=1; a worker advertising cpu_count=N runs N actions.
          cpu_count: "minimum",
          // "priority" (not "exact"): clients variously send Mac/Darwin/etc;
          // on an all-Mac cluster the value is informational. Workers still
          // must advertise the key.
          OSFamily: "priority",
          "container-image": "priority",
          "label:action_default": "priority",
          "label:action_large": "priority",
          // Sent by some Chromium/Siso actions; safe to ignore.
          InputRootAbsolutePath: "ignore",
        },
      },
    },
  ],
  servers: [
    {
      // Frontend: Siso clients and worker grpc stores connect here.
      name: "public",
      listener: {
        http: {
          socket_address: "$BIND_IP:$CAS_PORT",
          // Default 64KB HTTP/2 receive windows throttle concurrent CAS
          // uploads to a crawl; give each stream and the connection real
          // buffer space (values in bytes).
          advanced_http: {
            experimental_http2_initial_stream_window_size: 4194304,
            experimental_http2_initial_connection_window_size: 33554432,
          },
        },
      },
      services: {
        cas: [
          { instance_name: "", cas_store: "CAS_MAIN_STORE" },
          { instance_name: "$INSTANCE_NAME", cas_store: "CAS_MAIN_STORE" },
        ],
        ac: [
          { instance_name: "", ac_store: "AC_MAIN_STORE" },
          { instance_name: "$INSTANCE_NAME", ac_store: "AC_MAIN_STORE" },
        ],
        execution: [
          { instance_name: "", cas_store: "CAS_MAIN_STORE", scheduler: "MAIN_SCHEDULER" },
          { instance_name: "$INSTANCE_NAME", cas_store: "CAS_MAIN_STORE", scheduler: "MAIN_SCHEDULER" },
        ],
        capabilities: [
          { instance_name: "", remote_execution: { scheduler: "MAIN_SCHEDULER" } },
          { instance_name: "$INSTANCE_NAME", remote_execution: { scheduler: "MAIN_SCHEDULER" } },
        ],
        bytestream: [
          { instance_name: "", cas_store: "CAS_MAIN_STORE" },
          { instance_name: "$INSTANCE_NAME", cas_store: "CAS_MAIN_STORE" },
        ],
      },
    },
    {
      // Backend: workers connect here; also serves /status health checks.
      name: "private",
      listener: {
        http: {
          socket_address: "$BIND_IP:$WORKER_PORT",
          advanced_http: {
            experimental_http2_initial_stream_window_size: 4194304,
            experimental_http2_initial_connection_window_size: 33554432,
          },
        },
      },
      services: {
        worker_api: {
          scheduler: "MAIN_SCHEDULER",
        },
        admin: {},
        health: {},
      },
    },
  ],
  global: {
    max_open_files: 24576,
  },
}
EOF
  log "Wrote $out"
}

generate_worker_config() {
  local out; out="$(config_path_for worker)"
  case "$WORKER_DATA_DIR" in
    /Volumes/*)
      mount | grep -q " ${WORKER_DATA_DIR%/*} " ||         die "WORKER_DATA_DIR $WORKER_DATA_DIR is not mounted — run './manage.sh ramdisk' first (RAM disks do not survive reboot)"
      ;;
  esac
  mkdir -p "$WORKER_DATA_DIR/cas/content" "$WORKER_DATA_DIR/cas/tmp" "$WORKER_DATA_DIR/work"
  cat > "$out" <<EOF
// Generated by manage.sh — do not edit by hand; edit .nativelink/cluster.env
// and run './manage.sh config' instead.
{
  stores: [
    {
      name: "GRPC_CAS_STORE",
      grpc: {
        instance_name: "$INSTANCE_NAME",
        endpoints: [
          { address: "grpc://$MASTER_HOST:$CAS_PORT" },
        ],
        store_type: "cas",
        // Coalesce many tiny blob reads (Chromium input trees are mostly
        // small headers) into batched RPCs instead of one round-trip each.
        experimental_read_batching: {
          max_blob_size_bytes: "256kb",
          max_batch_bytes: "4mb",
          dispatch_slots: 16,
        },
        // v1.6.2 forces a 120s default rpc timeout; a result upload that
        // outlives it is killed mid-stream and retried from scratch forever
        // (upstream fix: nativelink#2195). Give uploads room instead.
        rpc_timeout_s: 900,
        // One HTTP/2 connection cannot carry WORKER_SLOTS concurrent input
        // downloads + result uploads (flow-control starvation stalls the
        // uploads). Spread streams over several connections and retry
        // transient failures instead of wedging the action.
        connections_per_endpoint: 8,
        retry: {
          max_retries: 5,
          delay: 0.3,
          jitter: 0.5,
        },
      },
    },
    {
      name: "GRPC_AC_STORE",
      grpc: {
        instance_name: "$INSTANCE_NAME",
        endpoints: [
          { address: "grpc://$MASTER_HOST:$CAS_PORT" },
        ],
        store_type: "ac",
        rpc_timeout_s: 120,
        connections_per_endpoint: 2,
        retry: {
          max_retries: 5,
          delay: 0.3,
          jitter: 0.5,
        },
      },
    },
    {
      // Local hot cache in front of the master CAS. The fast side must be a
      // filesystem store on the same volume as work_directory (hardlinks).
      name: "WORKER_FAST_SLOW_STORE",
      fast_slow: {
        fast: {
          filesystem: {
            content_path: "$WORKER_DATA_DIR/cas/content",
            temp_path: "$WORKER_DATA_DIR/cas/tmp",
            eviction_policy: {
              max_bytes: "${FAST_CACHE_GB}gb",
            },
          },
        },
        fast_direction: "get",
        slow: {
          ref_store: { name: "GRPC_CAS_STORE" },
        },
      },
    },
  ],
  workers: [
    {
      local: {
        name: "$WORKER_NAME",
        worker_api_endpoint: {
          uri: "grpc://$MASTER_HOST:$WORKER_PORT",
        },
        cas_fast_slow_store: "WORKER_FAST_SLOW_STORE",
        // Real concurrency governor: unlike platform cpu_count slots (which
        // release before cleanup), an inflight slot is held until the
        // action's ~14k-file workdir is deleted — backpressure that stops
        // unlink debt from piling up on the APFS volume.
        max_inflight_tasks: ${MAX_INFLIGHT:-10},
        $( [ "${DIR_CACHE_ENABLE:-1}" = "1" ] && cat <<DCEOF
        directory_cache: {
          max_entries: ${DIR_CACHE_ENTRIES:-1200},
          max_size_bytes: "${DIR_CACHE_GB:-8}gb",
          experimental_subtree_caching: ${DIR_CACHE_SUBTREES:-true},
          max_concurrent_fetches: 512,
        },
DCEOF
        )
        upload_action_result: {
          ac_store: "GRPC_AC_STORE",
        },
        work_directory: "$WORKER_DATA_DIR/work",
        platform_properties: {
          // Capacity: WORKER_SLOTS concurrent actions (each action asks for 1).
          cpu_count: {
            values: ["$WORKER_SLOTS"],
          },
          OSFamily: {
            values: ["Mac"],
          },
          "container-image": {
            values: [""],
          },
          "label:action_default": {
            values: ["1"],
          },
          "label:action_large": {
            values: ["1"],
          },
        },
      },
    },
  ],
  servers: [],
  global: {
    max_open_files: 24576,
  },
}
EOF
  log "Wrote $out"
}

# ---------------------------------------------------------------------------
# Process management (nohup + pidfile; use 'service install' for launchd)
# ---------------------------------------------------------------------------
proc_running() { # $1=role
  local pf; pf="$(pid_file_for "$1")"
  [ -f "$pf" ] || return 1
  local pid; pid="$(cat "$pf")"
  [ -n "$pid" ] || return 1
  # Guard against PID reuse after a crash/reboot: the pid must be nativelink.
  ps -p "$pid" -o command= 2>/dev/null | grep -qF "$NATIVELINK_BIN"
}

launchd_loaded() { # $1=role — plist loaded (running or not)
  launchctl list 2>/dev/null | awk -v l="$LAUNCHD_LABEL_PREFIX-$1" '$3==l' | grep -q .
}

launchd_pid() { # $1=role — prints pid if actually running under launchd
  launchctl list 2>/dev/null | awk -v l="$LAUNCHD_LABEL_PREFIX-$1" '$3==l && $1!="-" {print $1}'
}

start_role() {
  local r="$1"
  local conf; conf="$(config_path_for "$r")"
  [ -f "$conf" ] || die "Missing $conf — run './manage.sh config'"
  [ -x "$NATIVELINK_BIN" ] || die "nativelink binary missing — run './manage.sh install'"
  if launchd_loaded "$r"; then
    die "$r is managed by launchd — use './manage.sh service uninstall' before managing it manually"
  fi
  if proc_running "$r"; then
    log "$r already running (pid $(cat "$(pid_file_for "$r")"))"
    return 0
  fi
  local lf; lf="$(log_file_for "$r")"
  if [ -f "$lf" ] && [ "$(stat -f%z "$lf" 2>/dev/null || echo 0)" -gt 104857600 ]; then
    mv "$lf" "$lf.old"   # keep one ~100MB generation
  fi
  # nativelink holds many files open (global.max_open_files=24576).
  ulimit -n 65536 2>/dev/null || warn "could not raise open-file limit (currently $(ulimit -n))"
  log "Starting $r..."
  nohup "$NATIVELINK_BIN" "$conf" >> "$(log_file_for "$r")" 2>&1 &
  echo $! > "$(pid_file_for "$r")"
  sleep 1
  if proc_running "$r"; then
    log "$r started (pid $(cat "$(pid_file_for "$r")")), log: $(log_file_for "$r")"
  else
    rm -f "$(pid_file_for "$r")"
    echo "--- last log lines ---" >&2
    tail -n 20 "$(log_file_for "$r")" >&2 || true
    die "$r failed to start"
  fi
}

stop_role() {
  local r="$1"
  if launchd_loaded "$r"; then
    warn "$r is managed by launchd (KeepAlive would restart it) — use './manage.sh service uninstall'"
    return 0
  fi
  if proc_running "$r"; then
    local pid; pid="$(cat "$(pid_file_for "$r")")"
    log "Stopping $r (pid $pid)..."
    kill "$pid" 2>/dev/null || true
    local i=0
    while [ "$i" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
      sleep 1; i=$((i + 1))
    done
    kill -0 "$pid" 2>/dev/null && { warn "$r did not exit; sending SIGKILL"; kill -9 "$pid" 2>/dev/null || true; }
  else
    log "$r not running"
  fi
  rm -f "$(pid_file_for "$r")"
}

cmd_start()   { require_env; for r in $(node_roles); do start_role "$r"; done; }
cmd_stop()    { require_env; for r in $(node_roles_reversed); do stop_role "$r"; done; }
cmd_restart() { cmd_stop; cmd_start; }

cmd_status() {
  require_env
  local lpid
  for r in $(node_roles); do
    lpid="$(launchd_pid "$r")"
    if proc_running "$r"; then
      echo "$r: RUNNING (pid $(cat "$(pid_file_for "$r")"))"
    elif [ -n "$lpid" ]; then
      echo "$r: RUNNING (launchd, pid $lpid)"
    elif launchd_loaded "$r"; then
      echo "$r: LOADED by launchd but NOT running — check './manage.sh logs $r'"
    else
      echo "$r: STOPPED"
    fi
  done
  if has_role master; then
    echo "--- listening ports ---"
    lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk -v c=":$CAS_PORT" -v w=":$WORKER_PORT" \
      'NR==1 || index($0,c) || index($0,w)' | grep -v '^COMMAND$' || echo "(none)"
  fi
}

cmd_logs() {
  require_env
  local target="" follow=""
  for a in "$@"; do
    case "$a" in
      -f) follow="-f" ;;
      master|worker) target="$a" ;;
      *) die "logs: unknown argument '$a'" ;;
    esac
  done
  [ -n "$target" ] || target="$(node_roles | awk '{print $1}')"
  local lf; lf="$(log_file_for "$target")"
  [ -f "$lf" ] || die "No log file at $lf"
  if [ -n "$follow" ]; then tail -n 100 -f "$lf"; else tail -n 200 "$lf"; fi
}

# ---------------------------------------------------------------------------
# launchd service
# ---------------------------------------------------------------------------
plist_path_for() { echo "$HOME/Library/LaunchAgents/$LAUNCHD_LABEL_PREFIX-$1.plist"; }

write_plist() {
  local r="$1"
  local conf; conf="$(config_path_for "$r")"
  local plist; plist="$(plist_path_for "$r")"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LAUNCHD_LABEL_PREFIX-$r</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NATIVELINK_BIN</string>
    <string>$conf</string>
  </array>
  <key>WorkingDirectory</key><string>$SCRIPT_DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$(log_file_for "$r")</string>
  <key>StandardErrorPath</key><string>$(log_file_for "$r")</string>
  <key>SoftResourceLimits</key>
  <dict><key>NumberOfFiles</key><integer>65536</integer></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
  echo "$plist"
}

cmd_service() {
  require_env
  local action="${1:-}"
  local r plist
  case "$action" in
    install)
      binary_works || die "nativelink binary missing — run './manage.sh install' first"
      for r in $(node_roles); do
        [ -f "$(config_path_for "$r")" ] || die "missing $(config_path_for "$r") — run './manage.sh config'"
      done
      # Hand any running instances over to launchd.
      for r in $(node_roles_reversed); do
        launchctl unload "$(plist_path_for "$r")" 2>/dev/null || true
        stop_role "$r"
      done
      for r in $(node_roles); do
        plist="$(write_plist "$r")"
        launchctl load "$plist"
        log "Installed + loaded launchd service: $plist"
      done
      log "NOTE: LaunchAgents start at login. For a headless Mac Mini, enable"
      log "auto-login (System Settings > Users & Groups) so the node comes up on boot."
      ;;
    uninstall)
      for r in $(node_roles_reversed); do
        plist="$(plist_path_for "$r")"
        if [ -f "$plist" ]; then
          launchctl unload "$plist" 2>/dev/null || true
          rm -f "$plist"
          log "Removed $plist"
        fi
      done
      ;;
    status)
      launchctl list 2>/dev/null | grep "$LAUNCHD_LABEL_PREFIX" || echo "no $LAUNCHD_LABEL_PREFIX services loaded"
      ;;
    *) die "service requires: install | uninstall | status" ;;
  esac
}

# ---------------------------------------------------------------------------
# doctor
# ---------------------------------------------------------------------------
check_tcp() { # $1=host $2=port
  nc -z -G 3 "$1" "$2" >/dev/null 2>&1
}

cmd_doctor() {
  require_env
  local fails=0

  echo "== binary =="
  if binary_works; then
    ok "nativelink runs: $("$NATIVELINK_BIN" --version 2>/dev/null | head -1)"
  else
    bad "nativelink binary missing or broken — run './manage.sh install'"; fails=$((fails+1))
  fi

  echo "== configs =="
  local r
  for r in $(node_roles); do
    if [ -f "$(config_path_for "$r")" ]; then ok "$(config_path_for "$r")"; else bad "missing $(config_path_for "$r") — run './manage.sh config'"; fails=$((fails+1)); fi
  done

  echo "== processes =="
  local lpid
  for r in $(node_roles); do
    lpid="$(launchd_pid "$r")"
    if proc_running "$r"; then
      ok "$r running (pid $(cat "$(pid_file_for "$r")"))"
    elif [ -n "$lpid" ]; then
      ok "$r running under launchd (pid $lpid)"
    elif launchd_loaded "$r"; then
      bad "$r launchd service loaded but NOT running — check './manage.sh logs $r'"; fails=$((fails+1))
    else
      bad "$r not running — './manage.sh start' or './manage.sh service install'"; fails=$((fails+1))
    fi
  done

  if has_role master; then
    local probe="127.0.0.1"
    if [ "$BIND_IP" != "0.0.0.0" ]; then probe="$BIND_IP"; fi
    echo "== master endpoints ($probe) =="
    if check_tcp "$probe" "$CAS_PORT"; then ok "client gRPC port $CAS_PORT accepting connections"; else bad "port $CAS_PORT not accepting connections"; fails=$((fails+1)); fi
    if check_tcp "$probe" "$WORKER_PORT"; then ok "worker API port $WORKER_PORT accepting connections"; else bad "port $WORKER_PORT not accepting connections"; fails=$((fails+1)); fi
    local health
    if health="$(curl -sf --max-time 3 "http://$probe:$WORKER_PORT/status")"; then
      ok "health endpoint: ${health:-ok}"
    else
      bad "health endpoint http://$probe:$WORKER_PORT/status not responding"; fails=$((fails+1))
    fi
    echo "   (reachability from other machines: check firewall prompts / System Settings > Network > Firewall)"
  fi

  if [ "$ROLE" = "worker" ]; then
    echo "== master reachability ($MASTER_HOST) =="
    if check_tcp "$MASTER_HOST" "$CAS_PORT"; then ok "CAS $MASTER_HOST:$CAS_PORT reachable"; else bad "cannot reach $MASTER_HOST:$CAS_PORT (master down? firewall?)"; fails=$((fails+1)); fi
    if check_tcp "$MASTER_HOST" "$WORKER_PORT"; then ok "worker API $MASTER_HOST:$WORKER_PORT reachable"; else bad "cannot reach $MASTER_HOST:$WORKER_PORT"; fails=$((fails+1)); fi
  fi

  if has_role worker; then
    echo "== worker log (last errors, if any) =="
    if [ -f "$(log_file_for worker)" ]; then
      local errs
      errs="$(tail -n 2000 "$(log_file_for worker)" | grep -i -E "error|failed|panic" | tail -3 || true)"
      if [ -n "$errs" ]; then
        printf '%s\n' "$errs" | sed 's/^/    /'
      else
        ok "no errors in worker log"
      fi
    fi
  fi

  echo "== system limits =="
  local soft
  soft="$(launchctl limit maxfiles 2>/dev/null | awk '{print $2}')"
  if [ "${soft:-0}" = "unlimited" ] || [ "${soft:-0}" -ge 24576 ] 2>/dev/null; then
    ok "launchd maxfiles soft limit: $soft"
  else
    warn "launchd maxfiles soft limit is $soft (< 24576). The script raises ulimit per-process,"
    warn "but if starts fail, run: sudo launchctl limit maxfiles 65536 200000  (then reboot)"
  fi

  echo "== disk =="
  df -h "$SCRIPT_DIR" | tail -1 | awk '{printf "  data volume: %s free of %s (%s used)\n", $4, $2, $5}'

  echo ""
  if [ "$fails" -eq 0 ]; then log "All checks passed."; else die "$fails check(s) failed."; fi
}

# ---------------------------------------------------------------------------
# Chromium / Siso client integration
#
# Verified against Chromium main (2026-07) and siso source:
#   - siso reads SISO_REAPI_ADDRESS / SISO_REAPI_INSTANCE from
#     build/config/siso/.sisoenv (merged into env by depot_tools/siso.py).
#   - The address must be plain host:port (NO grpc:// scheme — siso prefixes
#     dns:/// itself; a scheme would be passed to grpc-go verbatim and fail).
#   - RBE_service_no_security=true makes -reapi_insecure default to true:
#     plaintext gRPC, no auth. LAN/closed-network use only.
#   - depot_tools errors if build/config/siso/backend_config/backend.star is
#     missing; it supplies the "default"/"large" platform properties.
#   - On a mac host, clang steps take platform properties from
#     buildtools/reclient_cfgs/chromium-browser-clang/rewrapper_mac.cfg
#     (platform= and remote_wrapper= lines are both REQUIRED by
#     clang_mac.star; an empty remote_wrapper= is valid and means no wrapper).
#     The file must exist BEFORE `gn gen` when use_remoteexec=true.
#   - clang_mac.star derives the "large" platform by replacing
#     label:action_default with label:action_large=1.
# ---------------------------------------------------------------------------
write_client_file() { # $1=path, content on stdin
  local path="$1" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  mkdir -p "$(dirname "$path")"
  if [ -f "$path" ] && ! cmp -s "$tmp" "$path"; then
    if [ -f "$path.rbe-ftw.bak" ]; then
      warn "keeping existing backup $path.rbe-ftw.bak (not overwriting it)"
    else
      cp "$path" "$path.rbe-ftw.bak"
      warn "backed up existing $path -> $path.rbe-ftw.bak"
    fi
  fi
  mv "$tmp" "$path"
  log "Wrote $path"
}

siso_client_files() { # $1=chromium_src $2=master_addr $3=instance
  local src="$1" addr="$2" instance="$3"

  # Cap in-flight remote steps at ~3x cluster slots. Siso's default Remote
  # limit is in the thousands; against a small NativeLink cluster that dumps
  # every ready step into the scheduler queue at once. Actions then sit
  # QUEUED past siso's per-call deadline -> mass DeadlineExceeded retries and
  # eventually fallback-on-Aborted local compiles that starve the client CPU.
  local slots="${WORKER_SLOTS:-16}"
  write_client_file "$src/build/config/siso/.sisoenv" <<EOF
SISO_REAPI_ADDRESS=$addr
SISO_REAPI_INSTANCE=$instance
RBE_service_no_security=true
SISO_LIMITS=remote=$((slots * 3))
EOF

  write_client_file "$src/build/config/siso/backend_config/backend.star" <<'EOF'
# Generated by rbe-ftw manage.sh — NativeLink Mac Mini cluster backend.
# Platform properties for non-clang remote actions ("default"/"large").
# Clang compile steps use rewrapper_mac.cfg instead (see clang_mac.star).
load("@builtin//struct.star", "module")

def __platform_properties(ctx):
    return {
        "default": {
            "OSFamily": "Mac",
            "label:action_default": "1",
            "cpu_count": "1",
        },
        "large": {
            "OSFamily": "Mac",
            "label:action_large": "1",
            "cpu_count": "1",
        },
    }

backend = module(
    "backend",
    platform_properties = __platform_properties,
)
EOF

  write_client_file "$src/buildtools/reclient_cfgs/chromium-browser-clang/rewrapper_mac.cfg" <<'EOF'
platform=OSFamily=Mac,label:action_default=1,cpu_count=1
remote_wrapper=
EOF
}

print_siso_instructions() { # $1=master_addr $2=instance
  local addr="$1" instance="$2"
  cat <<EOF

Chromium setup for this cluster
===============================

1. Files (written by 'siso-setup', all gitignored by Chromium):
     build/config/siso/.sisoenv
         SISO_REAPI_ADDRESS=$addr
         SISO_REAPI_INSTANCE=$instance
         RBE_service_no_security=true
     build/config/siso/backend_config/backend.star     (platform properties)
     buildtools/reclient_cfgs/chromium-browser-clang/rewrapper_mac.cfg
                                                       (mac clang platform props)

2. gn args (rewrapper_mac.cfg must exist before 'gn gen'):
     use_remoteexec = true
     use_siso = true

3. Build:
     autoninja -C out/Default chrome
   Size remote parallelism to the cluster, e.g. with 2 workers x 16 slots:
     autoninja -C out/Default -j 80 chrome

Notes
-----
- Address is plain host:port (no grpc:// scheme) — siso requires this form.
- Traffic is plaintext gRPC with no auth: closed/trusted networks only.
- 'gclient sync' / 'gclient runhooks' REWRITES .sisoenv and backend.star
  (Chromium's configure_siso hook) — re-run './manage.sh siso-setup'
  afterwards, or make it permanent via gclient custom_vars:
  reapi_address, reapi_instance, reapi_backend_config_path.
- Only clang compile steps go remote by default. Mojo/python actions stay
  local (they'd need the 'googlechrome' siso config, tuned for Linux workers).
- Mac caveat: remote clang needs the macOS SDK *inside* the src checkout
  (e.g. build/mac_files/xcode_binaries). With use_system_xcode and the SDK in
  /Applications, siso cannot ship SDK headers to workers and compiles fall
  back to local. Verify with a small target first:
     siso ninja -C out/Default base   # then check out/Default/siso_metrics
- If everything falls back to local, run './manage.sh doctor' on the master
  and compare platform properties: scheduler + worker + rewrapper_mac.cfg
  must agree (this script keeps them in sync).
EOF
}

# Resolve the master address + instance for client commands.
# Sets SISO_ADDR and SISO_INSTANCE. Args: master_override instance_override port_override
resolve_siso_target() {
  local master_override="$1" instance_override="$2" port_override="$3"
  local instance="main" cas_port=50051
  if [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    instance="$INSTANCE_NAME"; cas_port="$CAS_PORT"
  elif [ -z "$instance_override" ] || { [ -z "$port_override" ] && [ "${master_override##*:}" = "$master_override" ]; }; then
    warn "no cluster config on this machine — assuming instance '$instance'/port $cas_port unless overridden (--instance/--cas-port)"
  fi
  if [ -n "$instance_override" ]; then instance="$instance_override"; fi
  if [ -n "$port_override" ]; then cas_port="$port_override"; fi
  local host; host="$(master_address_for_clients "$master_override")"
  [ -n "$host" ] || die "Cannot determine master address — pass --master <host>"
  case "$host" in
    *:*) SISO_ADDR="$host" ;;              # caller already supplied host:port
    *)   SISO_ADDR="$host:$cas_port" ;;
  esac
  SISO_INSTANCE="$instance"
}

# Create + mount an APFS RAM disk for worker scratch (workdir, fast CAS,
# directory cache). File create/delete there is ~free, which matters because
# each Chromium action materializes and then deletes a ~14k-file input tree —
# on the SSD that syscall storm dominates the worker (mostly sys time) and
# caps throughput far below CPU saturation. Lost on reboot: re-run this, then
# './manage.sh start'.
cmd_ramdisk() {
  [ -f "$ENV_FILE" ] && . "$ENV_FILE"
  local size_gb="${RAMDISK_GB:-24}" vol="/Volumes/NLRam"
  if mount | grep -q " $vol "; then
    log "RAM disk already mounted at $vol"
    return 0
  fi
  local sectors=$((size_gb * 2097152)) dev
  dev=$(hdiutil attach -nomount ram://$sectors) || die "hdiutil attach failed"
  dev=$(printf '%s' "$dev" | tr -d ' 	')
  diskutil eraseDisk APFS NLRam "$dev" >/dev/null || die "diskutil eraseDisk $dev failed"
  log "RAM disk mounted at $vol (${size_gb}GB, $dev). Contents vanish on reboot/unmount."
}

cmd_siso_setup() {
  local src="" master_override="" instance_override="" port_override=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --master)   master_override="$2"; shift 2 ;;
      --instance) instance_override="$2"; shift 2 ;;
      --cas-port) port_override="$2"; shift 2 ;;
      *) src="$1"; shift ;;
    esac
  done
  [ -n "$src" ] || die "usage: ./manage.sh siso-setup <chromium-src-dir> [--master <host[:port]>] [--instance <name>] [--cas-port <port>]"
  [ -d "$src/build/config/siso" ] || die "$src does not look like a Chromium src checkout (no build/config/siso)"

  resolve_siso_target "$master_override" "$instance_override" "$port_override"
  siso_client_files "$src" "$SISO_ADDR" "$SISO_INSTANCE"
  print_siso_instructions "$SISO_ADDR" "$SISO_INSTANCE"
}

cmd_siso_env() {
  local master_override="" instance_override="" port_override=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --master)   master_override="$2"; shift 2 ;;
      --instance) instance_override="$2"; shift 2 ;;
      --cas-port) port_override="$2"; shift 2 ;;
      *) die "siso-env: unknown argument '$1'" ;;
    esac
  done
  resolve_siso_target "$master_override" "$instance_override" "$port_override"
  print_siso_instructions "$SISO_ADDR" "$SISO_INSTANCE"
}

cmd_env() {
  require_env
  cat "$ENV_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    install)    cmd_install "$@" ;;
    init)       cmd_init "$@" ;;
    config)     cmd_config "$@" ;;
    start)      cmd_start "$@" ;;
    stop)       cmd_stop "$@" ;;
    restart)    cmd_restart "$@" ;;
    status)     cmd_status "$@" ;;
    logs)       cmd_logs "$@" ;;
    service)    cmd_service "$@" ;;
    doctor)     cmd_doctor "$@" ;;
    siso-setup) cmd_siso_setup "$@" ;;
    ramdisk) cmd_ramdisk "$@" ;;
    siso-env)   cmd_siso_env "$@" ;;
    env)        cmd_env "$@" ;;
    -h|--help|help|"") usage ;;
    *) usage; die "Unknown command: $cmd" ;;
  esac
}
main "$@"
