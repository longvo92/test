#requires -Version 5.1
# Adapted from the attached EVCC baseline pipeline; MATLAB calls and comparison tolerance preserved.
function Invoke-EvccWorkflow {
param([string]$Repo, [string]$Mode, [string]$Vehicle, [string]$Selection,
      [string]$Matlab, [string]$Python, [string]$ArtRoot, [bool]$KeepFailedMat)
$ErrorActionPreference = 'Stop'
$selection = $Selection.Trim()
$matDir = Join-Path $repo '01_ModelBaseDesign/04_SWE5_SoftwareIntegration/simulation_resource/mat'

$pythonTool = Join-Path $repo '01_ModelBaseDesign/06_Tools/TestAction/blf2mat/blf_to_signal_editor_cli.py'
# Interface Excel is variant-specific; version is resolved per variant below.
$interfaceDir = Join-Path $repo '01_ModelBaseDesign/01_SWE2_SoftwareArchitecture/Interface'
$excelPrefixByVariant = @{
  VF68NP = 'interface_APSW_Model_VF68NP_'
  VF9WILD = 'interface_APSW_Model_VF9_WILD_'
}
if (-not (Test-Path -LiteralPath $interfaceDir -PathType Container)) {
  throw "Interface directory not found: $interfaceDir"
}
$dbc = Join-Path $repo '01_ModelBaseDesign/Common/dbc'
$config = Join-Path $repo '01_ModelBaseDesign/06_Tools/TestAction/blf2mat/signal_mapping.yaml'
$schema = Join-Path $repo '01_ModelBaseDesign/04_SWE5_SoftwareIntegration/simulation_resource'

$variants = if ($vehicle -eq 'All') { @('VF68NP', 'VF9WILD') } else { @($vehicle) }
if ($mode -notin @('GenerateBaseline','BaselineTest')) { throw "Unknown run mode: $mode" }
if ($variants.Count -eq 0) { throw 'No vehicle variant selected' }

Set-Location -LiteralPath $repo
$totalFault = 0
$totalScenarios = 0

foreach ($variant in $variants) {
  Write-Host "[VARIANT] $variant"

  # Resolve the Excel matching THIS variant, regardless of version.
  $excelPrefix = $excelPrefixByVariant[$variant]
  if (-not $excelPrefix) { throw "Unsupported Excel variant: $variant" }
  $excelCandidates = @(
    Get-ChildItem -LiteralPath $interfaceDir -Filter "$($excelPrefix)*.xlsx" -File |
      ForEach-Object {
        $versionText = $_.BaseName.Substring($excelPrefix.Length)
        $parsedVersion = $null
        if ([version]::TryParse($versionText, [ref]$parsedVersion)) {
          [pscustomobject]@{
            FullName = $_.FullName
            Version = $parsedVersion
          }
        }
      }
  )
  if ($excelCandidates.Count -eq 0) {
    throw "No versioned interface Excel found for $variant (expected: $($excelPrefix)*.xlsx) in $interfaceDir"
  }
  # Use numeric version order (e.g. 0.3.10 > 0.3.9), not file modification time.
  $excel = ($excelCandidates | Sort-Object -Property Version -Descending |
    Select-Object -First 1).FullName
  Write-Host "[$variant] Excel: $([IO.Path]::GetFileName($excel))"

  $blfDir = Join-Path (Join-Path $repo '01_ModelBaseDesign/04_SWE5_SoftwareIntegration/simulation_resource/blf') $variant
  $baselineDir = Join-Path (Join-Path $repo '01_ModelBaseDesign/04_SWE5_SoftwareIntegration/Baseline') $variant
  if (-not (Test-Path -LiteralPath $blfDir -PathType Container)) {
    throw "BLF folder missing: $blfDir"
  }
  if ($mode -eq 'BaselineTest' -and -not (Test-Path -LiteralPath $baselineDir -PathType Container)) {
    throw "Baseline folder missing: $baselineDir"
  }
  $available = @(Get-ChildItem -LiteralPath $blfDir -Filter '*.blf' -File)
  if ($available.Count -eq 0) { throw "No BLF files in $blfDir" }

  if ($mode -eq 'GenerateBaseline' -and $selection -notin @('all','*')) {
    $names = @($selection -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } |
      Where-Object { $_ } | Select-Object -Unique)
    if ($names.Count -eq 0) { throw 'No BLF filenames specified' }
    $selected = @()
    foreach ($name in $names) {
      if ($name -notmatch '(?i)\.blf$' -or $name -match '[\\/]' -or
          [IO.Path]::GetFileName($name) -ne $name) {
        throw "Invalid BLF filename: $name"
      }
      $found = @($available | Where-Object { $_.Name -ieq $name })
      if ($found.Count -ne 1) { throw "BLF not found in ${variant}: $name" }
      $selected += $found[0]
    }
  } else {
    $selected = $available
  }
  Write-Host "[$variant] $($selected.Count) BLF(s) selected"
  foreach ($item in $selected) { Write-Host "  $($item.Name)" }

  # Shared MAT folder: remove stale input/output and merged scenarios.
  Get-ChildItem -LiteralPath $matDir -File | Where-Object {
    $_.Name -match '(_input|_output)\.mat$' -or
    $_.Name -eq 'EVCC_Intergration_Scenarios.mat'
  } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }

  # CLI accepts one BLF or a folder. Stage a subset only when necessary.
  $blfInput = $blfDir
  if ($selected.Count -eq 1) {
    $blfInput = $selected[0].FullName
  } elseif ($selected.Count -lt $available.Count) {
    $subset = Join-Path $artRoot ("EVCC_BLF_" + $variant)
    New-Item -ItemType Directory -Path $subset | Out-Null
    foreach ($f in $selected) { Copy-Item -LiteralPath $f.FullName -Destination $subset }
    $blfInput = $subset
  }

  Write-Host "[$variant] Converting BLF to Dataset MAT ..."
  & $Python $pythonTool `
    --excel $excel `
    --dbc-folder $dbc `
    --blf $blfInput `
    --schema (Join-Path $schema 'BSW_IN.txt') (Join-Path $schema 'BSW_OUT.txt') `
    --output $matDir `
    --config $config `
    --matlab $matlab | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "BLF converter failed for $variant" }
  foreach ($f in $selected) {
    $generated = Join-Path $matDir ($f.BaseName + '_input.mat')
    if (-not (Test-Path -LiteralPath $generated -PathType Leaf)) {
      throw "Missing converted MAT: $generated"
    }
  }
  $inputs = @(Get-ChildItem -LiteralPath $matDir -Filter '*_input.mat' -File)
  if ($inputs.Count -ne $selected.Count) { throw "Unexpected input MAT count for $variant" }

  # Keep variant configuration in the same MATLAB process as simulation.
  $statusFile = Join-Path $artRoot ("evcc_${variant}_status.txt")
  if (Test-Path -LiteralPath $statusFile) { Remove-Item -LiteralPath $statusFile -Force }
  $env:EVCC_REPO_ROOT = $repo
  $env:EVCC_VARIANT = $variant
  $env:EVCC_RUN_MODE = $mode
  $env:EVCC_BASELINE_DIR = $baselineDir
  $env:EVCC_MAT_DIR = $matDir
  $env:EVCC_ARTIFACT_DIR = $artRoot
  $env:EVCC_STATUS_FILE = $statusFile
  $env:EVCC_KEEP_FAILED_MAT = [string]$KeepFailedMat
  Write-Host "[$variant] Merge -> set_wdmode_variant -> simulate -> compare/stage ..."
  $code = @'
  phase = 'Initialize';
  variant = string(getenv('EVCC_VARIANT'));
  try
      repoRoot = string(getenv('EVCC_REPO_ROOT'));
      runMode = string(getenv('EVCC_RUN_MODE'));
      baselineDir = string(getenv('EVCC_BASELINE_DIR'));
      matDir = string(getenv('EVCC_MAT_DIR'));
      artifactRoot = string(getenv('EVCC_ARTIFACT_DIR'));
      statusFile = string(getenv('EVCC_STATUS_FILE'));
      modelName = 'EVCC_Intergration';

      fprintf('[MATLAB] Variant=%s Mode=%s\n', variant, runMode);
      phase = 'Open project';
      fprintf('[START] %s\n', phase);
      openProject(fullfile(repoRoot, '01_ModelBaseDesign/EVCC_Architecture.prj'));
      cd(repoRoot);

      phase = 'Merge scenarios';
      fprintf('[START] %s\n', phase);
      merge_mat_scenarios;
      scenarioMat = fullfile(matDir, 'EVCC_Intergration_Scenarios.mat');
      if ~isfile(scenarioMat)
          error('Merged scenario MAT missing: %s', scenarioMat);
      end
      fprintf('[DONE] Merged scenarios: %s\n', scenarioMat);

      % Converter *_output.mat = decoded CAN output, not simulation output.
      phase = 'Clear decoded outputs';
      oldOutputs = dir(fullfile(matDir, '*_output.mat'));
      for k = 1:numel(oldOutputs)
          delete(fullfile(oldOutputs(k).folder, oldOutputs(k).name));
      end
      fprintf('[DONE] Removed %d decoded outputs\n', numel(oldOutputs));

      phase = 'Set variant';
      fprintf('[START] %s: %s\n', phase, variant);
      load_system(modelName);
      set_wdmode_variant(variant);
      fprintf('[DONE] Variant: %s\n', variant);

      phase = 'Run simulation';
      fprintf('[START] %s\n', phase);
      run_all_scenarios(modelName);
      fprintf('[DONE] Simulation returned normally\n');

      phase = 'Validate simulated MAT outputs';
      inputs = dir(fullfile(matDir, '*_input.mat'));
      outputs = dir(fullfile(matDir, '*_output.mat'));
      fprintf('[FILES] Input MATs: %d | Simulated output MATs: %d\n', numel(inputs), numel(outputs));
      if isempty(inputs)
          error('No scenario input MAT files for %s', variant);
      end
      totalFault = 0;
      for k = 1:numel(inputs)
          stem = regexprep(inputs(k).name, '_input\.mat$', '');
          actual = fullfile(matDir, [stem '_output.mat']);
          phase = ['Validate output: ' stem];
          fprintf('[OUTPUT] %s\n', actual);
          if ~isfile(actual)
              error('Simulation output missing: %s', actual);
          end

          if strcmp(runMode, 'GenerateBaseline')
              phase = ['Generate baseline: ' stem];
              targetDir = fullfile(artifactRoot, 'GeneratedBaseline', variant);
              if ~isfolder(targetDir), mkdir(targetDir); end
              target = fullfile(targetDir, [stem '_baseline.mat']);
              [ok,msg] = copyfile(actual, target);
              if ~ok, error('Cannot copy baseline: %s', msg); end
              fprintf('[BASELINE] %s\n', target);
          else
              phase = ['Resolve baseline: ' stem];
              reference = fullfile(baselineDir, [stem '_baseline.mat']);
              if ~isfile(reference)
                  switch stem
                      case 'AC-Basic_Charging', legacy = 'AC-Basic_baseline.mat';
                      case 'AC-HLC_Charging',   legacy = 'AC-HLC_baseline.mat';
                      case 'DC-HLC_Charging',   legacy = 'DC-HLC_baseline.mat';
                      case 'V2L-Discharging',  legacy = 'V2L_Discharging_baseline.mat';
                      otherwise, legacy = '';
                  end
                  if ~isempty(legacy)
                      oldReference = fullfile(baselineDir, legacy);
                      if isfile(oldReference), reference = oldReference; end
                  end
              end
              fprintf('[BASELINE] %s\n', reference);
              if ~isfile(reference)
                  error('Baseline missing for %s: %s', stem, reference);
              end
              phase = ['Compare baseline: ' stem];
              fprintf('[START] %s\n', phase);
              fault = compare_baseline(actual, reference, 'TimeTolerance', 0.5);
              if isempty(fault) || ~isscalar(fault) || (~isnumeric(fault) && ~islogical(fault))
                  error('Invalid compare_baseline return for %s', stem);
              end
              if fault ~= 0
                  totalFault = totalFault + 1;
                  if strcmpi(getenv('EVCC_KEEP_FAILED_MAT'), 'True')
                      targetDir = fullfile(artifactRoot, 'FailedScenarioMAT', variant);
                      if ~isfolder(targetDir), mkdir(targetDir); end
                      [ok,msg] = copyfile(actual, targetDir);
                      if ~ok, error('Cannot copy failed output: %s', msg); end
                  end
                  fprintf('[FAIL] %s/%s\n', variant, stem);
              else
                  fprintf('[PASS] %s/%s\n', variant, stem);
              end
          end
      end
      phase = 'Write summary';
      fid = fopen(statusFile, 'w');
      if fid < 0, error('Cannot write %s', statusFile); end
      fprintf(fid, '%d,%d\n', totalFault, numel(inputs));
      fclose(fid);
      fprintf('[SUMMARY] %s: %d failed / %d scenarios\n', variant, totalFault, numel(inputs));
  catch ME
      fprintf(2, '\n[MATLAB FAILED] Variant=%s | Phase=%s\n', variant, phase);
      fprintf(2, '%s\n', getReport(ME, 'extended', 'hyperlinks', 'off'));
      rethrow(ME);
  end
'@
  & $matlab -batch $code | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "MATLAB workflow failed for $variant" }
  if (-not (Test-Path -LiteralPath $statusFile -PathType Leaf)) {
    throw "MATLAB status file missing for $variant"
  }
  $counts = (Get-Content -LiteralPath $statusFile -Raw).Trim() -split ','
  if ($counts.Count -ne 2 -or $counts[0] -notmatch '^\d+$' -or $counts[1] -notmatch '^[1-9]\d*$' -or [int]$counts[0] -gt [int]$counts[1]) { throw "Invalid status file for $variant" }
  $totalFault += [int]$counts[0]
  $totalScenarios += [int]$counts[1]
  
}

Write-Host "[SUMMARY] $mode / $vehicle : $totalFault failure(s) / $totalScenarios scenario(s)"

return [pscustomobject]@{ Mode = $Mode; Vehicle = $Vehicle; Failures = $totalFault; Scenarios = $totalScenarios }
}
