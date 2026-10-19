% Merge, select variant, simulate and compare in the same MATLAB session.
phase = 'Initialize';
variant = string(getenv('EVCC_VARIANT'));
try
    settings = jsondecode(erase(fileread(getenv('EVCC_SETTINGS_FILE')), char(65279)));
    repoRoot = string(settings.RepoRoot);
    runMode = string(getenv('EVCC_RUN_MODE'));
    baselineDir = string(getenv('EVCC_BASELINE_DIR'));
    matDir = string(settings.Paths.MatDir);
    artifactRoot = string(getenv('EVCC_ARTIFACT_DIR'));
    statusFile = string(getenv('EVCC_STATUS_FILE'));
    modelName = settings.Matlab.ModelName;
    fprintf('[MATLAB] Variant=%s Mode=%s\n', variant, runMode);
    phase = 'Open project';
    openProject(settings.Paths.ProjectFile);
    cd(repoRoot);
    print_debug_state(phase, settings);

    phase = 'Merge scenarios';
    fprintf('[START] %s\n', phase);
    eval(settings.Matlab.MergeFunction);
    scenarioMat = fullfile(matDir, settings.Matlab.MergedScenarioFile);
    if ~isfile(scenarioMat), error('Merged scenario MAT missing: %s', scenarioMat); end
    fprintf('[DONE] Merged scenarios: %s\n', scenarioMat);
    print_debug_state(phase, settings);

    % Converter *_output.mat is decoded CAN output, not simulation output.
    phase = 'Clear decoded outputs';
    oldOutputs = dir(fullfile(matDir, '*_output.mat'));
    for k = 1:numel(oldOutputs), delete(fullfile(oldOutputs(k).folder, oldOutputs(k).name)); end
    fprintf('[DONE] Removed %d decoded outputs\n', numel(oldOutputs));

    phase = 'Set variant';
    fprintf('[START] %s: %s\n', phase, variant);
    load_system(modelName);
    feval(settings.Matlab.SetVariantFunction, variant);
    print_debug_state(phase, settings);

    phase = 'Run simulation';
    fprintf('[START] %s\n', phase);
    feval(settings.Matlab.RunScenariosFunction, modelName);
    fprintf('[DONE] Simulation returned normally\n');
    print_debug_state(phase, settings);

    phase = 'Validate simulated MAT outputs';
    inputs = dir(fullfile(matDir, '*_input.mat'));
    outputs = dir(fullfile(matDir, '*_output.mat'));
    fprintf('[FILES] Input MATs: %d | Simulated output MATs: %d\n', numel(inputs), numel(outputs));
    if isempty(inputs), error('No scenario input MAT files for %s', variant); end
    totalFault = 0;
    for k = 1:numel(inputs)
        stem = regexprep(inputs(k).name, '_input\.mat$', '');
        actual = fullfile(matDir, [stem '_output.mat']);
        phase = ['Validate output: ' stem];
        fprintf('[OUTPUT] %s\n', actual);
        if ~isfile(actual), error('Simulation output missing: %s', actual); end
        if strcmp(runMode, 'GenerateBaseline')
            phase = ['Generate baseline: ' stem];
            targetDir = fullfile(artifactRoot, 'GeneratedBaseline', variant);
            if ~isfolder(targetDir), mkdir(targetDir); end
            target = fullfile(targetDir, [stem '_baseline.mat']);
            [ok, msg] = copyfile(actual, target);
            if ~ok, error('Cannot copy baseline: %s', msg); end
            fprintf('[BASELINE] %s\n', target);
        else
            phase = ['Resolve baseline: ' stem];
            reference = fullfile(baselineDir, [stem '_baseline.mat']);
            if ~isfile(reference)
                for fallback = reshape(settings.Matlab.LegacyBaselines, 1, [])
                    if strcmp(stem, fallback.Scenario)
                        oldReference = fullfile(baselineDir, fallback.File);
                        if isfile(oldReference), reference = oldReference; end
                        break;
                    end
                end
            end
            fprintf('[BASELINE] %s\n', reference);
            if ~isfile(reference), error('Baseline missing for %s: %s', stem, reference); end
            phase = ['Compare baseline: ' stem];
            fprintf('[START] %s\n', phase);
            fault = feval(settings.Matlab.CompareFunction, actual, reference, ...
                'TimeTolerance', settings.Matlab.TimeTolerance);
            if isempty(fault) || ~isscalar(fault) || (~isnumeric(fault) && ~islogical(fault)) || ...
                    ~isreal(fault) || isnan(fault) || isinf(fault)
                error('Invalid return from %s for %s', settings.Matlab.CompareFunction, stem);
            end
            print_debug_state(phase, settings);
            if fault ~= 0
                totalFault = totalFault + 1;
                if settings.KeepFailedScenarioMat
                    targetDir = fullfile(artifactRoot, 'FailedScenarioMAT', variant);
                    if ~isfolder(targetDir), mkdir(targetDir); end
                    [ok, msg] = copyfile(actual, targetDir);
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

function print_debug_state(phase, settings)
if ~settings.Debug.Enabled, return; end
fprintf('[DEBUG] Phase=%s MATLAB=%s CWD=%s\n', phase, version, pwd);
helpers = {settings.Matlab.MergeFunction, settings.Matlab.SetVariantFunction, ...
    settings.Matlab.RunScenariosFunction, settings.Matlab.CompareFunction};
for h = 1:numel(helpers)
    fprintf('[DEBUG] Helper=%s Resolved=%s\n', helpers{h}, which(helpers{h}));
end
names = string(settings.Debug.MatlabVariables);
for n = 1:numel(names)
    name = char(names(n));
    if ~isvarname(name), continue; end
    try
        value = evalin('caller', name);
        fprintf('[DEBUG] Variable=%s Class=%s Size=%s\n', name, class(value), mat2str(size(value)));
        if (isnumeric(value) || islogical(value) || ischar(value) || isstring(value)) && ...
                numel(value) <= settings.Debug.MaxValueElements
            disp(value);
        else
            fprintf('[DEBUG] Value omitted (type/size limit)\n');
        end
    catch
        fprintf('[DEBUG] Variable=%s unavailable at this phase\n', name);
    end
end
end
