#requires -Version 5.1
function Get-EvccInputPlan($Settings) {
    $variants = if ($Settings.VehicleVariant -eq 'All') {
        @($Settings.Variants.PSObject.Properties.Name)
    } else { @($Settings.VehicleVariant) }
    foreach ($variant in $variants) {
        if ($variant -notmatch '^[A-Za-z0-9_-]+$') { throw "Invalid variant directory: $variant" }
        $prefix = $Settings.Variants.$variant.ExcelPrefix
        if ([string]::IsNullOrWhiteSpace($prefix) -or $prefix -match '[\\/*?\[\]]') { throw "Invalid ExcelPrefix for $variant" }
        $candidates = @(Get-ChildItem -LiteralPath $Settings.Paths.InterfaceDir -Filter "$prefix*.xlsx" -File | ForEach-Object {
            $version = $null
            if ([version]::TryParse($_.BaseName.Substring($prefix.Length), [ref]$version)) {
                [pscustomobject]@{ FullName = $_.FullName; Version = $version }
            }
        })
        if ($candidates.Count -eq 0) { throw "No versioned interface Excel for $variant ($prefix*.xlsx) in $($Settings.Paths.InterfaceDir)" }
        $excel = ($candidates | Sort-Object Version -Descending | Select-Object -First 1).FullName
        $blfDir = Join-Path $Settings.Paths.BlfRoot $variant
        $baselineDir = Join-Path $Settings.Paths.BaselineRoot $variant
        $available = @(Get-ChildItem -LiteralPath $blfDir -Filter '*.blf' -File -ErrorAction Stop | Sort-Object Name)
        if ($available.Count -eq 0) { throw "No BLF files in $blfDir" }
        $selected = $available
        if ($Settings.RunMode -eq 'GenerateBaseline' -and $Settings.BlfFiles.Trim() -notin @('all','*')) {
            $names = @($Settings.BlfFiles -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
            if ($names.Count -eq 0) { throw 'No BLF filenames specified' }
            $selected = @(foreach ($name in $names) {
                if ($name -notmatch '(?i)\.blf$' -or $name -match '[\\/]' -or $name -ne [IO.Path]::GetFileName($name)) { throw "Invalid BLF filename: $name" }
                $found = @($available | Where-Object { $_.Name -ieq $name })
                if ($found.Count -ne 1) { throw "BLF not found in ${variant}: $name" }
                $found[0]
            })
        }
        if ($Settings.RunMode -eq 'BaselineTest') {
            foreach ($file in $selected) {
                $reference = Join-Path $baselineDir ($file.BaseName + '_baseline.mat')
                if (-not (Test-Path -LiteralPath $reference -PathType Leaf)) {
                    $legacy = @($Settings.Matlab.LegacyBaselines | Where-Object { $_.Scenario -ceq $file.BaseName })
                    if ($legacy.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $baselineDir $legacy[0].File) -PathType Leaf)) {
                        throw "Baseline missing for $variant/$($file.BaseName): $reference"
                    }
                }
            }
        }
        Write-Host "[$variant] Excel=$excel; BLFs=$($selected.Count)"
        Write-EvccDebug "BLF directory=$blfDir Baseline directory=$baselineDir"
        foreach ($file in $selected) { Write-EvccDebug "Selected BLF=$($file.FullName)" }
        [pscustomobject]@{ Variant = $variant; Excel = $excel; BlfDir = $blfDir;
            BaselineDir = $baselineDir; Available = $available; Selected = $selected }
    }
}

function Invoke-EvccWorkflow($Settings, [object[]]$Plan, [string]$ArtRoot) {
    $totalFault = 0
    $totalScenarios = 0
    foreach ($item in $Plan) {
        $variant = $item.Variant
        $script:EvccPhase = "Prepare $variant"
        Write-Host "[VARIANT] $variant"
        # The converter and MATLAB helpers share this work directory by contract.
        Get-ChildItem -LiteralPath $Settings.Paths.MatDir -File | Where-Object {
            $_.Name -match '(_input|_output)\.mat$' -or $_.Name -eq $Settings.Matlab.MergedScenarioFile
        } | ForEach-Object { Write-EvccDebug "Remove stale MAT=$($_.FullName)"; Remove-Item -LiteralPath $_.FullName -Force }
        $blfInput = $item.BlfDir
        if ($item.Selected.Count -eq 1) { $blfInput = $item.Selected[0].FullName }
        elseif ($item.Selected.Count -lt $item.Available.Count) {
            $blfInput = Join-Path $ArtRoot ("EVCC_BLF_" + $variant)
            New-Item -ItemType Directory -Path $blfInput | Out-Null
            foreach ($file in $item.Selected) { Copy-Item -LiteralPath $file.FullName -Destination $blfInput }
        }
        $converterArgs = @($Settings.Paths.PythonTool, '--excel', $item.Excel,
            '--dbc-folder', $Settings.Paths.DbcDir, '--blf', $blfInput, '--schema') +
            @($Settings.SchemaFiles | ForEach-Object { Join-Path $Settings.Paths.SchemaDir $_ }) +
            @('--output', $Settings.Paths.MatDir, '--config', $Settings.Paths.MappingConfig, '--matlab', $Settings.MatlabExe)
        Invoke-EvccTool $Settings.PythonExe $converterArgs "Convert BLF: $variant"
        foreach ($file in $item.Selected) {
            $generated = Join-Path $Settings.Paths.MatDir ($file.BaseName + '_input.mat')
            if (-not (Test-Path -LiteralPath $generated -PathType Leaf)) { throw "Missing converted MAT: $generated" }
        }
        $inputs = @(Get-ChildItem -LiteralPath $Settings.Paths.MatDir -Filter '*_input.mat' -File)
        if ($inputs.Count -ne $item.Selected.Count) { throw "Unexpected input MAT count for $variant" }
        $statusFile = Join-Path $ArtRoot ("evcc_${variant}_status.txt")
        $env:EVCC_VARIANT = $variant
        $env:EVCC_RUN_MODE = $Settings.RunMode
        $env:EVCC_BASELINE_DIR = $item.BaselineDir
        $env:EVCC_MAT_DIR = $Settings.Paths.MatDir
        $env:EVCC_STATUS_FILE = $statusFile
        $env:EVCC_KEEP_FAILED_MAT = [string]$Settings.KeepFailedScenarioMat
        Write-EvccDebug "EVCC_VARIANT=$variant EVCC_MAT_DIR=$env:EVCC_MAT_DIR EVCC_STATUS_FILE=$statusFile EVCC_DEBUG=$env:EVCC_DEBUG"
        Invoke-EvccMatlab $Settings (Join-Path $PSScriptRoot 'run_variant.m') "Merge, simulate and compare: $variant"
        if (-not (Test-Path -LiteralPath $statusFile -PathType Leaf)) { throw "MATLAB status file missing: $statusFile" }
        $counts = (Get-Content -LiteralPath $statusFile -Raw).Trim() -split ','
        if ($counts.Count -ne 2 -or $counts[0] -notmatch '^\d+$' -or $counts[1] -notmatch '^[1-9]\d*$' -or [int]$counts[0] -gt [int]$counts[1]) {
            throw "Invalid MATLAB status for ${variant}: $($counts -join ',')"
        }
        $totalFault += [int]$counts[0]
        $totalScenarios += [int]$counts[1]
    }
    $script:EvccPhase = 'Complete'
    Write-Host "[SUMMARY] $($Settings.RunMode)/$($Settings.VehicleVariant): $totalFault failure(s)/$totalScenarios scenario(s)"
    return [pscustomobject]@{ Mode = $Settings.RunMode; Vehicle = $Settings.VehicleVariant;
        Failures = $totalFault; Scenarios = $totalScenarios }
}
