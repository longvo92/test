# EVCC nightly baseline trial

Local Windows PowerShell 5.1 runner adapted from `Pasted text(7).txt` in the ChatGPT conversation **Đánh giá rủi ro pipeline**. The Azure pipeline itself is unchanged. No scheduler task is installed until you run the installer.

## Configure and run

1. Keep this folder in a permanent location. Edit `baseline.config.json`: set an existing **dedicated test checkout**, absolute MATLAB/Python executable paths, variant (`VF68NP`, `VF9WILD`, `All`) and a results directory outside the checkout. Python needs `python-can`, `cantools`, `pandas`, `openpyxl`, `scipy`, `PyYAML`, plus any dependencies required by the converter itself. The sample paths must be replaced if they differ on your PC.
2. Run `Run-Now.cmd -CheckOnly` for basic file paths, Python imports and checkout-lock checks. It does not launch MATLAB or prove simulation/license availability. Then run `Run-Now.cmd` once to verify a complete regression with your project and MATLAB license.
3. From PowerShell in this folder, install the nightly task:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-NightlyTask.ps1 -At 22:00
```

The default installer asks for your current Windows account **password**, not a Windows Hello PIN, so the task can run while logged off. Task Scheduler manages the credential; it is not saved in these files. If registration is denied by Windows policy, run the installer in an elevated PowerShell under the same account or ask your IT administrator about batch-logon rights. MATLAB, its toolboxes/license and Python must work under that account without interactive prompts.

For an account without a usable password, use `-Interactive`: this can run with the screen locked, but the account must remain logged in. To inspect the proposed schedule without registering it or asking for a password, use `-Preview`. Use `-Replace` to update an existing task of the same name.

The schedule uses Windows local time, requests wake from sleep, runs missed starts when available, ignores overlapping scheduled starts and has a four-hour execution limit, matching the YAML. A powered-off computer cannot wake this way. Windows power/firmware policy must allow wake timers. Runs are allowed on battery. The checkout lock also prevents two copies of this runner using the same checkout; it does not coordinate with the Azure agent or manually launched MATLAB. Do not share the nightly checkout with either.

```powershell
# Trigger the installed task now, then inspect its last result.
Start-ScheduledTask -TaskName 'EVCC Baseline Nightly'
Get-ScheduledTaskInfo -TaskName 'EVCC Baseline Nightly'

# Remove the schedule only; checkout and results are retained.
Unregister-ScheduledTask -TaskName 'EVCC Baseline Nightly' -Confirm:$false
```

## Behavior and results

The runner uses the checkout's **current revision**. It does not fetch updates, switch branches, reset/clean Git, commit or push. Update this dedicated checkout yourself before a run if you want to test newer source. Git SHA is recorded in the log; uncommitted changes are also used, so the SHA alone does not fully identify a modified workspace. The existing MATLAB tools may modify model/variant files as in the original pipeline.

Execution preserves the original sequence and interfaces: `listBSW_io`, highest numeric version of the variant-specific interface Excel, BLF converter, `merge_mat_scenarios`, `set_wdmode_variant`, `run_all_scenarios`, and `compare_baseline(..., 'TimeTolerance', 0.5)`. Variants run sequentially in separate MATLAB processes. Existing legacy baseline filename fallbacks are preserved. Only `GenerateBaseline` accepts a BLF subset, as in the YAML.

The shared simulation `mat` directory is working data: each variant removes previous `*_input.mat`, `*_output.mat` and `EVCC_Intergration_Scenarios.mat`. Use a dedicated checkout and keep valuable MAT files elsewhere. Baseline reference files are never replaced by this wrapper.

Each invocation that reaches log setup gets a unique directory under `ResultsRoot`, with `run.log`, `result.json`, and on a completed workflow `scenarios.json` plus per-variant status files. MATLAB execution errors include their phase in the log. Exit codes / Task Scheduler `LastTaskResult`: `0` = pass (or successful `-CheckOnly`), `1` = baseline mismatch, `2` = setup/execution error. This makes mismatches visible as a nonzero result locally; the original Azure pipeline reports them as a warning. A forced scheduler timeout may leave an incomplete log and no final result JSON; check Task Scheduler history too.

`KeepFailedScenarioMat` defaults to `false` to avoid copying multi-GB MAT files every night. Logs still list failed scenarios; simulation MATs remain in the shared working folder until the next variant/run cleans them. Set it to `true` to retain failed output MATs under `FailedScenarioMAT/<variant>` for each run. Logs/results have **no automatic retention/deletion**; monitor disk space and remove old run folders yourself.

Manual baseline generation is available, but is never selected by the scheduled task:

```powershell
.\Run-Now.cmd -RunMode GenerateBaseline -BlfFiles 'AC-Basic_Charging.blf'
```

Generated references go into the run's `GeneratedBaseline/<variant>` folder for manual review/copy, not over the existing baseline.

This is a trial extracted from the supplied YAML. Local wrapper checks do not verify the proprietary MATLAB tools, BLF conversion semantics, model behavior, license availability or unattended execution on your PC. A full manual run followed by one scheduled run is required there.
