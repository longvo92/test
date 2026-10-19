#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [ValidateSet('BaselineTest', 'GenerateBaseline')][string]$RunMode = 'BaselineTest',
    [string]$BlfFiles = 'all',
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'baseline.config.json' }
$exitCode = 2
$lock = $null
$transcribing = $false
$runDir = $null
$originalLocation = Get-Location
$envNames = @('EVCC_REPO_ROOT','EVCC_VARIANT','EVCC_RUN_MODE','EVCC_BASELINE_DIR',
    'EVCC_MAT_DIR','EVCC_ARTIFACT_DIR','EVCC_STATUS_FILE','EVCC_KEEP_FAILED_MAT')
$savedEnv = @{}
foreach ($name in $envNames) { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    foreach ($name in @('RepoRoot','MatlabExe','PythonExe','VehicleVariant','ResultsRoot','KeepFailedScenarioMat')) {
        if ($null -eq $cfg.PSObject.Properties[$name]) { throw "Missing config property: $name" }
    }
    foreach ($name in @('RepoRoot','MatlabExe','PythonExe','ResultsRoot')) {
        if ([string]::IsNullOrWhiteSpace($cfg.$name) -or -not [IO.Path]::IsPathRooted($cfg.$name)) {
            throw "Config $name must be an absolute path"
        }
    }
    if ($cfg.VehicleVariant -notin @('VF68NP','VF9WILD','All')) { throw 'Unsupported VehicleVariant' }
    if ($cfg.KeepFailedScenarioMat -isnot [bool]) { throw 'KeepFailedScenarioMat must be a JSON boolean' }
    $repo = [IO.Path]::GetFullPath($cfg.RepoRoot).TrimEnd('\','/')
    $results = [IO.Path]::GetFullPath($cfg.ResultsRoot).TrimEnd('\','/')
    if ($repo -eq $results -or $results.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ResultsRoot must be outside the test checkout'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) { throw "Test checkout missing: $repo" }
    foreach ($file in @($cfg.MatlabExe, $cfg.PythonExe,
        (Join-Path $repo '01_ModelBaseDesign/EVCC_Architecture.prj'),
        (Join-Path $repo '01_ModelBaseDesign/06_Tools/TestAction/blf2mat/blf_to_signal_editor_cli.py'),
        (Join-Path $repo '01_ModelBaseDesign/06_Tools/TestAction/blf2mat/signal_mapping.yaml'))) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required file missing: $file" }
    }
    # The lock belongs to the checkout so different tasks/results paths cannot overlap.
    $lock = [IO.File]::Open((Join-Path $repo '.evcc-nightly.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    New-Item -ItemType Directory -Force -Path $results | Out-Null
    $runDir = Join-Path $results ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $runDir | Out-Null
    Start-Transcript -LiteralPath (Join-Path $runDir 'run.log') | Out-Null
    $transcribing = $true
    Write-Host "[START] Mode=$RunMode Variant=$($cfg.VehicleVariant) Repo=$repo"
    Write-Host "[RESULTS] $runDir"
    & $cfg.PythonExe -c "import sys, can, cantools, pandas, openpyxl, scipy, yaml; print('[PYTHON]', sys.executable)" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Python dependencies missing' }
    & git -C $repo rev-parse HEAD | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read checkout revision' }
    Write-Host '[SOURCE] Using current checkout; no fetch, checkout, reset, clean, commit or push.'
    $resource = '01_ModelBaseDesign/04_SWE5_SoftwareIntegration/simulation_resource'
    $matDir = Join-Path $repo "$resource/mat"
    # Shared MAT cleanup must never traverse a junction/symlink outside the checkout.
    $cursor = $matDir
    while ($cursor.Length -ge $repo.Length) {
        if ((Test-Path -LiteralPath $cursor) -and
            ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Reparse point in test workspace: $cursor"
        }
        if ($cursor -eq $repo) { break }
        $cursor = Split-Path -Parent $cursor
    }
    if ($CheckOnly) {
        Write-Host '[CHECK] Paths, interpreter dependencies and checkout lock verified. MATLAB was not launched.'
        $exitCode = 0
    } else {
        New-Item -ItemType Directory -Force -Path $matDir | Out-Null
        Set-Location -LiteralPath $repo
        $env:EVCC_REPO_ROOT = $repo
        $code = "repoRoot = string(getenv('EVCC_REPO_ROOT')); openProject(fullfile(repoRoot, '01_ModelBaseDesign/EVCC_Architecture.prj')); cd(repoRoot); listBSW_io;"
        & $cfg.MatlabExe -batch $code | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'listBSW_io failed' }
        foreach ($name in @('BSW_IN.txt','BSW_OUT.txt')) {
            if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $repo $resource) $name) -PathType Leaf)) {
                throw "BSW schema missing: $name"
            }
        }
        . (Join-Path $PSScriptRoot 'Invoke-Workflow.ps1')
        $stats = Invoke-EvccWorkflow -Repo $repo -Mode $RunMode -Vehicle $cfg.VehicleVariant `
            -Selection $BlfFiles -Matlab $cfg.MatlabExe -Python $cfg.PythonExe `
            -ArtRoot $runDir -KeepFailedMat $cfg.KeepFailedScenarioMat
        $exitCode = if ($stats.Failures -gt 0) { 1 } else { 0 }
        $stats | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runDir 'scenarios.json') -Encoding UTF8
    }
} catch {
    [Console]::Error.WriteLine('[ERROR] ' + $_.Exception.Message)
    $exitCode = 2
} finally {
    if ($runDir) {
        [pscustomobject]@{ FinishedAt = (Get-Date -Format o); Mode = $RunMode;
            CheckOnly = [bool]$CheckOnly; ExitCode = $exitCode } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runDir 'result.json') -Encoding UTF8
    }
    if ($transcribing) { Stop-Transcript | Out-Null }
    Set-Location -LiteralPath $originalLocation.Path
    foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], 'Process') }
    if ($lock) { $lock.Dispose() }
}
exit $exitCode
