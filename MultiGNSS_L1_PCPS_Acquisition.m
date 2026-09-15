%% MultiGNSS_L1_PCPS_Acquisition.m
% =========================================================================
% 多星座 L1/E1/B1 频段传统 PCPS 捕获
%
% 在用户现有 GPS L1 C/A、SBAS L1、BDS B1I、BDS B1C Pilot-A 脚本的
% 编程风格上统一扩展，输入仍为 USRP B210 8-bit 交织 IQ：
%       I0, Q0, I1, Q1, I2, Q2, ...
%
% 当前支持的开放信号：
%   1. GPS      L1 C/A          1575.42 MHz, BPSK(1), PRN 1~32
%   2. BDS      B1C Pilot-A     1575.42 MHz, BOC(1,1) 主导频分量, PRN 1~63
%   3. BDS      B1I             1561.098 MHz, BPSK(2), PRN 1~63
%   4. SBAS     L1 C/A          1575.42 MHz, PRN 120~158
%   5. GLONASS  L1OF            1602+k*0.5625 MHz, k=-7~+6
%   6. Galileo  E1-C Pilot      1575.42 MHz, E1C primary x sinBOC(1,1), SVID 1~50
%   7. QZSS     L1 C/A          1575.42 MHz, standard PRN 193~197/199~201
%   8. QZSS     L1 C/B          1575.42 MHz, PRN 203~206
%   9. NavIC    L1 SPS Data     1575.42 MHz, IZ4 primary x sinBOC(1,1), PRN 1~64
%
% 重要：
%   * 本文件的采集中心 1575.42 MHz、复采样率 30 MHz、RF 带宽 30 MHz，
%     理想数字基带只覆盖约 ±15 MHz。
%   * BDS B1I 位于数字基带 -14.322 MHz，处在带宽边缘，可搜索但可能被
%     B210 模拟/数字滤波器滚降明显衰减。
%   * GLONASS L1OF 最低频道也在约 1598.0625 MHz，当前文件看不到。
%     代码保留完整 GLONASS L1OF 支持；若以后把采集中心改到约 1602 MHz，
%     同一框架会自动执行 GLONASS 频道搜索。
%
% Galileo E1C primary code：
%   Galileo E1-C 使用本地 4092-chip memory-code 缓存，不依赖新版本工具箱函数。
%   程序优先读取同目录 Galileo_E1C_PrimaryCodes.mat；如果缓存不存在，
%   会自动调用 Prepare_Galileo_E1C_Codes.m，从公开 E1-C memory-code 表建立缓存。
%
% 捕获结果保存：MultiGNSS_L1_Acquisition_Result.mat
% 跟踪入口：    MultiGNSS_L1_Tracking.m
% =========================================================================

clear;
clc;
close all;

%% ========================================================================
%  1. 用户参数
% =========================================================================

% 修改为你的实际 1575.42 MHz / 30 Msps / sc8 IQ 文件。
iqFile = 'XXXXX';

% USRP B210 实采参数
rawFs = 30e6;
captureCenterFrequency = 1575.42e6;
captureBandwidth = 30e6;

% 从文件哪个位置开始做捕获
skipSeconds = 0;

% IQ 参数
iqOrder = 'IQ';                 % 'IQ' 或 'QI'
conjugateIQ = false;            % 频谱翻转时才改 true

% 统一残余多普勒范围。
% 各信号的步长不同：1 ms 信号 200 Hz；4 ms Galileo 100 Hz；
% 10 ms B1C/NavIC 50 Hz，避免长相干积分的频偏失配损失。
dopplerMin = -10e3;
dopplerMax =  10e3;

% 主峰 / 次峰经验判决门限，与现有脚本保持同一口径。
peakRatioThreshold = 2.0;

% 是否重建每个星座最强候选的三维捕获面。
% 全星座第一次跑建议 false；需要看三维图时再改 true。
plotAcquisitionSurfaces = false;
plotFloorDb = -35;
maxPlotCodePoints = 3000;

% -------------------------------------------------------------------------
% 需要搜索哪些信号。
% 第一次调试可只留一两个，例如：searchKeys = ["GPS_L1CA","GALILEO_E1C"];
% -------------------------------------------------------------------------
searchKeys = [ ...
    "GPS_L1CA", ...
    "BDS_B1C", ...
    "BDS_B1I", ...
    "SBAS_L1", ...
    "GALILEO_E1C", ...
    "QZSS_L1CA", ...
    "QZSS_L1CB", ...
    "NAVIC_L1", ...
    "GLONASS_L1OF" ...
];

% 各信号默认非相干累加块数。
% 1 ms 信号可以多积累；长码先使用较小块数，避免一次全星座搜索过慢。
blocksGps   = 15;   % 10 x 1 ms
blocksSbas  = 15;   % 10 x 1 ms
blocksQzss  = 15;   % 10 x 1 ms
blocksB1I   = 15;   % 10 x 1 ms
blocksB1C   = 5;    % 1 x 10 ms
blocksGal   = 5;    % 2 x 4 ms
blocksNavic = 5;    % 1 x 10 ms
blocksGlo   = 15;   % 10 x 1 ms

%% ========================================================================
%  2. 建立统一信号配置
% =========================================================================

specs = buildSignalSpecs(dopplerMin, dopplerMax, ...
                         blocksGps, blocksSbas, blocksQzss, blocksB1I, ...
                         blocksB1C, blocksGal, blocksNavic, blocksGlo);

config = struct();
config.iqFile = iqFile;
config.rawFs = rawFs;
config.captureCenterFrequency = captureCenterFrequency;
config.captureBandwidth = captureBandwidth;
config.skipSeconds = skipSeconds;
config.iqOrder = iqOrder;
config.conjugateIQ = conjugateIQ;
config.peakRatioThreshold = peakRatioThreshold;
config.searchKeys = searchKeys;

fprintf('============================================================\n');
fprintf('Multi-GNSS L1/E1/B1 PCPS Acquisition\n');
fprintf('============================================================\n');
fprintf('Input file             : %s\n', iqFile);
fprintf('Sample rate            : %.3f MHz\n', rawFs / 1e6);
fprintf('Capture center         : %.5f MHz\n', captureCenterFrequency / 1e6);
fprintf('Configured RF bandwidth: %.3f MHz\n', captureBandwidth / 1e6);
fprintf('Complex baseband span  : %+.3f ... %+.3f MHz\n', ...
        -rawFs/2/1e6, rawFs/2/1e6);
fprintf('Start offset           : %.3f s\n', skipSeconds);
fprintf('Peak ratio threshold   : %.2f\n', peakRatioThreshold);
fprintf('============================================================\n\n');

if ~isfile(iqFile)
    error('IQ 文件不存在：%s', iqFile);
end

%% ========================================================================
%  3. 依次执行各星座捕获
% =========================================================================

allRows = struct([]);
allChannelTemplates = struct([]);

for specIndex = 1:numel(specs)

    spec = specs{specIndex};

    if ~any(searchKeys == spec.key)
        continue;
    end

    fprintf('\n============================================================\n');
    fprintf('%s | %s\n', spec.system, spec.signal);
    fprintf('============================================================\n');

    if strcmp(spec.key, 'GLONASS_L1OF')
        [rows, channels] = acquireGlonassL1OF(iqFile, rawFs, ...
            captureCenterFrequency, captureBandwidth, skipSeconds, ...
            iqOrder, conjugateIQ, peakRatioThreshold, spec, ...
            plotAcquisitionSurfaces, plotFloorDb, maxPlotCodePoints);
    else
        [inside, nominalIF] = carrierInsideCapture(spec.rfHz, ...
            captureCenterFrequency, captureBandwidth, rawFs);

        if ~inside
            fprintf('SKIPPED: nominal carrier %+.6f MHz is outside the captured band.\n', ...
                    nominalIF / 1e6);
            rows = makeSkippedRows(spec, nominalIF, 'OUT_OF_CAPTURE_BAND');
            channels = struct([]);
        else
            if strcmp(spec.key, 'BDS_B1I')
                edgeDistance = captureBandwidth/2 - abs(nominalIF);
                fprintf(['WARNING: BDS B1I nominal IF = %+.3f MHz, only %.3f MHz from ' ...
                         'the configured RF-band edge.\n'], ...
                        nominalIF/1e6, edgeDistance/1e6);
                fprintf(['         Carrier center is observable, but part of the B1I spectrum ' ...
                         'can be attenuated/clipped by the front-end filter.\n']);
            end

            try
                [rows, channels] = acquireOneCdmaSignal(iqFile, rawFs, ...
                    captureCenterFrequency, skipSeconds, iqOrder, conjugateIQ, ...
                    peakRatioThreshold, spec, plotAcquisitionSurfaces, ...
                    plotFloorDb, maxPlotCodePoints);
            catch ME
                fprintf(2, 'SKIPPED because this signal branch failed: %s\n', ME.message);
                rows = makeSkippedRows(spec, nominalIF, ['ERROR: ' ME.message]);
                channels = struct([]);
            end
        end
    end

    allRows = appendStructArray(allRows, rows);
    allChannelTemplates = appendStructArray(allChannelTemplates, channels);
end

%% ========================================================================
%  4. 汇总、排序、保存结果
% =========================================================================

if isempty(allRows)
    error('没有产生任何捕获候选，请检查 searchKeys。');
end

results = struct2table(allRows);

% 先把真正完成搜索的候选排在前面，再按 PeakRatio 从高到低排序。
completed = results.Status == "SEARCHED";
results.SearchCompleted = completed;
results = sortrows(results, {'SearchCompleted','PeakRatio'}, {'descend','descend'});

fprintf('\n\n============================================================\n');
fprintf('Final Multi-GNSS L1 acquisition result\n');
fprintf('============================================================\n');
disp(results(:, {'System','Signal','PRN','Channel','Nominal_RF_MHz', ...
                 'Doppler_Hz','CodePhase_Chips','PeakRatio','Detected','Status'}));

numDetected = sum(results.Detected);
fprintf('Detected / searched candidates: %d / %d\n', ...
        numDetected, sum(results.SearchCompleted));

if numDetected > 0
    fprintf('\nDetected list:\n');
    detectedRows = results(results.Detected, :);
    for k = 1:height(detectedRows)
        if isnan(detectedRows.Channel(k))
            fprintf('  %-10s | %-18s | PRN %3d | Doppler %+7.0f Hz | Metric %.3f\n', ...
                detectedRows.System(k), detectedRows.Signal(k), ...
                detectedRows.PRN(k), detectedRows.Doppler_Hz(k), ...
                detectedRows.PeakRatio(k));
        else
            fprintf('  %-10s | %-18s | CH %+3d | Doppler %+7.0f Hz | Metric %.3f\n', ...
                detectedRows.System(k), detectedRows.Signal(k), ...
                detectedRows.Channel(k), detectedRows.Doppler_Hz(k), ...
                detectedRows.PeakRatio(k));
        end
    end
end

% 只保留真正检测到的通道模板，供跟踪脚本直接加载。
trackingChannels = struct([]);
for k = 1:numel(allChannelTemplates)
    if allChannelTemplates(k).Detected
        trackingChannels = appendStructArray(trackingChannels, allChannelTemplates(k));
    end
end

outputMat = fullfile(fileparts(mfilename('fullpath')), ...
                     'MultiGNSS_L1_Acquisition_Result.mat');
save(outputMat, 'results', 'trackingChannels', 'config', '-v7.3');

fprintf('\nAcquisition MAT saved to:\n  %s\n', outputMat);
fprintf('Detected tracking channels saved: %d\n', numel(trackingChannels));
fprintf('Next step: run MultiGNSS_L1_Tracking.m\n');

%% ========================================================================
%  本地函数 1：建立信号配置
% =========================================================================
function specs = buildSignalSpecs(dMin, dMax, ...
                                  blocksGps, blocksSbas, blocksQzss, blocksB1I, ...
                                  blocksB1C, blocksGal, blocksNavic, blocksGlo)

    specs = {};

    specs{end+1} = makeSpec('GPS_L1CA', 'GPS', 'L1 C/A', ...
        1575.42e6, 1.023e6, 1023, 1e-3, 1:32, ...
        4.092e6, dMin, dMax, 200, blocksGps, 'BPSK', 'GPS_CA', ...
        1e-3, 0.50, 'GPS legacy L1 C/A');

    specs{end+1} = makeSpec('BDS_B1C', 'BDS', 'B1C Pilot-A', ...
        1575.42e6, 1.023e6, 10230, 10e-3, 1:63, ...
        8.184e6, dMin, dMax, 50, blocksB1C, 'BOC11', 'BDS_B1C_PILOT', ...
        10e-3, 0.20, 'Pilot-A = B1C pilot primary code x BOC(1,1)');

    specs{end+1} = makeSpec('BDS_B1I', 'BDS', 'B1I', ...
        1561.098e6, 2.046e6, 2046, 1e-3, 1:63, ...
        8.184e6, dMin, dMax, 200, blocksB1I, 'BPSK', 'BDS_B1I', ...
        1e-3, 0.50, 'Shift -14.322 MHz to zero before resampling');

    specs{end+1} = makeSpec('SBAS_L1', 'SBAS', 'L1 C/A', ...
        1575.42e6, 1.023e6, 1023, 1e-3, 120:158, ...
        4.092e6, dMin, dMax, 200, blocksSbas, 'BPSK', 'SBAS_CA', ...
        1e-3, 0.50, 'SBAS PRN 120~158');

    specs{end+1} = makeSpec('GALILEO_E1C', 'GALILEO', 'E1-C Pilot', ...
        1575.42e6, 1.023e6, 4092, 4e-3, 1:50, ...
        8.184e6, dMin, dMax, 100, blocksGal, 'BOC11', 'GALILEO_E1C', ...
        4e-3, 0.20, 'E1-C primary x sinBOC(1,1); secondary code ignored by Costas tracking');

    specs{end+1} = makeSpec('QZSS_L1CA', 'QZSS', 'L1 C/A', ...
        1575.42e6, 1.023e6, 1023, 1e-3, [193:197, 199:201], ...
        4.092e6, dMin, dMax, 200, blocksQzss, 'BPSK', 'QZSS_CA', ...
        1e-3, 0.50, 'QZSS L1 C/A standard code candidates; non-standard PRN 198/202 excluded');

    specs{end+1} = makeSpec('QZSS_L1CB', 'QZSS', 'L1 C/B', ...
        1575.42e6, 1.023e6, 1023, 1e-3, 203:206, ...
        4.092e6, dMin, dMax, 200, blocksQzss, 'BPSK', 'QZSS_CA', ...
        1e-3, 0.50, 'QZSS L1 C/B uses C/A-code family with dedicated PRNs');

    specs{end+1} = makeSpec('NAVIC_L1', 'NAVIC', 'L1 SPS Data', ...
        1575.42e6, 1.023e6, 10230, 10e-3, 1:64, ...
        8.184e6, dMin, dMax, 50, blocksNavic, 'BOC11', 'NAVIC_L1_DATA', ...
        10e-3, 0.20, 'IZ4 data primary code x sinBOC(1,1); no overlay on data channel');

    % GLONASS 的 rfHz 在各 FDMA channel 中变化，此处只保存中心配置。
    specs{end+1} = makeSpec('GLONASS_L1OF', 'GLONASS', 'L1OF', ...
        1602.0e6, 0.511e6, 511, 1e-3, -7:6, ...
        2.044e6, dMin, dMax, 200, blocksGlo, 'BPSK', 'GLONASS_CA', ...
        1e-3, 0.50, 'FDMA: f=1602 MHz + k*0.5625 MHz, k=-7..+6');
end

function spec = makeSpec(key, system, signal, rfHz, codeRate, codeLength, ...
                         codePeriod, prnList, acqFs, dMin, dMax, dStep, ...
                         blocks, modulation, generatorKey, trackT, dllSpacing, note)
    spec = struct();
    spec.key = string(key);
    spec.system = string(system);
    spec.signal = string(signal);
    spec.rfHz = rfHz;
    spec.codeRate = codeRate;
    spec.codeLength = codeLength;
    spec.codePeriod = codePeriod;
    spec.prnList = prnList;
    spec.acqFs = acqFs;
    spec.dopplerMin = dMin;
    spec.dopplerMax = dMax;
    spec.dopplerStep = dStep;
    spec.noncoherentBlocks = blocks;
    spec.modulation = string(modulation);
    spec.generatorKey = string(generatorKey);
    spec.trackingIntegration = trackT;
    spec.dllSpacing = dllSpacing;
    spec.note = string(note);
end

%% ========================================================================
%  本地函数 2：通用 CDMA PCPS 捕获
% =========================================================================
function [rows, channels] = acquireOneCdmaSignal(iqFile, rawFs, captureCenter, ...
        skipSeconds, iqOrder, conjugateIQ, threshold, spec, ...
        doPlot, plotFloorDb, maxPlotCodePoints)

    nominalIF = spec.rfHz - captureCenter;
    samplesPerCode = round(spec.acqFs * spec.codePeriod);
    samplesPerChip = spec.acqFs / spec.codeRate;
    numBlocks = spec.noncoherentBlocks;
    numNeeded = numBlocks * samplesPerCode;

    fprintf('Nominal RF             : %.6f MHz\n', spec.rfHz/1e6);
    fprintf('Nominal digital IF     : %+.6f MHz\n', nominalIF/1e6);
    fprintf('Acquisition Fs         : %.3f MHz\n', spec.acqFs/1e6);
    fprintf('Code rate              : %.3f Mcps\n', spec.codeRate/1e6);
    fprintf('Code length / period   : %d chips / %.3f ms\n', ...
        spec.codeLength, spec.codePeriod*1e3);
    fprintf('Doppler                : %+g ... %+g Hz, step %.0f Hz\n', ...
        spec.dopplerMin, spec.dopplerMax, spec.dopplerStep);
    fprintf('Noncoherent blocks     : %d x %.3f ms\n', ...
        numBlocks, spec.codePeriod*1e3);

    rawDuration = numBlocks * spec.codePeriod + 2e-3;
    signalRaw = readSc8IQSegment(iqFile, rawFs, skipSeconds, rawDuration, ...
                                 iqOrder, conjugateIQ);

    % 先把该信号的标称数字中频搬到零频，再重采样。
    nRaw = (0:length(signalRaw)-1).';
    if abs(nominalIF) > 1
        signalRaw = signalRaw .* exp(-1j * 2*pi * nominalIF * nRaw / rawFs);
    end
    signalRaw = signalRaw - mean(signalRaw);

    if abs(spec.acqFs - rawFs) > 1
        [p, q] = rat(spec.acqFs / rawFs, 1e-12);
        fprintf('Front-end resample     : %.3f -> %.3f MHz (%d/%d)\n', ...
            rawFs/1e6, spec.acqFs/1e6, p, q);
        signal = resample(signalRaw, p, q);
    else
        signal = signalRaw;
    end
    clear signalRaw;

    if length(signal) < numNeeded
        error('重采样后的数据不足：需要 %d 点，只有 %d 点。', numNeeded, length(signal));
    end
    signal = signal(1:numNeeded);
    signal = signal - mean(signal);

    prnList = spec.prnList;
    numPRN = numel(prnList);
    t = (0:samplesPerCode-1) / spec.acqFs;
    chipPhase = t * spec.codeRate;

    fprintf('[1/3] Generating local codes and FFTs...\n');
    localFFTConj = complex(zeros(numPRN, samplesPerCode, 'single'));
    codeBank = cell(numPRN, 1);

    for pIndex = 1:numPRN
        prn = prnList(pIndex);
        primaryCode = getPrimaryCode(spec.generatorKey, prn);
        codeBank{pIndex} = single(primaryCode(:).');
        localReplica = sampleLocalReplica(primaryCode, chipPhase, spec.modulation);
        localFFTConj(pIndex, :) = conj(fft(single(localReplica)));

        if mod(pIndex, 10) == 0 || pIndex == numPRN
            fprintf('      generated %d / %d candidates\n', pIndex, numPRN);
        end
    end

    dopplerBins = spec.dopplerMin:spec.dopplerStep:spec.dopplerMax;
    numDoppler = numel(dopplerBins);

    bestPeak = -inf(numPRN, 1);
    bestDoppler = zeros(numPRN, 1);
    bestCodeSample = zeros(numPRN, 1);
    bestRowPower = zeros(numPRN, samplesPerCode, 'single');

    fprintf('[2/3] PCPS searching...\n');

    for dIndex = 1:numDoppler
        fd = dopplerBins(dIndex);
        carrier = single(exp(-1j * 2*pi * fd * t));
        powerAccum = zeros(numPRN, samplesPerCode, 'single');

        for blockIndex = 1:numBlocks
            firstSample = (blockIndex-1)*samplesPerCode + 1;
            lastSample = blockIndex*samplesPerCode;
            oneBlock = signal(firstSample:lastSample).';

            dataFFT = fft(single(oneBlock) .* carrier);
            correlation = ifft(localFFTConj .* dataFFT, [], 2);
            powerAccum = powerAccum + single(abs(correlation).^2);
        end

        [rowPeak, rowCodeIndex] = max(powerAccum, [], 2);
        improved = double(rowPeak) > bestPeak;
        idx = find(improved);
        for k = 1:numel(idx)
            ii = idx(k);
            bestPeak(ii) = double(rowPeak(ii));
            bestDoppler(ii) = fd;
            bestCodeSample(ii) = rowCodeIndex(ii) - 1;
            bestRowPower(ii, :) = powerAccum(ii, :);
        end

        if mod(dIndex, max(1, floor(numDoppler/10))) == 0 || dIndex == numDoppler
            fprintf('      Doppler %+7.0f Hz : %d / %d bins\n', fd, dIndex, numDoppler);
        end
    end

    clear signal correlation powerAccum carrier dataFFT localFFTConj;

    fprintf('[3/3] Computing peak-ratio decisions...\n');
    rows = repmat(makeEmptyResultRow(), numPRN, 1);
    channels = struct([]);
    exclusionSamples = ceil(samplesPerChip);
    allIndices = 1:samplesPerCode;

    for pIndex = 1:numPRN
        codeIndex = bestCodeSample(pIndex) + 1;
        distance = abs(allIndices - codeIndex);
        circularDistance = min(distance, samplesPerCode-distance);
        valid = circularDistance > exclusionSamples;
        secondPeak = max(bestRowPower(pIndex, valid));
        metric = bestPeak(pIndex) / max(double(secondPeak), eps);
        detected = metric >= threshold;
        codeChips = bestCodeSample(pIndex) * spec.codeRate / spec.acqFs;
        codeSeconds = bestCodeSample(pIndex) / spec.acqFs;

        rows(pIndex) = fillResultRow(spec, prnList(pIndex), NaN, nominalIF, ...
            bestDoppler(pIndex), bestCodeSample(pIndex), codeChips, codeSeconds, ...
            metric, detected, 'SEARCHED', spec.note);

        if detected
            ch = makeTrackingChannel(spec, prnList(pIndex), NaN, ...
                codeBank{pIndex}, nominalIF, bestDoppler(pIndex), ...
                codeSeconds, metric, skipSeconds);
            channels = appendStructArray(channels, ch);
        end
    end

    [~, strongestIndex] = max(bestPeak);
    fprintf('Strongest candidate    : PRN %d, Doppler %+0.0f Hz, Metric %.3f\n', ...
        prnList(strongestIndex), bestDoppler(strongestIndex), ...
        rows(strongestIndex).PeakRatio);

    if doPlot
        rebuildAndPlot3D(iqFile, rawFs, captureCenter, skipSeconds, iqOrder, ...
            conjugateIQ, spec, prnList(strongestIndex), bestDoppler(strongestIndex), ...
            plotFloorDb, maxPlotCodePoints);
    end
end

%% ========================================================================
%  本地函数 3：GLONASS L1OF FDMA 捕获
% =========================================================================
function [rows, channels] = acquireGlonassL1OF(iqFile, rawFs, captureCenter, ...
        captureBandwidth, skipSeconds, iqOrder, conjugateIQ, threshold, spec, ...
        doPlot, plotFloorDb, maxPlotCodePoints)

    rows = struct([]);
    channels = struct([]);

    for channel = -7:6
        thisSpec = spec;
        thisSpec.rfHz = 1602.0e6 + channel * 0.5625e6;
        thisSpec.prnList = channel;
        thisSpec.note = "GLONASS L1OF FDMA channel k=" + string(channel);

        [inside, nominalIF] = carrierInsideCapture(thisSpec.rfHz, ...
            captureCenter, captureBandwidth, rawFs);

        if ~inside
            oneRow = fillResultRow(thisSpec, channel, channel, nominalIF, ...
                NaN, NaN, NaN, NaN, NaN, false, ...
                'OUT_OF_CAPTURE_BAND', thisSpec.note);
            rows = appendStructArray(rows, oneRow);
            fprintf('Channel %+2d | RF %.6f MHz | IF %+.3f MHz | OUT OF BAND\n', ...
                    channel, thisSpec.rfHz/1e6, nominalIF/1e6);
            continue;
        end

        fprintf('\nGLONASS channel %+d, RF %.6f MHz\n', channel, thisSpec.rfHz/1e6);
        [oneRows, oneChannels] = acquireOneCdmaSignal(iqFile, rawFs, ...
            captureCenter, skipSeconds, iqOrder, conjugateIQ, threshold, ...
            thisSpec, doPlot, plotFloorDb, maxPlotCodePoints);

        oneRows.Channel = channel;
        rows = appendStructArray(rows, oneRows);
        if ~isempty(oneChannels)
            oneChannels.Channel = channel;
            channels = appendStructArray(channels, oneChannels);
        end
    end
end

%% ========================================================================
%  本地函数 4：读取 B210 sc8 IQ
% =========================================================================
function signal = readSc8IQSegment(iqFile, fs, startSeconds, durationSeconds, ...
                                   iqOrder, conjugateIQ)

    numComplex = ceil(durationSeconds * fs);
    fid = fopen(iqFile, 'rb');
    if fid < 0
        error('无法打开 IQ 文件：%s', iqFile);
    end

    byteOffset = round(startSeconds * fs) * 2;
    status = fseek(fid, byteOffset, 'bof');
    if status ~= 0
        fclose(fid);
        error('无法跳转到 %.6f s，请检查文件大小。', startSeconds);
    end

    raw = fread(fid, 2*numComplex, 'int8=>double');
    fclose(fid);

    if numel(raw) < 2*numComplex
        error('IQ 文件剩余数据不足：请求 %.3f ms。', durationSeconds*1e3);
    end

    switch upper(iqOrder)
        case 'IQ'
            I = raw(1:2:end);
            Q = raw(2:2:end);
        case 'QI'
            Q = raw(1:2:end);
            I = raw(2:2:end);
        otherwise
            error('iqOrder 只能是 ''IQ'' 或 ''QI''。');
    end

    signal = complex(I, Q) / 128.0;
    if conjugateIQ
        signal = conj(signal);
    end
    signal = signal - mean(signal);
end

%% ========================================================================
%  本地函数 5：本地复制信号采样
% =========================================================================
function replica = sampleLocalReplica(primaryCode, chipPhase, modulation)
    codeLength = numel(primaryCode);
    chipIndex = mod(floor(chipPhase), codeLength) + 1;
    replica = double(primaryCode(chipIndex));

    if strcmpi(modulation, 'BOC11')
        % sinBOC(1,1)：每 0.5 chip 翻转一次，t=0+ 定义为 +1。
        subcarrier = 1 - 2 * mod(floor(2*chipPhase), 2);
        replica = replica .* subcarrier;
    end
end

%% ========================================================================
%  本地函数 6：按信号类型生成 1-chip/sample 主码
% =========================================================================
function code = getPrimaryCode(generatorKey, prn)
    switch char(generatorKey)
        case 'GPS_CA'
            code = generateGpsCaCode(prn);
        case 'SBAS_CA'
            code = generateSbasL1CaCode(prn);
        case 'QZSS_CA'
            code = generateQzssL1CaCode(prn);
        case 'BDS_B1I'
            code = generateBdsB1ICode(prn);
        case 'BDS_B1C_PILOT'
            code = generateB1CPilotPrimaryCode(prn);
        case 'GALILEO_E1C'
            code = generateGalileoE1CPrimaryCode(prn);
        case 'NAVIC_L1_DATA'
            code = generateNavicL1DataPrimaryCode(prn);
        case 'GLONASS_CA'
            code = generateGlonassCaCode();
        otherwise
            error('未知本地码生成器：%s', generatorKey);
    end
    code = double(code(:).');
end

%% ========================================================================
%  本地函数 7：结果与跟踪通道结构
% =========================================================================
function row = makeEmptyResultRow()
    row = struct('System', "", 'Signal', "", 'PRN', NaN, 'Channel', NaN, ...
        'Nominal_RF_MHz', NaN, 'Nominal_IF_MHz', NaN, 'AcqFs_MHz', NaN, ...
        'Doppler_Hz', NaN, 'Estimated_RF_MHz', NaN, ...
        'CodePhase_Samples_Acq', NaN, 'CodePhase_Chips', NaN, ...
        'CodePhase_Seconds', NaN, 'PeakRatio', NaN, 'Detected', false, ...
        'Trackable', false, 'Status', "", 'Note', "");
end

function row = fillResultRow(spec, prn, channel, nominalIF, doppler, ...
        codeSample, codeChips, codeSeconds, metric, detected, status, note)

    row = makeEmptyResultRow();
    row.System = spec.system;
    row.Signal = spec.signal;
    row.PRN = prn;
    row.Channel = channel;
    row.Nominal_RF_MHz = spec.rfHz/1e6;
    row.Nominal_IF_MHz = nominalIF/1e6;
    row.AcqFs_MHz = spec.acqFs/1e6;
    row.Doppler_Hz = doppler;
    if isfinite(doppler)
        row.Estimated_RF_MHz = (spec.rfHz + doppler)/1e6;
    end
    row.CodePhase_Samples_Acq = codeSample;
    row.CodePhase_Chips = codeChips;
    row.CodePhase_Seconds = codeSeconds;
    row.PeakRatio = metric;
    row.Detected = logical(detected);
    row.Trackable = logical(detected) && strcmp(status, 'SEARCHED');
    row.Status = string(status);
    row.Note = string(note);
end

function rows = makeSkippedRows(spec, nominalIF, status)
    rows = repmat(makeEmptyResultRow(), numel(spec.prnList), 1);
    for k = 1:numel(spec.prnList)
        rows(k) = fillResultRow(spec, spec.prnList(k), NaN, nominalIF, ...
            NaN, NaN, NaN, NaN, NaN, false, status, spec.note);
    end
end

function ch = makeTrackingChannel(spec, prn, channel, primaryCode, nominalIF, ...
                                  doppler, codeSeconds, metric, skipSeconds)
    ch = struct();
    ch.System = spec.system;
    ch.Signal = spec.signal;
    ch.PRN = prn;
    ch.Channel = channel;
    ch.RF_Hz = spec.rfHz;
    ch.NominalIF_Hz = nominalIF;
    ch.Doppler_Hz = doppler;
    ch.CodeRate_Hz = spec.codeRate;
    ch.CodeLength = spec.codeLength;
    ch.CodePeriod_s = spec.codePeriod;
    ch.Modulation = spec.modulation;
    ch.PrimaryCodeChips = int8(primaryCode);
    ch.CodePhase_Seconds = codeSeconds;
    ch.AcquisitionSkipSeconds = skipSeconds;
    ch.TrackingIntegration_s = spec.trackingIntegration;
    ch.DllSpacing_Chips = spec.dllSpacing;
    ch.PeakRatio = metric;
    ch.Detected = true;
end

function out = appendStructArray(a, b)
    if isempty(b)
        out = a;
    elseif isempty(a)
        out = b;
    else
        out = [a(:); b(:)];
    end
end

%% ========================================================================
%  本地函数 8：采集带宽判定
% =========================================================================
function [inside, nominalIF] = carrierInsideCapture(rfHz, centerHz, bwHz, fs)
    nominalIF = rfHz - centerHz;
    halfUsable = min(bwHz/2, fs/2);
    inside = abs(nominalIF) <= halfUsable;
end

%% ========================================================================
%  本地函数 9：可选重建三维图
% =========================================================================
function rebuildAndPlot3D(iqFile, rawFs, captureCenter, skipSeconds, iqOrder, ...
        conjugateIQ, spec, prn, bestDoppler, plotFloorDb, maxPlotCodePoints)

    nominalIF = spec.rfHz - captureCenter;
    samplesPerCode = round(spec.acqFs * spec.codePeriod);
    numNeeded = spec.noncoherentBlocks * samplesPerCode;
    rawDuration = spec.noncoherentBlocks * spec.codePeriod + 2e-3;

    signalRaw = readSc8IQSegment(iqFile, rawFs, skipSeconds, rawDuration, ...
                                 iqOrder, conjugateIQ);
    nRaw = (0:length(signalRaw)-1).';
    if abs(nominalIF) > 1
        signalRaw = signalRaw .* exp(-1j*2*pi*nominalIF*nRaw/rawFs);
    end
    if abs(spec.acqFs-rawFs) > 1
        [p,q] = rat(spec.acqFs/rawFs, 1e-12);
        signal = resample(signalRaw, p, q);
    else
        signal = signalRaw;
    end
    signal = signal(1:numNeeded);
    signal = signal - mean(signal);

    t = (0:samplesPerCode-1)/spec.acqFs;
    chipPhase = t*spec.codeRate;
    code = getPrimaryCode(spec.generatorKey, prn);
    local = sampleLocalReplica(code, chipPhase, spec.modulation);
    localFFT = conj(fft(single(local)));

    dopplerBins = spec.dopplerMin:spec.dopplerStep:spec.dopplerMax;
    decim = max(1, ceil(samplesPerCode/maxPlotCodePoints));
    plotIdx = 1:decim:samplesPerCode;
    plotMap = zeros(numel(dopplerBins), numel(plotIdx), 'single');

    for d = 1:numel(dopplerBins)
        carrier = single(exp(-1j*2*pi*dopplerBins(d)*t));
        rowPower = zeros(1, samplesPerCode, 'single');
        for b = 1:spec.noncoherentBlocks
            idx = (b-1)*samplesPerCode + (1:samplesPerCode);
            dataFFT = fft(single(signal(idx).') .* carrier);
            corr = ifft(dataFFT .* localFFT);
            rowPower = rowPower + single(abs(corr).^2);
        end
        plotMap(d,:) = rowPower(plotIdx);
    end

    mapDb = 10*log10(double(plotMap)/max(double(plotMap(:))) + eps);
    mapDb(mapDb < plotFloorDb) = plotFloorDb;
    codeChips = (plotIdx-1)*spec.codeRate/spec.acqFs;

    figure('Name', sprintf('%s %s PRN %d', spec.system, spec.signal, prn), ...
           'NumberTitle', 'off');
    surf(codeChips, dopplerBins/1e3, mapDb, 'EdgeColor', 'none');
    xlabel('Code phase (chips)');
    ylabel('Residual Doppler (kHz)');
    zlabel('Normalized correlation power (dB)');
    title(sprintf('%s %s | PRN %d | strongest Doppler %+0.0f Hz', ...
          spec.system, spec.signal, prn, bestDoppler));
    grid on; axis tight; view(45,55); colorbar;
end

%% ========================================================================
%  本地函数 10：GPS L1 C/A PRN 1~32
% =========================================================================
function caCode = generateGpsCaCode(prn)

    % GPS L1 C/A PRN 1~32 对应的 G2 两个抽头。
    %
    % 每一行：
    %       [tap1, tap2]
    g2TapTable = [ ...
         2,  6;   % PRN  1
         3,  7;   % PRN  2
         4,  8;   % PRN  3
         5,  9;   % PRN  4
         1,  9;   % PRN  5
         2, 10;   % PRN  6
         1,  8;   % PRN  7
         2,  9;   % PRN  8
         3, 10;   % PRN  9
         2,  3;   % PRN 10
         3,  4;   % PRN 11
         5,  6;   % PRN 12
         6,  7;   % PRN 13
         7,  8;   % PRN 14
         8,  9;   % PRN 15
         9, 10;   % PRN 16
         1,  4;   % PRN 17
         2,  5;   % PRN 18
         3,  6;   % PRN 19
         4,  7;   % PRN 20
         5,  8;   % PRN 21
         6,  9;   % PRN 22
         1,  3;   % PRN 23
         4,  6;   % PRN 24
         5,  7;   % PRN 25
         6,  8;   % PRN 26
         7,  9;   % PRN 27
         8, 10;   % PRN 28
         1,  6;   % PRN 29
         2,  7;   % PRN 30
         3,  8;   % PRN 31
         4,  9];  % PRN 32

    if prn < 1 || prn > 32
        error('本程序当前只支持 GPS L1 C/A PRN 1~32。');
    end

    % G1、G2 两个 10 级移位寄存器初始状态全部为 1。
    g1 = ones(1, 10);
    g2 = ones(1, 10);

    caCodeBinary = zeros(1, 1023);

    tap1 = g2TapTable(prn, 1);
    tap2 = g2TapTable(prn, 2);

    for chipIndex = 1:1023

        % G1 输出为第 10 级。
        g1Output = g1(10);

        % PRN-specific G2 输出由两个指定 tap 模 2 相加。
        g2Output = mod(g2(tap1) + g2(tap2), 2);

        % C/A chip = G1 XOR G2。
        caCodeBinary(chipIndex) = mod(g1Output + g2Output, 2);

        % G1 反馈多项式：
        %       x^10 + x^3 + 1
        g1Feedback = mod(g1(3) + g1(10), 2);

        % G2 反馈多项式：
        %       x^10 + x^9 + x^8 + x^6 + x^3 + x^2 + 1
        g2Feedback = mod(g2(2) + ...
                         g2(3) + ...
                         g2(6) + ...
                         g2(8) + ...
                         g2(9) + ...
                         g2(10), 2);

        % 移位。
        g1(2:10) = g1(1:9);
        g1(1) = g1Feedback;

        g2(2:10) = g2(1:9);
        g2(1) = g2Feedback;
    end

    % 二进制 0/1 转为 BPSK +1/-1。
    %
    % 0 -> +1
    % 1 -> -1
    caCode = 1 - 2 * caCodeBinary;
end

%% ========================================================================
%  本地函数 11：通用延迟式 GPS C/A 码族（供 SBAS/QZSS 使用）
% =========================================================================
function caCode = generateCaCodeFromG2Delay(g2Delay)
    g1 = ones(1,10);
    g2 = ones(1,10);
    g1Seq = zeros(1,1023);
    g2Seq = zeros(1,1023);

    for i = 1:1023
        g1Seq(i) = g1(10);
        g2Seq(i) = g2(10);
        g1Feedback = xor(g1(3), g1(10));
        g2Feedback = xor(g2(2), g2(3));
        g2Feedback = xor(g2Feedback, g2(6));
        g2Feedback = xor(g2Feedback, g2(8));
        g2Feedback = xor(g2Feedback, g2(9));
        g2Feedback = xor(g2Feedback, g2(10));
        g1(2:10) = g1(1:9); g1(1) = g1Feedback;
        g2(2:10) = g2(1:9); g2(1) = g2Feedback;
    end

    g2Delayed = circshift(g2Seq, [0,g2Delay]);
    codeBinary = xor(logical(g1Seq), logical(g2Delayed));
    caCode = 1 - 2*double(codeBinary);
end

function caCode = generateSbasL1CaCode(prn)
    caCode = generateCaCodeFromG2Delay(getSbasL1G2Delay(prn));
end

function d = getSbasL1G2Delay(prn)
    delayTable = [ ...
        120 145; 121 175; 122 52; 123 21; 124 237; 125 235; 126 886; ...
        127 657; 128 634; 129 762; 130 355; 131 1012; 132 176; 133 603; ...
        134 130; 135 359; 136 595; 137 68; 138 386; 139 797; 140 456; ...
        141 499; 142 883; 143 307; 144 127; 145 211; 146 121; 147 118; ...
        148 163; 149 628; 150 853; 151 484; 152 289; 153 811; 154 202; ...
        155 1021; 156 463; 157 568; 158 904];
    row = find(delayTable(:,1)==prn,1);
    if isempty(row); error('SBAS PRN %d 不在 120~158。',prn); end
    d = delayTable(row,2);
end

function caCode = generateQzssL1CaCode(prn)
    % IS-QZSS-PNT-006 Table 3.2.2-1
    delayTable = [ ...
        193 339; 194 208; 195 711; 196 189; 197 263; 198 537; ...
        199 663; 200 942; 201 173; 202 900; ...
        203 30; 204 500; 205 935; 206 556];
    row = find(delayTable(:,1)==prn,1);
    if isempty(row); error('QZSS PRN %d 未配置 C/A-family G2 delay。',prn); end
    caCode = generateCaCodeFromG2Delay(delayTable(row,2));
end

%% ========================================================================
%  本地函数 12：GLONASS L1OF 511-chip standard code
% =========================================================================
function caCode = generateGlonassCaCode()
    % 9-stage LFSR, initial 111111111, polynomial 1+x^5+x^9.
    % Standard code output is taken from stage 7.
    reg = ones(1,9);
    bits = zeros(1,511);
    for k = 1:511
        bits(k) = reg(7);
        feedback = xor(reg(5), reg(9));
        reg(2:9) = reg(1:8);
        reg(1) = feedback;
    end
    caCode = 1 - 2*bits;
end

%% ========================================================================
%  本地函数 13：BDS B1I PRN 1~63
% =========================================================================
function b1iCode = generateBdsB1ICode(prn)

    if prn < 1 || prn > 63 || prn ~= floor(prn)
        error('B1I PRN 必须为 1~63 的整数。');
    end

    % ---------------------------------------------------------------------
    % BDS-SIS-ICD-B1I-3.0 Table 4-1：G2 phase selection taps
    % 每行最多 3 个抽头；0 表示该 PRN 只使用两个抽头。
    % ---------------------------------------------------------------------
    tapTable = [ ...
         1  3  0;  1  4  0;  1  5  0;  1  6  0;  1  8  0; ... %  1-5
         1  9  0;  1 10  0;  1 11  0;  2  7  0;  3  4  0; ... %  6-10
         3  5  0;  3  6  0;  3  8  0;  3  9  0;  3 10  0; ... % 11-15
         3 11  0;  4  5  0;  4  6  0;  4  8  0;  4  9  0; ... % 16-20
         4 10  0;  4 11  0;  5  6  0;  5  8  0;  5  9  0; ... % 21-25
         5 10  0;  5 11  0;  6  8  0;  6  9  0;  6 10  0; ... % 26-30
         6 11  0;  8  9  0;  8 10  0;  8 11  0;  9 10  0; ... % 31-35
         9 11  0; 10 11  0;  1  2  7;  1  3  4;  1  3  6; ... % 36-40
         1  3  8;  1  3 10;  1  3 11;  1  4  5;  1  4  9; ... % 41-45
         1  5  6;  1  5  8;  1  5 10;  1  5 11;  1  6  9; ... % 46-50
         1  8  9;  1  9 10;  1  9 11;  2  3  7;  2  5  7; ... % 51-55
         2  7  9;  3  4  5;  3  4  9;  3  5  6;  3  5  8; ... % 56-60
         3  5 10;  3  5 11;  3  6  9];                         % 61-63

    % ICD 初始状态：stage 1 -> stage 11
    g1 = [0 1 0 1 0 1 0 1 0 1 0];
    g2 = [0 1 0 1 0 1 0 1 0 1 0];

    % 2047-chip Gold 序列；最后截掉 1 chip -> 2046 chips
    goldBinary = zeros(1, 2047);
    taps = tapTable(prn, :);
    taps = taps(taps > 0);

    for chipIndex = 1:2047
        % G1 sequence 输出为 stage 11
        g1Output = g1(11);

        % G2 phase selection output = 指定 stages 的 modulo-2 sum
        g2Output = mod(sum(g2(taps)), 2);

        goldBinary(chipIndex) = mod(g1Output + g2Output, 2);

        % 多项式：
        % G1(X)=1+X+X^7+X^8+X^9+X^10+X^11
        g1Feedback = mod(g1(1) + g1(7) + g1(8) + ...
                         g1(9) + g1(10) + g1(11), 2);

        % G2(X)=1+X+X^2+X^3+X^4+X^5+X^8+X^9+X^11
        g2Feedback = mod(g2(1) + g2(2) + g2(3) + g2(4) + ...
                         g2(5) + g2(8) + g2(9) + g2(11), 2);

        % stage 1 -> stage 2 -> ... -> stage 11
        g1(2:11) = g1(1:10);
        g1(1) = g1Feedback;

        g2(2:11) = g2(1:10);
        g2(1) = g2Feedback;
    end

    % balanced Gold code truncated with the last one chip
    codeBinary = goldBinary(1:2046);

    % 0 -> +1, 1 -> -1；整体符号反转不影响捕获功率峰位置
    b1iCode = 1 - 2 * codeBinary;
end

%% ========================================================================
%  本地函数 14：BDS B1C Pilot primary code
% =========================================================================
function code = generateB1CPilotPrimaryCode(prn)

    if prn < 1 || prn > 63 || prn ~= floor(prn)
        error('B1C PRN 必须为 1~63 的整数。');
    end

    % BDS-SIS-ICD-B1C-1.0 Table 5-3
    % 列 1：phase difference w
    % 列 2：truncation point p
    pilotParams = [ ...
         796 7575;  156 2369; 4198 5688; 3941  539; 1374 2270; ...
        1338 7306; 1833 6457; 2521 6254; 3175 5644;  168 7119; ...
        2715 1402; 4408 5557; 3160 5764; 2796 1073;  459 7001; ...
        3594 5910; 4813 10060; 586 2710; 1428 1546; 2371 6887; ...
        2285 1883; 3377 5613; 4965 5062; 3779 1038; 4547 10170; ...
        1646 6484; 1430 1718;  607 2535; 2118 1158; 4709  526; ...
        1149 7331; 3283 5844; 2473 6423; 1006 6968; 3670 1280; ...
        1817 1838;  771 1989; 2173 6468;  740 2091; 1433 1581; ...
        2458 1453; 3459 6252; 2155 7122; 1205 7711;  413 7216; ...
         874 2113; 2463 1095; 1106 1628; 1590 1713; 3873 6102; ...
        4026 6123; 4272 6070; 3556 1115;  128 8047; 1200 6795; ...
         130 2575; 4494   53; 1871 1729; 3073 6388; 4386  682; ...
        4098 5565; 1923 7160; 1176 2277];

    w = pilotParams(prn, 1);
    p = pilotParams(prn, 2);

    N = 10243;
    N0 = 10230;

    % -------------------------------------------------------------
    % Legendre sequence L(k), k=0..10242
    % ICD 定义：
    %   L(0)=0
    %   k != 0 且 k 为模 N 的二次剩余 -> 1
    %   其他 -> 0
    % -------------------------------------------------------------
    L = zeros(1, N, 'uint8');
    x = 1:(N-1);
    quadraticResidues = mod(x.^2, N);
    L(quadraticResidues + 1) = 1;
    L(1) = 0;

    % Weil code W(k;w) = L(k) xor L((k+w) mod N)
    k = 0:(N-1);
    W = xor(L(k + 1), L(mod(k + w, N) + 1));

    % c(n;w;p) = W((n+p-1) mod N; w), n=0..10229
    n = 0:(N0-1);
    idx = mod(n + p - 1, N) + 1;
    codeBinary = double(W(idx));

    % 0 -> +1, 1 -> -1
    code = 1 - 2 * codeBinary;
end

%% ========================================================================
%  本地函数 15：Galileo E1-C primary memory code
% =========================================================================
function code = generateGalileoE1CPrimaryCode(prn)
    if prn < 1 || prn > 50 || prn ~= floor(prn)
        error('Galileo E1-C SVID 必须为 1~50。');
    end

    % ---------------------------------------------------------------------
    % Galileo E1-C 是 4092-chip memory code。
    % 本程序不再依赖 MATLAB R2026a 的 galileoCodes。
    % ---------------------------------------------------------------------
    baseDir = fileparts(mfilename('fullpath'));
    codeFile = fullfile(baseDir, 'Galileo_E1C_PrimaryCodes.mat');

    % 缓存不存在时，自动调用同目录的准备程序建立缓存。
    if exist(codeFile, 'file') ~= 2
        prepareFile = fullfile(baseDir, 'Prepare_Galileo_E1C_Codes.m');

        if exist(prepareFile, 'file') ~= 2
            error(['缺少 Galileo E1-C 本地码缓存，同时也找不到 ' ...
                   'Prepare_Galileo_E1C_Codes.m。']);
        end

        fprintf(['      Galileo E1-C cache not found.\n' ...
                 '      Building Galileo_E1C_PrimaryCodes.mat ...\n']);

        oldDir = pwd;
        try
            cd(baseDir);
            Prepare_Galileo_E1C_Codes(false);
            cd(oldDir);
        catch ME
            cd(oldDir);
            rethrow(ME);
        end
    end

    % 读取已经准备好的 4092 x 50 ±1 码表。
    S = load(codeFile, 'galileoE1CChips');

    if ~isfield(S, 'galileoE1CChips')
        error('Galileo_E1C_PrimaryCodes.mat 中缺少 galileoE1CChips。');
    end

    C = S.galileoE1CChips;

    if isequal(size(C), [4092, 50])
        code = double(C(:, prn)).';
    elseif isequal(size(C), [50, 4092])
        % 为兼容可能的旧缓存格式，允许转置布局。
        code = double(C(prn, :));
    else
        error(['galileoE1CChips 尺寸错误。\n' ...
               '应为 4092 x 50（或兼容的 50 x 4092），实际为 %d x %d。'], ...
               size(C, 1), size(C, 2));
    end

    % 兼容 0/1 缓存；新版 Prepare 直接保存 ±1。
    uniqueValues = unique(code);
    if all(ismember(uniqueValues, [0, 1]))
        code = 1 - 2 * code;
    end

    if length(code) ~= 4092 || ~all(abs(code) == 1)
        error('Galileo E1-C PRN %d 本地码内容异常。', prn);
    end
end

%% ========================================================================
%  本地函数 16：NavIC L1 SPS Data IZ4 primary code, PRN 1~64
% =========================================================================
function code = generateNavicL1DataPrimaryCode(prn)
    if prn < 1 || prn > 64 || prn ~= floor(prn)
        error('NavIC L1 PRN 必须为 1~64。');
    end

    persistent r0Oct r1Oct cInit validated
    if isempty(r0Oct)
        r0Oct = [ ...
"0061727026503255544";"1660130752435362260";"0676457016477551225";"1763467705267605701"; ...
"1614265052776007236";"1446113457553463523";"1467417471470124574";"0022513456555401603"; ...
"0004420115402210365";"0072276243316574510";"1632356715721616750";"1670164755420300763"; ...
"1752127524253360255";"0262220014044243135";"1476157654546440020";"1567545246612304745"; ...
"0341667641424721673";"0627234635353763045";"0422600144741165152";"1661124176724621030"; ...
"1225124173720602330";"1271773065617322065";"0611751161355750124";"0121046615341766266"; ...
"0337423707274604122";"0246610305446052270";"0427326063324033344";"1127467544162733403"; ...
"0772425336125565156";"1652465113031101044";"1737622607214524550";"1621315362240732407"; ...
"0171733204500613155";"1462031354327077565";"1141265411761074755";"0665106277260231251"; ...
"0573123144343776027";"0222101406610314705";"0140673225434336401";"0624233245727625631"; ...
"0224022145647544263";"0222501602610354705";"1370337660412244327";"0563567347256715524"; ...
"1407636661116077143";"1137431557133151004";"1113003456475500265";"1746553632646152413"; ...
"1465416631251321074";"0130516430377202712";"0762173527246302776";"1606732407336425136"; ...
"1131112010066741562";"1107467740060732403";"0755500241327076744";"1443037764170374631"; ...
"0243224434357700345";"0445504023027564357";"1211152271373271472";"0256644102553071753"; ...
"0733312314424771412";"1636376400221406415";"0574114621235461516";"1710717574016037362"];

        r1Oct = [ ...
"0377627103341647600";"0047555332635133703";"0570574070736102152";"0511013576745450615"; ...
"1216243446624447775";"0176452272675511054";"0151055342317137706";"1127720116046071664"; ...
"0514407436155575524";"0253070462740453542";"0573371306324706336";"1315135317732077306"; ...
"1170303027726635012";"1637171270537414673";"0342370520251732111";"0142423551056551362"; ...
"0641261355426453710";"0237176034757345266";"1205663360515365064";"0725000004121104102"; ...
"0337367500320303262";"1303374445022536530";"1033071464007363115";"0753124124237073577"; ...
"0133522075443754772";"1244212514312345145";"1066056211234322164";"0073115240113351010"; ...
"1102260031574577224";"1166703527236520553";"0056062273631723177";"0141517013160576212"; ...
"1644007677312431616";"0201757033615262622";"0357610362675720200";"1637504174727237065"; ...
"1510345507743707753";"0540160763721100120";"0406415410457500342";"0707515543554212732"; ...
"0140216674314371011";"0445414471314273300";"0120121661750263177";"0477301251340044262"; ...
"1157040657040363676";"1222265021477405004";"0314661556545362364";"0177320240371640542"; ...
"0735517310345570340";"1367565551220511432";"1274167141162675644";"1543641015130470077"; ...
"0640733734534576460";"0216312531021205434";"0050232164401566177";"0702636370401726111"; ...
"1733537351460015703";"1523265651140460620";"0607703231502460135";"1757246242710445777"; ...
"0464412467237572274";"1050617751566552643";"1041606123021052264";"1335441345250455042"];

        cInit = [ ...
"10100";"10100";"00110";"10100";"10100";"00110";"10100";"00110"; ...
"00110";"00110";"10100";"00110";"10100";"00110";"00110";"10100"; ...
"00110";"00110";"00110";"00110";"10100";"10100";"10100";"00110"; ...
"10100";"00110";"00110";"00110";"00110";"10100";"10100";"00110"; ...
"10100";"00110";"00110";"00110";"10100";"10100";"01100";"00110"; ...
"00011";"01100";"10100";"00110";"10100";"10100";"00110";"00110"; ...
"00110";"10100";"10100";"10100";"00110";"10100";"00110";"10100"; ...
"00110";"00110";"10100";"10010";"10001";"11000";"00110";"10100"];
        validated = false;
    end

    R0 = navicOctal55ToBits(r0Oct(prn));
    R1 = navicOctal55ToBits(r1Oct(prn));
    C = double(char(cInit(prn))) - double('0');

    bits = zeros(1,10230);
    for n = 1:10230
        bits(n) = xor(C(1), R1(1));

        r0fb = mod(R0(51)+R0(46)+R0(41)+R0(21)+R0(11)+R0(6)+R0(1),2);

        sigma2A = bitand(mod(R0(51)+R0(46)+R0(41),2), ...
                         mod(R0(21)+R0(11)+R0(6)+R0(1),2));
        sigma2B = xor(bitand(mod(R0(51)+R0(46),2), R0(41)), ...
                      bitand(mod(R0(21)+R0(11),2), mod(R0(6)+R0(1),2)));
        sigma2C = xor(xor(bitand(R0(51),R0(46)), bitand(R0(21),R0(11))), ...
                      bitand(R0(6),R0(1)));
        sigma2 = xor(xor(sigma2A,sigma2B),sigma2C);

        r1A = mod(double(sigma2)+R0(41)+R0(36)+R0(31)+R0(26)+R0(16)+R0(1),2);
        r1B = mod(R1(51)+R1(46)+R1(41)+R1(21)+R1(11)+R1(6)+R1(1),2);
        r1fb = mod(r1A+r1B,2);

        R0 = [R0(2:end), r0fb]; %#ok<AGROW>
        R1 = [R1(2:end), r1fb]; %#ok<AGROW>
        C  = [C(2:end), C(1)]; %#ok<AGROW>
    end

    code = 1 - 2*bits;

    % PRN 1 做一次 ICD 前 24 chips 自检：46555656(octal)
    if ~validated && prn == 1
        testOctal = bits24ToOctal(bits(1:24));
        if testOctal ~= "46555656"
            error('NavIC L1 IZ4 自检失败：PRN1 first24=%s, expected 46555656。', testOctal);
        end
        validated = true;
    end
end

function bits = navicOctal55ToBits(octalString)
    s = char(octalString);
    if numel(s) ~= 19
        error('NavIC 55-bit initial state 应为 19 个八进制字符。');
    end
    % ICD：第一字符直接表示 R(0)；后 18 个八进制字符表示剩余 54 bits。
    bits = zeros(1,55);
    bits(1) = str2double(s(1));
    out = 2;
    for k = 2:19
        v = str2double(s(k));
        bits(out:out+2) = [bitget(v,3), bitget(v,2), bitget(v,1)];
        out = out + 3;
    end
end

function s = bits24ToOctal(bits)
    chars = repmat('0',1,8);
    for k = 1:8
        b = bits((k-1)*3+(1:3));
        v = 4*b(1)+2*b(2)+b(3);
        chars(k) = char('0'+v);
    end
    s = string(chars);
end
