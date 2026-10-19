#requires -Version 5.1
# Synthetic tools only. This test never runs MATLAB or installs a scheduled task.
$ErrorActionPreference = 'Stop'
$package = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('evcc debug fixture ' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $fixture 'repo'
$results = Join-Path $fixture 'results'
New-Item -ItemType Directory -Force -Path $repo | Out-Null
& git -C $repo init --quiet
& git -C $repo -c user.name=Smoke -c user.email=smoke@example.invalid commit --allow-empty -m smoke --quiet
if ($LASTEXITCODE) { throw 'Cannot create synthetic repo' }
$paths = @('01_ModelBaseDesign/EVCC_Architecture.prj',
    '01_ModelBaseDesign/06_Tools/TestAction/blf2mat/blf_to_signal_editor_cli.py',
    '01_ModelBaseDesign/06_Tools/TestAction/blf2mat/signal_mapping.yaml',
    '01_ModelBaseDesign/01_SWE2_SoftwareArchitecture/Interface/interface_APSW_Model_VF68NP_0.3.9.xlsx',
    '01_ModelBaseDesign/01_SWE2_SoftwareArchitecture/Interface/interface_APSW_Model_VF68NP_0.3.10.xlsx',
    '01_ModelBaseDesign/01_SWE2_SoftwareArchitecture/Interface/interface_APSW_Model_VF9_WILD_0.3.10.xlsx')
foreach ($variant in @('VF68NP','VF9WILD')) {
    foreach ($scenario in @('first','second','third')) {
        $paths += "01_ModelBaseDesign/04_SWE5_SoftwareIntegration/simulation_resource/blf/$variant/$scenario.blf"
        $paths += "01_ModelBaseDesign/04_SWE5_SoftwareIntegration/Baseline/$variant/${scenario}_baseline.mat"
    }
}
foreach ($relative in $paths) {
    $path = Join-Path $repo $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    Set-Content -LiteralPath $path -Value fixture
}
New-Item -ItemType Directory -Force -Path (Join-Path $repo '01_ModelBaseDesign/Common/dbc') | Out-Null
$python = Join-Path $fixture 'fake-python.ps1'
$matlab = Join-Path $fixture 'fake-matlab.ps1'
@'
if ($args[0] -eq '-c') { Write-Host '[MOCK] Python imports'; exit 0 }
if ($env:EVCC_TEST_CONVERTER_FAIL -eq '1') { exit 7 }
$blf = $args[[array]::IndexOf($args,'--blf') + 1]
$output = $args[[array]::IndexOf($args,'--output') + 1]
$files = if (Test-Path -LiteralPath $blf -PathType Leaf) { @(Get-Item -LiteralPath $blf) } else { @(Get-ChildItem -LiteralPath $blf -Filter '*.blf') }
foreach ($file in $files) { Set-Content -LiteralPath (Join-Path $output ($file.BaseName + '_input.mat')) -Value fixture }
exit 0
'@ | Set-Content -LiteralPath $python
@'
$settings = Get-Content -LiteralPath $env:EVCC_SETTINGS_FILE -Raw | ConvertFrom-Json
if ($env:EVCC_STATUS_FILE) {
    if ($env:EVCC_TEST_MATLAB_FAIL -eq '1') { exit 9 }
    if ($env:EVCC_TEST_NO_STATUS -ne '1') { Set-Content -LiteralPath $env:EVCC_STATUS_FILE -Value $env:EVCC_TEST_STATUS }
} else {
    foreach ($name in $settings.SchemaFiles) { Set-Content -LiteralPath (Join-Path $settings.Paths.SchemaDir $name) -Value fixture }
}
exit 0
'@ | Set-Content -LiteralPath $matlab
$config = Join-Path $fixture 'test.config.json'
# The old six-property JSON must remain usable with new defaults.
$settings = [pscustomobject]@{ RepoRoot=$repo; ResultsRoot=$results; PythonExe=$python;
    MatlabExe=$matlab; VehicleVariant='All'; KeepFailedScenarioMat=$false }
function Save-Config { $settings | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $config }
Save-Config
$hostExe = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
function Test-Case([string]$Name,[int]$Expected,[string[]]$Extra=@()) {
    $output = & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'Run-Baseline.ps1') -ConfigPath $config @Extra 2>&1
    $code = $LASTEXITCODE
    if ($code -ne $Expected) { $output | Out-Host; throw "$Name returned $code instead of $Expected" }
    $script:latest = Get-ChildItem -LiteralPath $results -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-Host "[TEST PASS] $Name -> $Expected"
}
$env:EVCC_TEST_STATUS='0,3'
Test-Case 'Old JSON and expanded preflight' 0 @('-CheckOnly')
Test-Case 'Two-variant pass' 0
$stats = Get-Content -LiteralPath (Join-Path $latest.FullName 'scenarios.json') -Raw | ConvertFrom-Json
if ($stats.Scenarios -ne 6 -or $stats.Failures -ne 0) { throw 'Incorrect aggregate summary' }
$plainLog = Get-Content -LiteralPath (Join-Path $latest.FullName 'run.log') -Raw
if ($plainLog -notmatch 'VF68NP_0.3.10.xlsx' -or $plainLog -match '\[DEBUG\]') { throw 'Excel resolution or normal logging failed' }
$settings | Add-Member Debug ([pscustomobject]@{ Enabled=$true; MatlabVariables=@('variant','fault') })
Save-Config
Test-Case 'Debug JSON controls logging' 0 @('-CheckOnly')
foreach ($file in @('debug.json','effective-config.json','run.log','result.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $latest.FullName $file))) { throw "Missing debug artifact: $file" }
}
$effective = Get-Content -LiteralPath (Join-Path $latest.FullName 'effective-config.json') -Raw | ConvertFrom-Json
if (-not $effective.Debug.PrintMatlabProducts -or $effective.Debug.MatlabVariables.Count -ne 2) { throw 'Nested defaults/array override failed' }
if ((Get-Content -LiteralPath (Join-Path $latest.FullName 'run.log') -Raw) -notmatch '\[DEBUG\] Command:') { throw 'Missing debug commands' }
$env:EVCC_TEST_STATUS='1,3'
Test-Case 'Mismatch remains exit 1' 1
$env:EVCC_TEST_MATLAB_FAIL='1'
Test-Case 'MATLAB failure remains exit 2' 2
$errorInfo = Get-Content -LiteralPath (Join-Path $latest.FullName 'error.json') -Raw | ConvertFrom-Json
if ($errorInfo.Phase -notmatch 'Merge, simulate' -or -not $errorInfo.Stack -or $errorInfo.Message -notmatch 'exit code 9') { throw 'Missing error diagnostics' }
$env:EVCC_TEST_MATLAB_FAIL='0'
$env:EVCC_TEST_NO_STATUS='1'
Test-Case 'Missing status rejected' 2
$env:EVCC_TEST_NO_STATUS='0'
$env:EVCC_TEST_CONVERTER_FAIL='1'
Test-Case 'Converter failure remains exit 2' 2
$env:EVCC_TEST_CONVERTER_FAIL='0'
$held = [IO.File]::Open((Join-Path $repo '.evcc-nightly.lock'),'OpenOrCreate','ReadWrite','None')
try { Test-Case 'Overlap rejected' 2 @('-CheckOnly') } finally { $held.Dispose() }
Test-Case 'Lock released after failure' 0 @('-CheckOnly')
$missing = Join-Path $repo '01_ModelBaseDesign/04_SWE5_SoftwareIntegration/Baseline/VF68NP/first_baseline.mat'
Move-Item -LiteralPath $missing -Destination ($missing + '.saved')
Test-Case 'Missing baseline detected without MATLAB' 2 @('-CheckOnly')
Move-Item -LiteralPath ($missing + '.saved') -Destination $missing
$settings | Add-Member Schedule ([pscustomobject]@{ At='23:45'; TaskName='EVCC fixture preview only'; LogonType='Interactive'; WakeToRun=$false; TimeoutHours=2 })
Save-Config
$preview = & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'Install-NightlyTask.ps1') -ConfigPath $config -Preview | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $preview.DailyAt -ne '23:45' -or $preview.Settings.WakeToRun -or $preview.LogonType -ne 'Interactive' -or $preview.Arguments -notmatch '-RunMode BaselineTest') {
    throw 'Schedule JSON preview failed'
}
Write-Host '[TEST PASS] Scheduler reads JSON; preview only, no task APIs'
$settings.MatlabExe = Join-Path $fixture 'missing.exe'
Save-Config
Test-Case 'Missing executable creates early error log' 2 @('-CheckOnly')
$settings.MatlabExe=$matlab
$settings | Add-Member RunMode GenerateBaseline
$settings | Add-Member BlfFiles 'first.blf,second.blf'
Save-Config
$env:EVCC_TEST_STATUS='0,2'
Test-Case 'RunMode and BLF subset from JSON' 0
$stats = Get-Content -LiteralPath (Join-Path $latest.FullName 'scenarios.json') -Raw | ConvertFrom-Json
if ($stats.Mode -ne 'GenerateBaseline' -or $stats.Scenarios -ne 4) { throw 'JSON execution selection failed' }
$settings.Debug.Enabled=$false
Save-Config
Test-Case 'Debug CLI override remains supported' 0 @('-DebugMode','-CheckOnly')
if ((Get-Content -LiteralPath (Join-Path $latest.FullName 'run.log') -Raw) -notmatch '\[DEBUG\]') { throw 'CLI debug override ignored' }
$settings | Add-Member Variants ([pscustomobject]@{ VF9WILD = [pscustomobject]@{ ExcelPrefix='interface_APSW_Model_VF9_WILD_' } })
$settings | Add-Member Paths ([pscustomobject]@{ InterfaceDir='custom-interface' })
Move-Item -LiteralPath (Join-Path $repo '01_ModelBaseDesign/01_SWE2_SoftwareArchitecture/Interface') -Destination (Join-Path $repo 'custom-interface')
Save-Config
Test-Case 'Custom variants and project paths from JSON' 0
$stats = Get-Content -LiteralPath (Join-Path $latest.FullName 'scenarios.json') -Raw | ConvertFrom-Json
if ($stats.Scenarios -ne 2) { throw 'Variants map should replace compatibility defaults' }
# Native stderr with exit 0 must not become a PS 5.1 NativeCommandError failure.
. (Join-Path $package 'Common.ps1')
$script:EvccDebug=$false
Invoke-EvccTool (Join-Path $env:SystemRoot 'System32/cmd.exe') @('/c','echo native-warning 1>&2') 'Native stderr smoke'
Write-Host '[TEST PASS] Native stderr with exit 0'
$settings.Debug.Enabled='yes'
Save-Config
Test-Case 'Invalid debug type rejected' 2 @('-CheckOnly')
Set-Content -LiteralPath $config -Value '{ invalid json'
$output = & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'Run-Baseline.ps1') -ConfigPath $config 2>&1
if ($LASTEXITCODE -ne 2 -or ($output -join "`n") -notmatch 'EVCCNightly-startup-') { throw 'Malformed JSON fallback diagnostics failed' }
Write-Host '[TEST PASS] Malformed JSON creates startup fallback log'
Write-Host "[DONE] Fixture retained in TEMP: $fixture"
