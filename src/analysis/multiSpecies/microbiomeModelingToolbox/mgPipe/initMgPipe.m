function [init, netSecretionFluxes, netUptakeFluxes, Y, modelStats, summary, statistics, modelsOK] = initMgPipe(modPath, abunFilePath, computeProfiles, varargin)
% This function initializes the mgPipe pipeline and sets the optional input 
% variables if not defined.
%
% USAGE
%       [init, netSecretionFluxes, netUptakeFluxes, Y, modelStats, summary, statistics, modelsOK] = initMgPipe(modPath, abunFilePath, computeProfiles, varargin)
%
% INPUTS:
%    modPath:                char with path of directory where models are stored
%    abunFilePath:           char with path and name of file from which to retrieve abundance information
%    computeProfiles:        boolean defining whether flux variability analysis to 
%                            compute the metabolic profiles should be performed.
%
% OPTIONAL INPUTS:
%    resPath:                char with path of directory where results are saved
%    dietFilePath:           char with path of directory where the diet is saved.
%                            Can also be a character array with a separate diet for
%                            each individual, in that case, size(dietFilePath,1) 
%                            needs to equal the length of samples.
%    infoFilePath:           char with path to stratification criteria if available
%    hostPath:               char with path to host model, e.g., Recon3D (default: empty)
%    hostBiomassRxn:         char with name of biomass reaction in host (default: empty)
%    hostBiomassRxnFlux:     double with the desired upper bound on flux through the host
%                            biomass reaction (default: 1)
%    objre:                  char with reaction name of objective function of organisms
%    saveConstrModels:       boolean indicating if models with imposed
%                            constraints are saved externally
%    numWorkers:             integer indicating the number of cores to use for parallelization
%    rDiet:                  boolean indicating if to enable also rich diet simulations (default: 'false')
%    pDiet:                  boolean indicating if to enable also personalized diet simulations (default: 'false')
%    includeHumanMets:       boolean indicating if human-derived metabolites
%                            present in the gut should be provided to the models (default: true)
%    lowerBMBound:           lower bound on community biomass (default=0.4)
%    repeatSim:              boolean defining if simulations should be repeated and previous results
%                            overwritten (default=false)
%    adaptMedium:            boolean indicating if the medium should be adapted through the
%                            adaptVMHDietToAGORA function or used as is (default=true)
%    removeBlockedRxns:      Remove reactions blocked on the input diet to
%                            reduce computation time (default=false)
%
% OUTPUTS:
%    init:                   status of initialization
%    netSecretionFluxes:     Net secretion fluxes by microbiome community models
%    netUptakeFluxes:        Net uptake fluxes by microbiome community models
%    Y:                      Classical multidimensional scaling
%    modelStats:             Reaction and metabolite numbers for each model
%    summary:                Table with average, median, minimal, and maximal
%                            reactions and metabolites
%    statistics:             If info file with stratification is provided, will
%                            determine if there is a significant difference.
%    modelsOK:               Boolean indicating if the created microbiome models
%                            passed verifyModel. If true, all models passed.
%
% .. Author: Federico Baldini 2018
%               - Almut Heinken 02/2020: removed unnecessary outputs
%               - Almut Heinken 08/2020: added extra inputs and changed to
%                                        varargin input
%               - Almut Heinken 02/2021: added option for creation of each 
%                                        personalized model separately and
%                                        output of model stats
%               - Almut Heinken 03/2021: inserted error message if 
%                                        abundances are not normalized.


% Define default input parameters if not specified
parser = inputParser();
parser.addRequired('modPath', @ischar);
parser.addRequired('abunFilePath', @ischar);
parser.addRequired('computeProfiles', @islogical);
parser.addParameter('resPath', [pwd filesep 'Results'], @ischar);
parser.addParameter('dietFilePath', 'AverageEuropeanDiet', @ischar);
parser.addParameter('infoFilePath', '', @ischar);
parser.addParameter('hostPath', '', @ischar);
parser.addParameter('hostBiomassRxn', '', @ischar);
parser.addParameter('hostBiomassRxnFlux', 1, @isnumeric);
parser.addParameter('objre', '', @ischar);
parser.addParameter('saveConstrModels', false, @islogical);
parser.addParameter('numWorkers', 2, @isnumeric);
parser.addParameter('rDiet', false, @islogical);
parser.addParameter('pDiet', false, @islogical);
parser.addParameter('includeHumanMets', true, @islogical);
parser.addParameter('lowerBMBound', 0.4, @isnumeric);
parser.addParameter('repeatSim', false, @islogical);
parser.addParameter('adaptMedium', true, @islogical);
parser.addParameter('removeBlockedRxns', false, @islogical);

parser.parse(modPath, abunFilePath, computeProfiles, varargin{:});

modPath = parser.Results.modPath;
abunFilePath = parser.Results.abunFilePath;
computeProfiles = parser.Results.computeProfiles;
resPath = parser.Results.resPath;
dietFilePath = parser.Results.dietFilePath;
infoFilePath = parser.Results.infoFilePath;
hostPath = parser.Results.hostPath;
hostBiomassRxn = parser.Results.hostBiomassRxn;
hostBiomassRxnFlux = parser.Results.hostBiomassRxnFlux;
objre = parser.Results.objre;
saveConstrModels = parser.Results.saveConstrModels;
numWorkers = parser.Results.numWorkers;
rDiet = parser.Results.rDiet;
pDiet = parser.Results.pDiet;
includeHumanMets = parser.Results.includeHumanMets;
lowerBMBound = parser.Results.lowerBMBound;
repeatSim = parser.Results.repeatSim;
adaptMedium = parser.Results.adaptMedium;
removeBlockedRxns = parser.Results.removeBlockedRxns;

global CBT_LP_SOLVER
if isempty(CBT_LP_SOLVER)
    initCobraToolbox
end

% set parallel pool
if numWorkers > 1
    poolobj = gcp('nocreate');
    if isempty(poolobj)
        parpool(numWorkers)
    end
end

global CBTDIR
    
% set optional variables
mkdir(resPath);

currentDir=pwd;
    
if ~contains(dietFilePath,'.txt')
   dietFilePath=[dietFilePath '.txt']; 
end
if exist(dietFilePath)==0
    error('Path to file with dietary information is incorrect!');
end

% test if abundances are normalized
abundance = table2cell(readtable(abunFilePath,'ReadVariableNames',false));
totalAbun=sum(str2double(abundance(2:end,2:end)),1);
if any(totalAbun > 1.01)
    error('Abundances are not normalized. Please run the function normalizeCoverage!')
end

if strcmp(infoFilePath, '')
    patStat = false;
else
    patStat = true;
end

% adding a filesep at the end of the path
if ~strcmpi(resPath(end), filesep)
    resPath = [resPath filesep];
end

if isempty(objre)
   objre = {'EX_biomass(e)'};
   warning(['The default objective (objre) has been set to ' objre{1}]);
else
    objre=cellstr(objre);
end

% define file type for images
figForm = '-depsc';

% Check for installation of parallel Toolbox
try
   version = ver('parallel');
catch
   error('Sequential mode not available for this application. Please install Parallel Computing Toolbox');
end

if numWorkers > 1
    poolobj = gcp('nocreate');
    if isempty(poolobj)
        parpool(numWorkers)
    end
else
    error('You disabled parallel mode to enable sequential one. Sequential mode is not available for this application. Please specify a higher number of workers modifying numWorkers option.')
end

if patStat == false
    warning('Individuals health status not declared. Analysis will ignore that.')
end

% output messages
fprintf(' > Models will be read from: %s\n', modPath);
fprintf(' > Results will be stored in: %s\n', resPath);
fprintf(' > Microbiome Toolbox pipeline initialized successfully.\n');

init = true;

[netSecretionFluxes, netUptakeFluxes, Y, modelStats, summary, statistics, modelsOK] = mgPipe(modPath, abunFilePath, computeProfiles, resPath, dietFilePath, infoFilePath, hostPath, hostBiomassRxn, hostBiomassRxnFlux, objre, saveConstrModels, figForm, numWorkers, rDiet, pDiet, includeHumanMets, lowerBMBound, repeatSim, adaptMedium, removeBlockedRxns);

cd(currentDir)

end
