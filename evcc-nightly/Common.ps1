#requires -Version 5.1
function Merge-EvccSettings($Target, $Source) {
    foreach ($property in $Source.PSObject.Properties) {
        $name = $property.Name
        if ($name -ne 'Variants' -and $property.Value -is [pscustomobject] -and $Target.PSObject.Properties[$name] -and
            $Target.$name -is [pscustomobject]) {
            Merge-EvccSettings $Target.$name $property.Value
        } else {
            $Target | Add-Member -NotePropertyName $name -NotePropertyValue $property.Value -Force
        }
    }
}

function Resolve-EvccPath([string]$Base, [string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An empty path is configured' }
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $Base $Path }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
}

function Read-EvccSettings([string]$ConfigPath) {
    $configFile = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path
    $settings = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.defaults.json') -Raw | ConvertFrom-Json
    $overrides = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
    if ($overrides -isnot [pscustomobject]) { throw 'Config JSON must contain an object' }
    Merge-EvccSettings $settings $overrides
    foreach ($name in @('RepoRoot','ResultsRoot')) {
        if ([string]::IsNullOrWhiteSpace($settings.$name)) { throw "Config $name must contain a directory path" }
    }
    $settings.RepoRoot = Resolve-EvccPath (Split-Path -Parent $configFile) $settings.RepoRoot
    $settings.ResultsRoot = Resolve-EvccPath (Split-Path -Parent $configFile) $settings.ResultsRoot
    foreach ($property in $settings.Paths.PSObject.Properties) {
        $property.Value = Resolve-EvccPath $settings.RepoRoot $property.Value
    }
    return $settings
}

function Test-EvccSettings($Settings) {
    foreach ($entry in @(
        @($Settings,'RequireGitRepository'), @($Settings,'KeepFailedScenarioMat'),
        @($Settings.Debug,'Enabled'), @($Settings.Debug,'PrintMatlabProducts'),
        @($Settings.Schedule,'WakeToRun'), @($Settings.Schedule,'StartWhenAvailable'),
        @($Settings.Schedule,'AllowStartIfOnBatteries'), @($Settings.Schedule,'DontStopIfGoingOnBatteries'))) {
        if ($entry[0].($entry[1]) -isnot [bool]) { throw "$($entry[1]) must be a JSON boolean" }
    }
    if ($Settings.RunMode -notin @('BaselineTest','GenerateBaseline')) { throw 'Unsupported RunMode' }
    if ([string]::IsNullOrWhiteSpace($Settings.BlfFiles)) { throw 'BlfFiles cannot be empty' }
    if ($Settings.VehicleVariant -ne 'All' -and -not $Settings.Variants.PSObject.Properties[$Settings.VehicleVariant]) {
        throw "Unsupported VehicleVariant: $($Settings.VehicleVariant)"
    }
    foreach ($name in @('TimeTolerance')) {
        $value = $Settings.Matlab.$name
        if ($value -is [string] -or $value -is [bool] -or $null -eq $value -or
            [double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value) -or $value -lt 0) {
            throw "Matlab.$name must be a finite nonnegative number"
        }
    }
    foreach ($name in @('ExportSchemaFunction','MergeFunction','SetVariantFunction','RunScenariosFunction','CompareFunction')) {
        if ($Settings.Matlab.$name -notmatch '^[A-Za-z]\w*(\.[A-Za-z]\w*)*$') { throw "Invalid MATLAB function: $name" }
    }
    if ($Settings.Debug.MaxValueElements -isnot [int] -or $Settings.Debug.MaxValueElements -lt 1) {
        throw 'Debug.MaxValueElements must be a positive integer'
    }
    foreach ($name in $Settings.Debug.MatlabVariables) {
        if ($name -notmatch '^[A-Za-z]\w*$') { throw "Invalid debug variable name: $name" }
    }
    foreach ($name in $Settings.PythonModules) {
        if ($name -notmatch '^[A-Za-z_]\w*(\.[A-Za-z_]\w*)*$') { throw "Invalid Python module: $name" }
    }
    foreach ($name in @($Settings.SchemaFiles) + @($Settings.Matlab.MergedScenarioFile) + @($Settings.Matlab.LegacyBaselines | ForEach-Object { $_.File })) {
        if ([string]::IsNullOrWhiteSpace($name) -or $name -match '[\\/]' -or $name -in @('.','..')) {
            throw "Expected a filename without a directory: $name"
        }
    }
    if (@($Settings.SchemaFiles).Count -ne 2) { throw 'SchemaFiles must contain input and output filenames, in that order' }
    if ($Settings.Schedule.At -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { throw 'Schedule.At must use HH:mm' }
    if ($Settings.Schedule.LogonType -notin @('Password','Interactive')) { throw 'Unsupported Schedule.LogonType' }
    if ($Settings.Schedule.MultipleInstances -notin @('IgnoreNew','Queue')) { throw 'Schedule.MultipleInstances must be IgnoreNew or Queue' }
    if ($Settings.Schedule.RunLevel -notin @('Limited','Highest')) { throw 'Unsupported Schedule.RunLevel' }
    if ($Settings.Schedule.TimeoutHours -is [string] -or $Settings.Schedule.TimeoutHours -is [bool] -or
        $Settings.Schedule.TimeoutHours -le 0 -or [double]::IsInfinity($Settings.Schedule.TimeoutHours) -or
        [double]::IsNaN($Settings.Schedule.TimeoutHours)) { throw 'Schedule.TimeoutHours must be a positive finite number' }
    if ([string]::IsNullOrWhiteSpace($Settings.Schedule.TaskName)) { throw 'Schedule.TaskName cannot be empty' }
    $repo = $Settings.RepoRoot
    if ($Settings.ResultsRoot -eq $repo -or $Settings.ResultsRoot.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ResultsRoot must be outside the test checkout'
    }
    # Only the converter's known work directory may be cleaned, within this checkout.
    if (-not $Settings.Paths.MatDir.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Paths.MatDir must be inside the dedicated test checkout'
    }
    $cursor = $Settings.Paths.MatDir
    while ($cursor.Length -ge $repo.Length) {
        if ((Test-Path -LiteralPath $cursor) -and
            ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Reparse point in test workspace: $cursor"
        }
        if ($cursor -eq $repo) { break }
        $cursor = Split-Path -Parent $cursor
    }
}

function Write-EvccDebug([string]$Message) {
    if ($script:EvccDebug) { Write-Host "[DEBUG] $Message" }
}

function Resolve-EvccExecutable([string]$Value, [string]$ConfigDirectory) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw 'An executable is not configured' }
    if ($Value -match '[\\/]' -or [IO.Path]::IsPathRooted($Value)) {
        $path = Resolve-EvccPath $ConfigDirectory $Value
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Executable not found: $path" }
        return $path
    }
    $command = Get-Command -Name $Value -CommandType Application -ErrorAction Stop | Select-Object -First 1
    return $command.Source
}

function Invoke-EvccTool([string]$Executable, [string[]]$Arguments, [string]$Stage) {
    $script:EvccPhase = $Stage
    Write-Host "[START] $Stage"
    Write-EvccDebug ('Command: "' + $Executable + '" ' + (($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '))
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $previousPreference = $ErrorActionPreference
    try {
        # PS 5.1 represents native stderr as error records: warnings are not process failures.
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = $null
        & $Executable @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
        $timer.Stop()
    }
    Write-EvccDebug ("ExitCode=$code ElapsedSeconds=$($timer.Elapsed.TotalSeconds.ToString('F2'))")
    if ($null -eq $code) { throw "$Stage could not start: $Executable" }
    if ($code -ne 0) { throw "$Stage failed (exit code $code). See command output above." }
    Write-Host "[DONE] $Stage"
}

function Invoke-EvccMatlab($Settings, [string]$ScriptFile, [string]$Stage) {
    $matlabPath = $ScriptFile.Replace("'", "''")
    Invoke-EvccTool $Settings.MatlabExe @('-batch', "run('$matlabPath');") $Stage
}
