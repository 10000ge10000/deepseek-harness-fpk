# shared/cmd — fnOS App Lifecycle Framework

Core daemon management and install/upgrade/uninstall hooks. All apps source these scripts; app-specific `cmd/service-setup` customizes per app.

## STRUCTURE

```
cmd/
├── common              # ~430 lines — THE core: daemon ops, install lifecycle, utilities
├── main                # Entry point: start|stop|status|log dispatcher
├── installer           # Sources common + service-setup, loads wizard vars
├── install_init        # Delegates to installer → install_init()
├── install_callback    # Delegates to installer → install_callback()
├── uninstall_init      # Delegates to installer → uninstall_init()
├── uninstall_callback  # Delegates to installer → uninstall_callback()
├── upgrade_init        # Delegates to installer → upgrade_init()
├── upgrade_callback    # Delegates to installer → upgrade_callback()
├── config_init         # Delegates to installer → config_init()
└── config_callback     # Delegates to installer → config_callback()
```

## WHERE TO LOOK

| Task | File | Key functions |
|------|------|---------------|
| Daemon start/stop/PID management | `common` | `start_daemon()`, `stop_daemon()`, `daemon_status()`, `wait_for_status()` |
| Install lifecycle | `common` | `install_init()`, `install_callback()` — aborts via `error_exit` when `validate_preinst` fails |
| Upgrade lifecycle | `common` | `upgrade_init()`, `upgrade_callback()` — aborts via `error_exit` when `validate_preupgrade` fails |
| Uninstall + data cleanup | `common` | `uninstall_init()`, `uninstall_callback()` — checks `wizard_delete_data` (guards `TRIM_PKGHOME` before delete) |
| Config lifecycle | `common` | `config_init()`, `config_callback()` |
| Logging | `common` | `install_log()`, `log_step()`, `call_func()` |
| Wizard variable persistence | `common` | `save_wizard_variables()`, `load_variables_from_file()` |
| File sync (var/ overlay) | `common` | `sync_var_folder()` — rsync with --ignore-existing |
| Docker check | `common` | `check_docker()` — reads `docker-compose.yaml` container_name (docker/ or app/) |
| Service dispatch | `main` | Case switch: `start)` `stop)` `status)` `log)` |

## CONVENTIONS

- **Source chain**: `main` → `common` → `service-setup` (app-specific). The `installer` script does the same for install/upgrade hooks. Note: `apps/deepseek-harness/fnos/cmd/main` overrides the shared `main` in the final package with a self-contained version (own PID/port recovery).
- **Hook functions**: Apps override by defining `service_preinst()`, `service_postinst()`, `service_preupgrade()`, etc. in their `service-setup`. Defaults are no-ops (echo only).
- **`call_func()`**: Calls function only if it exists (`declare -F` check). Logs begin/end with the real exit code (`PIPESTATUS`-aware). Pass `install_log` as $2 for timestamped logging.
- **PID management**: Writes PIDs to `PID_FILE` (one per line). `stop_daemon()` sends SIGTERM then SIGKILL after timeout.
- **SVC_WAIT_TIMEOUT**: Default 15s in `common` (the `wait_for_status` fallback is 20s; override in service-setup if needed).
- **SVC_BACKGROUND=y**: deepseek-harness runs backgrounded via runner.js.

## ANTI-PATTERNS

- **Don't bypass `call_func()`** — it handles existence checks, logging, and exit-code propagation.
- **Don't write to `LOG_FILE` directly** from hooks — use `install_log` for timestamped output.
- **Don't assume shared `installer`** — apps may override it entirely with their own version.
- **`{init,callback}` wrapper scripts** just source `installer` and call the matching function via `$(basename "$0")`. Don't add logic to them.
- **Don't use bare filename patterns in `pgrep -f`/kill loops** — always path-qualify (e.g. `${APP_DIR}/bin/runner\.js`) to avoid killing unrelated processes.
