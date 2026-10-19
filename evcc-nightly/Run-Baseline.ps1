#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [ValidateSet('BaselineTest', 'GenerateBaseline')][string]$RunMode,
    [string]$BlfFiles,
    [switch]$DebugMode,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'baseline.config.json' }
$originalLocation = Get-Location
$exitCode = 2
$runDir = $null
$transcribing = $false
$lock = $null
$failure = $null
$cfg = $null
$script:EvccDebug = $false
$script:EvccPhase = 'Read configuration'
$envNames = @('EVCC_REPO_ROOT','EVCC_VARIANT','EVCC_RUN_MODE','EVCC_BASELINE_DIR',
    'EVCC_MAT_DIR','EVCC_ARTIFACT_DIR','EVCC_STATUS_FILE','EVCC_KEEP_FAILED_MAT',
    'EVCC_SETTINGS_FILE','EVCC_DEBUG')
$savedEnv = @{}
foreach ($name in $envNames) { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    . (Join-Path $PSScriptRoot 'Common.ps1')
    $configFile = (Resolve-Path -LiteralPath $ConfigPath).Path
    $cfg = Read-EvccSettings $configFile
    if ($PSBoundParameters.ContainsKey('RunMode')) { $cfg.RunMode = $RunMode }
    if ($PSBoundParameters.ContainsKey('BlfFiles')) { $cfg.BlfFiles = $BlfFiles }
    if ($PSBoundParameters.ContainsKey('DebugMode')) { $cfg.Debug.Enabled = [bool]$DebugMode }
    $script:EvccDebug = $cfg.Debug.Enabled -eq $true
    # Start logging before dependency/path validation so a broken setup leaves evidence.
    $runDir = Join-Path $cfg.ResultsRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    Start-Transcript -LiteralPath (Join-Path $runDir 'run.log') | Out-Null
    $transcribing = $true
    Write-Host "[CONFIG] $configFile"
    Write-Host "[RESULTS] $runDir"
    $script:EvccPhase = 'Validate configuration'
    Test-EvccSettings $cfg
    $configDirectory = Split-Path -Parent $configFile
    Write-Host "[START] Mode=$($cfg.RunMode) Variant=$($cfg.VehicleVariant) Repo=$($cfg.RepoRoot) Debug=$script:EvccDebug"
    if ($script:EvccDebug) {
        $cfg | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $runDir 'effective-config.json') -Encoding UTF8
        [pscustomobject]@{ PowerShell = $PSVersionTable.PSVersion.ToString(); HostExecutable = (Get-Process -Id $PID).Path;
            User = [Security.Principal.WindowsIdentity]::GetCurrent().Name; InitialDirectory = $originalLocation.Path;
            ConfigFile = $configFile; ProcessId = $PID } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $runDir 'debug.json') -Encoding UTF8
        Write-EvccDebug "PowerShell=$($PSVersionTable.PSVersion) User=$([Security.Principal.WindowsIdentity]::GetCurrent().Name) CWD=$originalLocation"
        Write-EvccDebug ($cfg | ConvertTo-Json -Depth 15)
    }
    $script:EvccPhase = 'Verify executable and project paths'
    $cfg.MatlabExe = Resolve-EvccExecutable $cfg.MatlabExe $configDirectory
    $cfg.PythonExe = Resolve-EvccExecutable $cfg.PythonExe $configDirectory
    Write-EvccDebug "Resolved MatlabExe=$($cfg.MatlabExe) PythonExe=$($cfg.PythonExe)"
    if ($script:EvccDebug) {
        $cfg | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $runDir 'effective-config.json') -Encoding UTF8
    }
    if (-not (Test-Path -LiteralPath $cfg.RepoRoot -PathType Container)) { throw "Test checkout missing: $($cfg.RepoRoot)" }
    if ($cfg.RequireGitRepository) {
        if (-not (Test-Path -LiteralPath (Join-Path $cfg.RepoRoot '.git'))) { throw "Git repository/worktree missing: $($cfg.RepoRoot)" }
        $cfg.GitExe = Resolve-EvccExecutable $cfg.GitExe $configDirectory
    }
    foreach ($name in @('ProjectFile','PythonTool','MappingConfig')) {
        Write-EvccDebug "Paths.$name=$($cfg.Paths.$name)"
        if (-not (Test-Path -LiteralPath $cfg.Paths.$name -PathType Leaf)) { throw "Paths.$name file missing: $($cfg.Paths.$name)" }
    }
    foreach ($name in @('InterfaceDir','DbcDir')) {
        if (-not (Test-Path -LiteralPath $cfg.Paths.$name -PathType Container)) { throw "Paths.$name folder missing: $($cfg.Paths.$name)" }
    }
    $script:EvccPhase = 'Acquire checkout lock'
    $lock = [IO.File]::Open((Join-Path $cfg.RepoRoot '.evcc-nightly.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $moduleList = '[' + (($cfg.PythonModules | ForEach-Object { "'$_'" }) -join ',') + ']'
    $pythonCode = "import importlib,sys; [importlib.import_module(n) for n in $moduleList]; print('[PYTHON]',sys.executable,sys.version)"
    Invoke-EvccTool $cfg.PythonExe @('-c', $pythonCode) 'Check Python dependencies'
    if ($cfg.RequireGitRepository) {
        Invoke-EvccTool $cfg.GitExe @('-C',$cfg.RepoRoot,'rev-parse','HEAD') 'Read source revision'
        if ($script:EvccDebug) { Invoke-EvccTool $cfg.GitExe @('-C',$cfg.RepoRoot,'status','--short','--untracked-files=no') 'Read tracked source status' }
    }
    . (Join-Path $PSScriptRoot 'Invoke-Workflow.ps1')
    $script:EvccPhase = 'Resolve scenario inputs'
    $plan = @(Get-EvccInputPlan $cfg)
    if ($plan.Count -eq 0) { throw 'No vehicle variants selected' }
    if ($CheckOnly) {
        Write-Host '[CHECK] Configuration, paths, Python imports, lock, interface Excel, BLFs and baseline files verified. MATLAB was not launched.'
        $exitCode = 0
    } else {
        New-Item -ItemType Directory -Force -Path $cfg.Paths.MatDir | Out-Null
        Set-Location -LiteralPath $cfg.RepoRoot
        $settingsFile = Join-Path $runDir 'effective-config.json'
        # Both MATLAB sessions read exactly the same resolved configuration.
        $cfg | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $settingsFile -Encoding UTF8
        $env:EVCC_SETTINGS_FILE = $settingsFile
        $env:EVCC_DEBUG = [string]$cfg.Debug.Enabled
        $env:EVCC_REPO_ROOT = $cfg.RepoRoot
        $env:EVCC_ARTIFACT_DIR = $runDir
        Invoke-EvccMatlab $cfg (Join-Path $PSScriptRoot 'export_schema.m') 'Export BSW schema'
        foreach ($name in $cfg.SchemaFiles) {
            if (-not (Test-Path -LiteralPath (Join-Path $cfg.Paths.SchemaDir $name) -PathType Leaf)) { throw "BSW schema missing: $name" }
        }
        $stats = Invoke-EvccWorkflow $cfg $plan $runDir
        $stats | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runDir 'scenarios.json') -Encoding UTF8
        $exitCode = if ($stats.Failures -gt 0) { 1 } else { 0 }
    }
} catch {
    $failure = [pscustomobject]@{ Phase = $script:EvccPhase; Message = $_.Exception.Message;
        Position = $_.InvocationInfo.PositionMessage; Stack = $_.ScriptStackTrace }
    # Invalid JSON, an unreadable config or an unwritable results root still gets a log.
    if (-not $transcribing) {
        $runDir = Join-Path ([IO.Path]::GetTempPath()) ('EVCCNightly-startup-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $runDir | Out-Null
        Start-Transcript -LiteralPath (Join-Path $runDir 'run.log') | Out-Null
        $transcribing = $true
        Write-Host "[RESULTS] $runDir"
    }
    Write-Host "[ERROR] Phase=$($failure.Phase): $($failure.Message)" -ForegroundColor Red
    Write-Host $failure.Position
    Write-Host $failure.Stack
    $failure | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runDir 'error.json') -Encoding UTF8
    $exitCode = 2
} finally {
    try {
        if ($runDir -and (Test-Path -LiteralPath $runDir -PathType Container)) {
            [pscustomobject]@{ FinishedAt = (Get-Date -Format o); ConfigFile = $ConfigPath;
                Mode = $(if ($cfg) { $cfg.RunMode } else { $RunMode }); Phase = $script:EvccPhase;
                Debug = $script:EvccDebug; CheckOnly = [bool]$CheckOnly; ExitCode = $exitCode; Error = $failure } |
                ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runDir 'result.json') -Encoding UTF8
        }
        if ($transcribing) { Stop-Transcript | Out-Null }
    } finally {
        Set-Location -LiteralPath $originalLocation.Path
        foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], 'Process') }
        if ($lock) { $lock.Dispose() }
    }
}
exit $exitCode
