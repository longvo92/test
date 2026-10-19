#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')][string]$At,
    [string]$TaskName,
    [switch]$Interactive,
    [switch]$Replace,
    [switch]$Preview
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'baseline.config.json' }
. (Join-Path $PSScriptRoot 'Common.ps1')
$config = (Resolve-Path -LiteralPath $ConfigPath).Path
$cfg = Read-EvccSettings $config
if ($PSBoundParameters.ContainsKey('At')) { $cfg.Schedule.At = $At }
if ($PSBoundParameters.ContainsKey('TaskName')) { $cfg.Schedule.TaskName = $TaskName }
if ($PSBoundParameters.ContainsKey('Interactive')) {
    $cfg.Schedule.LogonType = if ($Interactive) { 'Interactive' } else { 'Password' }
}
Test-EvccSettings $cfg
$schedule = $cfg.Schedule
$runner = Join-Path $PSScriptRoot 'Run-Baseline.ps1'
$hostExe = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
# A schedule always tests baselines, even when manual generation is configured.
$arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -RunMode BaselineTest' -f $runner, $config
$user = $schedule.UserId
if ([string]::IsNullOrWhiteSpace($user)) { $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name }
if ($Preview) {
    [pscustomobject]@{ TaskName = $schedule.TaskName; DailyAt = $schedule.At; User = $user;
        LogonType = $schedule.LogonType; Execute = $hostExe; Arguments = $arguments;
        Settings = $schedule; Debug = $cfg.Debug.Enabled } | ConvertTo-Json -Depth 5
    return
}
# Validate the runner first. Preview never imports or calls task-service APIs.
& $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -ConfigPath $config -RunMode BaselineTest -CheckOnly
if ($LASTEXITCODE -ne 0) { throw 'Preflight failed. Inspect the [RESULTS] directory printed above.' }
$action = New-ScheduledTaskAction -Execute $hostExe -Argument $arguments -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.Add([timespan]::ParseExact($schedule.At, 'hh\:mm', $null)))
$settingsArgs = @{
    MultipleInstances = $schedule.MultipleInstances; StartWhenAvailable = $schedule.StartWhenAvailable;
    WakeToRun = $schedule.WakeToRun; AllowStartIfOnBatteries = $schedule.AllowStartIfOnBatteries;
    DontStopIfGoingOnBatteries = $schedule.DontStopIfGoingOnBatteries;
    ExecutionTimeLimit = (New-TimeSpan -Seconds ($schedule.TimeoutHours * 3600))
}
$settings = New-ScheduledTaskSettingsSet @settingsArgs
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType $schedule.LogonType -RunLevel $schedule.RunLevel
$task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'EVCC baseline regression. Exit 0=pass, 1=mismatch, 2=execution/configuration error. See ResultsRoot.'
if ((Get-ScheduledTask -TaskName $schedule.TaskName -TaskPath '\' -ErrorAction SilentlyContinue) -and -not $Replace) {
    throw "Task already exists: $($schedule.TaskName). Use -Replace to update it."
}
$register = @{ TaskName = $schedule.TaskName; TaskPath = '\'; InputObject = $task; Force = [bool]$Replace }
$credential = $null
if ($schedule.LogonType -eq 'Password') {
    $credential = Get-Credential -UserName $user -Message 'Windows account password for nightly execution while logged off (not the Windows Hello PIN).'
    if (-not $credential) { throw 'Task registration cancelled' }
    if ($credential.UserName -ine $user) { throw "Use the configured task account: $user" }
    $register.User = $user
    $register.Password = $credential.GetNetworkCredential().Password
}
try {
    Register-ScheduledTask @register | Out-Null
} finally {
    $register.Remove('Password')
    $credential = $null
}
Get-ScheduledTaskInfo -TaskName $schedule.TaskName -TaskPath '\' | Select-Object TaskName, NextRunTime, LastTaskResult
Write-Host "[INSTALLED] Daily at $($schedule.At) (Windows local time). Mode=BaselineTest; LogonType=$($schedule.LogonType)"
