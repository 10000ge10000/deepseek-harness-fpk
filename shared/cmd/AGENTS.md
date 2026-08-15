# shared/cmd — fnOS App Lifecycle Framework

Core daemon management and install/upgrade/uninstall hooks. All apps source these scripts; app-specific `cmd/service-setup` customizes per app.

## STRUCTURE

```
cmd/
├── common              # 352 lines — THE core: daemon ops, install lifecycle, utilities
├── main                # Entry point: start|stop|status dispatcher
├── installer           # Sources common + service-setup, loads wizard vars
├── install_init        # Delegates to installer → install_init()
├── install_callback    # Delegates to installer → install_callback()
├── uninstall_init      # Delegates to installer → uninstall_init()
├── uninstall_callback  # Delegates to installer → uninstall_callback()
├── upgrade_init        # Delegates to installer → upgrade_init()
└── upgrade_callback    # Delegates to installer → upgrade_callback()
```

## WHERE TO LOOK

| Task | File | Key functions |
|------|------|---------------|
| Daemon start/stop/PID management | `common` | `start_daemon()`, `stop_daemon()`, `daemon_status()`, `wait_for_status()` |
| Install lifecycle | `common` | `install_init()`, `install_callback()` |
| Upgrade lifecycle | `common` | `upgrade_init()`, `upgrade_callback()` |
| Uninstall + data cleanup | `common` | `uninstall_init()`, `uninstall_callback()` — checks `wizard_delete_data` |
| Logging | `common` | `install_log()`, `log_step()`, `call_func()` |
| Wizard variable persistence | `common` | `save_wizard_variables()`, `load_variables_from_file()` |
| File sync (var/ overlay) | `common` | `sync_var_folder()` — rsync with --ignore-existing |
| Docker check | `common` | `check_docker()` — reads `docker-compose.yaml` container_name |
| Service dispatch | `main` | Case switch: `start)` `stop)` `status)` |

## CONVENTIONS

- **Source chain**: `main` → `common` → `service-setup` (app-specific). The `installer` script does the same for install/upgrade hooks.
- **Hook functions**: Apps override by defining `service_preinst()`, `service_postinst()`, `service_preupgrade()`, etc. in their `service-setup`. Defaults are no-ops (echo only).
- **`call_func()`**: Calls function only if it exists (type check). Logs begin/end. Pass `install_log` as $2 for timestamped logging.
- **PID management**: Writes PIDs to `PID_FILE` (one per line). `stop_daemon()` sends SIGTERM then SIGKILL after timeout.
- **SVC_WAIT_TIMEOUT**: Default 15s (override in service-setup).
- **SVC_BACKGROUND=y**: All 3 current apps run backgrounded.

## ANTI-PATTERNS

- **Don't bypass `call_func()`** — it handles existence checks and logging.
- **Don't write to `LOG_FILE` directly** from hooks — use `install_log` for timestamped output.
- **Don't assume shared `installer`** — qBittorrent overrides it entirely with its own version that adds `postupgrade()` logic.
- **`{init,callback}` wrapper scripts** just source `installer` and call the matching function via `$(basename "$0")`. Don't add logic to them.
