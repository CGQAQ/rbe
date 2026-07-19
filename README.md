# rbe-ftw

Turn Mac Minis into a [NativeLink](https://github.com/TraceMachina/nativelink)
Remote Build Execution cluster for building Chromium with
[Siso](https://chromium.googlesource.com/build/+/refs/heads/main/siso/).

```
                 ┌─────────────────────────────┐
   Siso clients  │  master (Mac Mini #1)       │      ┌────────────────────┐
  ───────────────▶  CAS + Action Cache : 50051 ◀──────│ worker (Mac Mini #2)│
   host:50051    │  scheduler                  │ gRPC │  N concurrent      │
                 │  worker API        : 50061  ◀──────│  compile actions   │
                 └─────────────────────────────┘      └────────────────────┘
```

- **master** — one NativeLink process serving the CAS (content-addressable
  store), action cache, and scheduler. Clients and workers all connect to it.
- **worker** — one NativeLink process that registers with the master and
  executes actions directly on the host (no containers), with a local
  disk cache in front of the master CAS.
- A machine can be both (`init both`) — useful to use the master's cores too.

Everything is managed by [manage.sh](manage.sh). Runtime state lives in
gitignored directories: `.nativelink/` (binary, configs, logs),
`.nativelink-server/` (CAS/AC data), `.nativelink-worker/` (cache + workdir).

## Setup

Clone this repo onto each Mac Mini.

**Mac Mini #1 (master):**

```sh
./manage.sh install          # prebuilt NativeLink v1.6.2; falls back to cargo build
./manage.sh init master      # or: init both   (also run a worker on this machine)
./manage.sh start
./manage.sh doctor
```

**Mac Mini #2+ (workers):**

```sh
./manage.sh install
./manage.sh init worker --master 192.168.1.10   # the master's LAN IP
./manage.sh start
./manage.sh doctor           # verifies it can reach the master
```

If the master was initialized with a non-default `--instance` or ports, pass
the same values to `init worker` — the instance name is baked into the
worker's gRPC stores and must match what the master serves.

**Run at boot** (instead of `start`):

```sh
./manage.sh service install  # launchd LaunchAgent with keep-alive
```

LaunchAgents start at login — enable auto-login on headless Mac Minis
(System Settings → Users & Groups). macOS may show a firewall prompt for
`nativelink` on the master the first time; allow incoming connections.

Useful knobs (edit `.nativelink/cluster.env`, then `./manage.sh config` and
`restart`): `CAS_SIZE_GB` (default 200), `WORKER_SLOTS` (default = CPU count),
`FAST_CACHE_GB` (worker-local cache, default 50).

## Pointing a Chromium checkout at the cluster

On the machine where you build Chromium:

```sh
./manage.sh siso-setup /path/to/chromium/src --master 192.168.1.10
```

This writes three files into the checkout (all gitignored by Chromium;
existing files are backed up as `*.rbe-ftw.bak`):

| File | Purpose |
|---|---|
| `build/config/siso/.sisoenv` | `SISO_REAPI_ADDRESS`, `SISO_REAPI_INSTANCE=main`, `RBE_service_no_security=true` |
| `build/config/siso/backend_config/backend.star` | platform properties for non-clang remote actions (required by depot_tools) |
| `buildtools/reclient_cfgs/chromium-browser-clang/rewrapper_mac.cfg` | platform properties for clang compile steps on a mac host |

Then:

```sh
gn gen out/Default --args='use_remoteexec=true use_siso=true'
autoninja -C out/Default -j 80 chrome     # ~2-3x total worker slots
```

`rewrapper_mac.cfg` must exist **before** `gn gen` — `siso-setup` takes care
of that as long as you run it first.

### How the pieces line up

Siso sends platform properties with each remote action; the NativeLink
scheduler hard-rejects unknown property keys and only dispatches to workers
whose advertised properties satisfy the request. This repo keeps all three
sides in sync:

| | value |
|---|---|
| Siso sends (per action) | `OSFamily=Mac`, `label:action_default=1` (or `label:action_large=1`), `cpu_count=1` |
| Worker advertises | `OSFamily=Mac`, both labels, `cpu_count=<slots>` |
| Scheduler declares | `cpu_count: minimum`, `OSFamily`/labels/`container-image`: `priority`, `InputRootAbsolutePath: ignore` |

`cpu_count` is a *consumable* property: each action subtracts 1 from the
worker's advertised capacity, so a worker runs at most `WORKER_SLOTS` actions
at once.

Because both the build host and the workers are arm64 macs, the remote
worker natively runs the exact clang/tool binaries the build uploads — no
containers or cross toolchains involved.

## Caveats

- **No TLS, no auth.** Siso runs with `-reapi_insecure`; anyone on the
  network can submit actions that execute as your user on the workers, and
  workers run actions with no sandboxing. Trusted/closed networks only.
- **macOS SDK must be inside the checkout for remote clang.** Chromium's siso
  config can only upload SDK inputs that live under the source tree
  (`build/mac_files/xcode_binaries/...`, normally a Googler-only CIPD
  package). With `use_system_xcode` and the SDK in `/Applications`, remote
  compiles can't gather SDK headers and will fall back to local. Options:
  place a hermetic Xcode under `build/mac_files/xcode_binaries`, or test
  whether your build's actions need SDK headers at all. **Smoke-test with a
  small target first** (`autoninja -C out/Default base`) and check
  `out/Default/siso_metrics.json` for remote vs local counts before relying
  on the cluster for full builds.
- **Only clang compile steps go remote by default.** Link steps need Siso's
  `remote-link` config (`siso ninja -config remote-link`); mojo/python codegen
  is gated behind the `googlechrome` config, which assumes Google's Linux
  containers, and stays local here.
- **`gclient sync` rewrites the client files.** Chromium's `configure_siso`
  hook regenerates `.sisoenv`/`backend.star` on every sync — re-run
  `./manage.sh siso-setup` afterwards, or set the `reapi_address`,
  `reapi_instance`, and `reapi_backend_config_path` gclient custom_vars to
  make the configuration permanent.
- **File limits:** the script raises `ulimit -n` (and the launchd service
  sets 65536). If starts fail on a stock machine, run
  `sudo launchctl limit maxfiles 65536 200000` and reboot.

## Commands

```
./manage.sh install [--from-source]        # install NativeLink into .nativelink/bin
./manage.sh init master|worker|both [opts] # configure this node (see --help)
./manage.sh config                         # regenerate configs from cluster.env
./manage.sh start|stop|restart|status      # process management
./manage.sh logs [master|worker] [-f]      # tail logs
./manage.sh service install|uninstall      # launchd keep-alive service
./manage.sh doctor                         # health checks
./manage.sh siso-setup <src> [--master h]  # wire a Chromium checkout to the cluster
./manage.sh siso-env [--master h]          # print the Chromium setup instructions
```

Verified end-to-end against NativeLink v1.6.2 with a REAPI client sending
Siso's exact platform properties: remote execution, CAS round-trip, and
remote action-cache hits (through the completeness-checking store, so CAS
eviction can't cause broken cache hits).
