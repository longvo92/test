# EVCC nightly baseline

Windows PowerShell 5.1 runner extracted from the supplied EVCC Azure baseline YAML. Uses the existing project and converter; does not fetch, reset/clean, commit or push source. A schedule always runs `BaselineTest` against the current checkout.

## Configure and run

Edit **`baseline.config.json`**. It contains the machine paths, execution mode/BLF selection, project/tool paths, variants and Excel prefixes, MATLAB helper names/model/tolerance/legacy baselines, debug settings, and nightly schedule. Relative repository/results/executable paths use the JSON file's directory; relative `Paths` entries use `RepoRoot`. Executables may also be names on PATH (absolute paths are more predictable in Task Scheduler).

`config.defaults.json` supplies compatibility defaults for older six-property config files. Only edit your `baseline.config.json`; partial nested overrides inherit defaults, arrays and the `Variants` map replace defaults. `All` processes the configured variants in JSON order.

Set `RepoRoot`, `MatlabExe`, `PythonExe`, `ResultsRoot` and `VehicleVariant` for your PC. The sample MATLAB path is **R2024b**; point it at the version actually installed. Use a dedicated test checkout; Python needs the modules listed in `PythonModules` and any additional converter dependencies. Set `RequireGitRepository` to `false` only for a source export without `.git` (no Git SHA/status is recorded). MATLAB needs its existing project/toolbox/license setup.

```powershell
# Preflight: no MATLAB launch and no simulation MAT cleanup.
.\Run-Now.cmd -CheckOnly -DebugMode

# Run with diagnostic logging.
.\Run-Now.cmd -DebugMode
```

Without CLI overrides, `RunMode`, `BlfFiles` and `Debug.Enabled` come from JSON. Existing `-RunMode`, `-BlfFiles`, `-At`, `-TaskName` and `-Interactive` options remain supported. Double-clicking `Run-Now.cmd` pauses on failure so the error stays visible; calls with arguments and scheduled runs do not pause.

## Debugging a failed start

Set `Debug.Enabled` to `true`, or pass `-DebugMode`. The runner prints the config file, results folder, resolved paths, selected Excel/BLFs, allowlisted EVCC variables, commands, elapsed time and process exit codes. Debug output records PowerShell version, account and initial directory; Git status covers tracked changes when Git is required. It does not dump the entire process environment.

MATLAB prints its version, helper resolution (`which`) and the names in **`Debug.MatlabVariables`** at major phases. Add project variable names there, for example `fault`, `totalFault` or a calibration variable. Names must be simple identifiers, not expressions. Missing variables are reported as unavailable. Numeric/logical/text values up to `MaxValueElements` are displayed; larger values and other types show class/size. No debug workspace MAT dump is created. `PrintMatlabProducts` controls the installed-product listing during schema export.

Each run has a unique folder under `ResultsRoot`:

| File | Contents |
| --- | --- |
| `run.log` | Transcript, tools' stdout/stderr, MATLAB phase/errors |
| `result.json` | Exit code, current phase, finish time and error details |
| `error.json` | On error: message, PowerShell source position and stack |
| `debug.json` | With debug enabled: host/account/start-directory diagnostics |
| `effective-config.json` | Resolved settings for debug/preflight, and all full runs |
| `scenarios.json` | Aggregate counts after a completed workflow |

Logging starts before dependency/path checks. If JSON cannot be read/parsed or `ResultsRoot` is unwritable, diagnostics go under `%TEMP%\EVCCNightly-startup-<id>`; the path is printed. To diagnose a failure, inspect `error.json` and the last section of `run.log` in the printed `[RESULTS]` folder. Debug does not repair a missing tool, license or project dependency.

Preflight checks config types, tools, Python imports, checkout locking, required paths, numeric Excel version selection, BLF files and baseline references (including legacy names). It does not prove MATLAB/license/model execution. Native stderr is logged; a nonzero process exit determines failure.

## Nightly schedule

Set `Schedule.At` (default `22:00`, Windows local time), task name, timeout, logon type, wake/power settings and overlap policy in JSON. Inspect the proposed task first, without task-service calls or registration:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-NightlyTask.ps1 -Preview
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-NightlyTask.ps1
```

The installer preflights `BaselineTest` before registration. `Schedule.LogonType: "Password"` asks for the Windows account password (not the Hello PIN) to run while logged off. Credentials are passed to Windows Task Scheduler, never written into JSON/logs. `Interactive` works while locked but requires the configured account to stay logged in. Empty `UserId` means the current account; another account must have access to the tools, source, results and license. If Windows denies registration/batch logon, use the appropriate elevated account or ask IT.

Use `-Replace` to update an installed task after changing schedule settings. Execution/debug settings are read from JSON on each run. Scheduled execution explicitly selects `BaselineTest` even if manual `RunMode` is `GenerateBaseline`. Default settings request wake from sleep, run missed starts when available, allow battery operation, ignore overlapping starts and impose a four-hour limit. A powered-off PC cannot wake this way; Windows/firmware wake timers must be enabled. A forced timeout can leave incomplete logs/no final JSON and may leave child processes; inspect Task Scheduler history and MATLAB processes before retrying.

Exit codes / Task Scheduler `LastTaskResult`: **0** pass (or successful preflight), **1** baseline mismatch, **2** config/execution error. The checkout lock coordinates copies of this runner, not the Azure agent or manual MATLAB sessions. Do not share the dedicated checkout with them.

## Working data and baseline generation

The original MATLAB sequence and tolerance default (`0.5`) are preserved. Configurable helper names must be MATLAB identifiers; schema/merge helpers can be scripts and run in the same script workspace. The Python converter's own `signal_mapping.yaml` stays in its original format; `Paths.MappingConfig` selects it. If project helpers assume fixed MAT locations, keep `Paths.MatDir` consistent with those helpers.

Before each variant, previous `*_input.mat`, `*_output.mat` and the configured merged scenario file are removed from the shared MAT work directory. Keep valuable MAT files elsewhere. The wrapper never replaces baseline references. `KeepFailedScenarioMat: false` avoids copying multi-GB failure outputs every night; set it to `true` to retain them under `FailedScenarioMAT/<variant>`. Otherwise working outputs survive only until the next variant/run cleans them. There is no automatic results retention/deletion.

For manual generation set JSON `RunMode`/`BlfFiles`, or use:

```powershell
.\Run-Now.cmd -RunMode GenerateBaseline -BlfFiles 'AC-Basic_Charging.blf'
```

Only generation selects a BLF subset, as in the YAML. Generated references go under `GeneratedBaseline/<variant>` for review, not over existing references.

## Verification

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Smoke.ps1` for synthetic wrapper tests, including old configs, JSON overrides, debug/errors, native stderr and exit codes. Tests create fixtures in TEMP and preview the scheduler without registering a task. They do not verify proprietary converter/model behavior. MATLAB Code Analyzer can check `export_schema.m` and `run_variant.m` separately; a complete manual regression and one real scheduled run must still be verified on the target PC.