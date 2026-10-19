#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')][string]$At = '22:00',
    [string]$TaskName = 'EVCC Baseline Nightly',
    [switch]$Interactive,
    [switch]$Replace,
    [switch]$Preview
)
$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'baseline.config.json' }
$config = (Resolve-Path -LiteralPath $ConfigPath).Path
$runner = Join-Path $PSScriptRoot 'Run-Baseline.ps1'
$hostExe = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $runner, $config
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$logonType = if ($Interactive) { 'Interactive' } else { 'Password' }
if ($Preview) {
    [pscustomobject]@{ TaskName = $TaskName; DailyAt = $At; User = $user; LogonType = $logonType;
        Execute = $hostExe; Arguments = $arguments; MultipleInstances = 'IgnoreNew';
        WakeToRun = $true; StartWhenAvailable = $true; TimeoutHours = 4 } | Format-List
    return
}
$action = New-ScheduledTaskAction -Execute $hostExe -Argument $arguments -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.Add([timespan]::ParseExact($At, 'hh\:mm', $null)))
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -WakeToRun `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 4)
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType $logonType -RunLevel Limited
$task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description 'EVCC baseline regression. Exit 0=pass, 1=baseline mismatch, 2=execution/configuration error. See ResultsRoot.'
if ((Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue) -and -not $Replace) {
    throw "Task already exists: $TaskName. Use -Replace to update it."
}
# Check configuration/dependencies in a child process before changing Task Scheduler.
& $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -ConfigPath $config -CheckOnly
if ($LASTEXITCODE -ne 0) { throw 'Preflight failed. Fix baseline.config.json and run Run-Now.cmd -CheckOnly.' }
$register = @{ TaskName = $TaskName; TaskPath = '\'; InputObject = $task; Force = [bool]$Replace }
if (-not $Interactive) {
    $credential = Get-Credential -UserName $user -Message 'Windows account password for nightly execution while logged off (not the Windows Hello PIN).'
    if (-not $credential) { throw 'Task registration cancelled' }
    if ($credential.UserName -ine $user) { throw "Use the current account: $user" }
    # The password is passed only to Task Scheduler. It is never written into the package or logs.
    $register.User = $user
    $register.Password = $credential.GetNetworkCredential().Password
}
try {
    Register-ScheduledTask @register | Out-Null
} finally {
    $register.Remove('Password')
    $credential = $null
}
Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath '\' | Select-Object TaskName, NextRunTime, LastTaskResult
Write-Host "[INSTALLED] Daily at $At (Windows local time). Mode=BaselineTest; LogonType=$logonType"
