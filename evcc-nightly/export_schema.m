% Export the BSW schemas using the resolved JSON settings from the runner.
settings = jsondecode(erase(fileread(getenv('EVCC_SETTINGS_FILE')), char(65279)));
repoRoot = string(settings.RepoRoot);
fprintf('[MATLAB] Version=%s Repo=%s Debug=%d\n', version, repoRoot, settings.Debug.Enabled);
openProject(settings.Paths.ProjectFile);
cd(repoRoot);
if settings.Debug.Enabled
    fprintf('[DEBUG] ExportSchemaFunction=%s Resolved=%s\n', ...
        settings.Matlab.ExportSchemaFunction, which(settings.Matlab.ExportSchemaFunction));
    if settings.Debug.PrintMatlabProducts, disp(ver); end
end
% These helpers can be scripts; evaluate the validated identifier in this session.
eval(settings.Matlab.ExportSchemaFunction);
