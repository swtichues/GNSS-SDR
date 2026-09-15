%% MultiGNSS_L1_Tracking.m
% =========================================================================
% 多星座 L1/E1/B1 跟踪模块
%
% 输入：MultiGNSS_L1_PCPS_Acquisition.m 生成的
%       MultiGNSS_L1_Acquisition_Result.mat
%
% 跟踪结构：
%   1. 捕获码相位 -> 定位到原始 30 Msps sc8 IQ 中的码周期起点；
%   2. 标称数字中频 + 捕获 Doppler -> 载波 NCO 初值；
%   3. Early / Prompt / Late 三相关器；
%   4. FLL 辅助 Costas PLL：前若干历元负责较快拉频，之后由 Costas PLL 锁相；
%   5. 归一化 Early-minus-Late 包络 DLL；
%   6. 连续保存 Prompt I/Q、DLL/PLL/FLL 误差、载波频率和码频率；
%   7. 每个通道单独绘图，并把全部结果保存到 MAT。
%
% 说明：
%   * 对 GPS/SBAS/QZSS/BDS B1I/GLONASS，导航数据 180° 翻转由 Costas PLL 处理。
%   * 对 Galileo E1-C、BDS B1C Pilot-A 的 secondary-code 翻转，同样使用
%     Costas 型相位鉴别，因此跟踪本身不要求先知道 secondary-code 相位。
%   * BOC 信号使用与捕获一致的 sinBOC(1,1) 本地复制信号；这是实用的
%     低复杂度跟踪版本，不是完整 CBOC/QMBOC/SBOC 多分量联合跟踪器。
% =========================================================================

clear;
clc;
close all;

%% ========================================================================
%  1. 用户参数
% =========================================================================

acqMatFile = fullfile(fileparts(mfilename('fullpath')), ...
                      'MultiGNSS_L1_Acquisition_Result.mat');

% 每颗已捕获卫星/通道跟踪多长时间。
trackingDurationSeconds = 1.0;

% 默认跟踪所有捕获成功的通道。
% 若只想跟踪指定通道，把 trackAllDetected 改 false，然后设置下面三个条件。
trackAllDetected = true;
selectedSystem = "GPS";
selectedSignal = "L1 C/A";
selectedPRN = 1;

% 载波环参数
pllNoiseBandwidthHz = 18.0;
pllDamping = 0.707;

% 前若干历元使用 FLL 辅助拉频。
fllAssistEpochs = 50;
fllGain = 0.35;

% 码环参数
dllNoiseBandwidthHz = 2.0;
dllDamping = 0.707;

% 失锁保护：Prompt 功率连续过低时这里只记录，不自动停止。
% 真正工程接收机可在此基础上增加 lock detector / reacquisition。
plotEveryChannel = true;

%% ========================================================================
%  2. 读取捕获结果
% =========================================================================

if ~isfile(acqMatFile)
    error(['找不到捕获结果文件：\n%s\n' ...
           '请先运行 MultiGNSS_L1_PCPS_Acquisition.m。'], acqMatFile);
end

S = load(acqMatFile, 'trackingChannels', 'config', 'results');

if ~isfield(S, 'trackingChannels') || isempty(S.trackingChannels)
    error('捕获结果中没有 Detected=true 的可跟踪通道。');
end

trackingChannels = S.trackingChannels;
config = S.config;

fprintf('============================================================\n');
fprintf('Multi-GNSS L1 Tracking\n');
fprintf('============================================================\n');
fprintf('IQ file                : %s\n', config.iqFile);
fprintf('Sample rate            : %.3f MHz\n', config.rawFs/1e6);
fprintf('Capture center         : %.5f MHz\n', config.captureCenterFrequency/1e6);
fprintf('Tracking duration      : %.3f s / channel\n', trackingDurationSeconds);
fprintf('Detected channel count : %d\n', numel(trackingChannels));
fprintf('PLL bandwidth          : %.2f Hz\n', pllNoiseBandwidthHz);
fprintf('DLL bandwidth          : %.2f Hz\n', dllNoiseBandwidthHz);
fprintf('============================================================\n\n');

%% ========================================================================
%  3. 选择要跟踪的通道
% =========================================================================

selectedIndices = [];

for k = 1:numel(trackingChannels)
    ch = trackingChannels(k);

    if trackAllDetected
        selectedIndices(end+1) = k; %#ok<SAGROW>
    else
        if ch.System == selectedSystem && ...
           ch.Signal == selectedSignal && ...
           ch.PRN == selectedPRN
            selectedIndices(end+1) = k; %#ok<SAGROW>
        end
    end
end

if isempty(selectedIndices)
    error('没有找到满足当前筛选条件的已捕获通道。');
end

%% ========================================================================
%  4. 逐通道跟踪
% =========================================================================

allTrackingResults = struct([]);

for selectedIndex = 1:numel(selectedIndices)

    ch = trackingChannels(selectedIndices(selectedIndex));

    fprintf('\n============================================================\n');
    if isnan(ch.Channel)
        fprintf('Tracking %s | %s | PRN %d\n', ch.System, ch.Signal, ch.PRN);
    else
        fprintf('Tracking %s | %s | channel %+d\n', ch.System, ch.Signal, ch.Channel);
    end
    fprintf('============================================================\n');

    tr = trackOneChannel(config, ch, trackingDurationSeconds, ...
        pllNoiseBandwidthHz, pllDamping, fllAssistEpochs, fllGain, ...
        dllNoiseBandwidthHz, dllDamping);

    allTrackingResults = appendStructArray(allTrackingResults, tr);

    if plotEveryChannel
        plotTrackingResult(tr);
    end
end

%% ========================================================================
%  5. 保存跟踪结果
% =========================================================================

trackingOutputMat = fullfile(fileparts(mfilename('fullpath')), ...
                             'MultiGNSS_L1_Tracking_Result.mat');
save(trackingOutputMat, 'allTrackingResults', 'config', '-v7.3');

fprintf('\n============================================================\n');
fprintf('Tracking completed.\n');
fprintf('Result saved to:\n  %s\n', trackingOutputMat);
fprintf('============================================================\n');

%% ========================================================================
%  本地函数 1：单通道连续跟踪
% =========================================================================
function tr = trackOneChannel(config, ch, durationSeconds, ...
        pllBn, pllZeta, fllAssistEpochs, fllGain, dllBn, dllZeta)

    fs = config.rawFs;
    T = ch.TrackingIntegration_s;
    nominalBlockSamples = round(T * fs);
    numEpochs = floor(durationSeconds / T);

    if numEpochs < 1
        error('trackingDurationSeconds 小于一个跟踪积分周期。');
    end

    % ---------------------------------------------------------------------
    % 捕获给出的 CodePhase_Seconds 是从 acquisition skip 起点开始的循环相关 lag。
    % 因此从 skip + lag 开始读取，理论上第一个样点就在主码 chip 0 附近。
    % ---------------------------------------------------------------------
    requestedStartSeconds = ch.AcquisitionSkipSeconds + ch.CodePhase_Seconds;
    requestedStartSample = requestedStartSeconds * fs;
    actualStartSample = round(requestedStartSample);
    actualStartSeconds = actualStartSample / fs;

    % 因为文件 seek 只能落在整数采样点，保留这个不到半个采样的分数码相位。
    fractionalStartSeconds = actualStartSeconds - requestedStartSeconds;
    initialCodePhaseChips = mod(fractionalStartSeconds * ch.CodeRate_Hz, ...
                                ch.CodeLength);

    % 多读一个积分块，便于最后边界安全。
    totalSamples = numEpochs * nominalBlockSamples + nominalBlockSamples;
    signal = readSc8IQBySample(config.iqFile, actualStartSample, totalSamples, ...
                               config.iqOrder, config.conjugateIQ);

    % ---------------------------------------------------------------------
    % 载波 / 码 NCO 初值
    % ---------------------------------------------------------------------
    carrierFrequencyInitial = ch.NominalIF_Hz + ch.Doppler_Hz;
    carrierFrequency = carrierFrequencyInitial;
    carrierPhase = 0;
    fllFrequencyOffsetHz = 0;

    % 一阶 Doppler 比例给出码速率初值，可明显降低 DLL 初始漂移。
    codeFrequencyBase = ch.CodeRate_Hz * (1 + ch.Doppler_Hz / ch.RF_Hz);
    codeFrequency = codeFrequencyBase;
    codePhase = initialCodePhaseChips;

    % PI 环路增益。
    [pllKp, pllKi] = secondOrderLoopGains(pllBn, pllZeta);
    [dllKp, dllKi] = secondOrderLoopGains(dllBn, dllZeta);
    pllIntegratorHz = 0;
    dllIntegratorChipPerSec = 0;

    primaryCode = double(ch.PrimaryCodeChips(:).');
    modulation = ch.Modulation;
    spacing = ch.DllSpacing_Chips;

    % ---------------------------------------------------------------------
    % 结果数组
    % ---------------------------------------------------------------------
    time_s = zeros(numEpochs,1);
    IE = zeros(numEpochs,1); QE = zeros(numEpochs,1);
    IP = zeros(numEpochs,1); QP = zeros(numEpochs,1);
    IL = zeros(numEpochs,1); QL = zeros(numEpochs,1);
    promptPower = zeros(numEpochs,1);
    dllError = zeros(numEpochs,1);
    pllErrorCycles = zeros(numEpochs,1);
    fllErrorHz = nan(numEpochs,1);
    carrierFrequencyHz = zeros(numEpochs,1);
    dopplerHz = zeros(numEpochs,1);
    codeFrequencyHz = zeros(numEpochs,1);

    prevPrompt = 0;
    readIndex = 1;

    fprintf('Initial carrier NCO     : %+.3f MHz\n', carrierFrequency/1e6);
    fprintf('Initial residual Doppler: %+0.1f Hz\n', ch.Doppler_Hz);
    fprintf('Initial code frequency : %.3f Hz\n', codeFrequency);
    fprintf('Integration time       : %.3f ms\n', T*1e3);
    fprintf('Early-Late spacing     : %.3f chips total\n', spacing);

    for epoch = 1:numEpochs

        N = nominalBlockSamples;
        if readIndex + N - 1 > length(signal)
            break;
        end
        block = signal(readIndex:readIndex+N-1).';

        % -------------------------------------------------------------
        % Carrier NCO / wipe-off
        % -------------------------------------------------------------
        n = 0:N-1;
        carrier = exp(-1j * (carrierPhase + 2*pi*carrierFrequency*n/fs));
        baseband = block .* carrier;

        carrierPhase = mod(carrierPhase + 2*pi*carrierFrequency*N/fs, 2*pi);

        % -------------------------------------------------------------
        % Code NCO / E-P-L replicas
        % Early 定义为相对 Prompt 前进 spacing/2 chip；Late 相对落后。
        % -------------------------------------------------------------
        codePhaseVector = codePhase + n * codeFrequency / fs;

        promptCode = localReplicaFromPhase(primaryCode, codePhaseVector, modulation);
        earlyCode  = localReplicaFromPhase(primaryCode, ...
                     codePhaseVector + spacing/2, modulation);
        lateCode   = localReplicaFromPhase(primaryCode, ...
                     codePhaseVector - spacing/2, modulation);

        E = sum(baseband .* earlyCode);
        P = sum(baseband .* promptCode);
        L = sum(baseband .* lateCode);

        IE(epoch)=real(E); QE(epoch)=imag(E);
        IP(epoch)=real(P); QP(epoch)=imag(P);
        IL(epoch)=real(L); QL(epoch)=imag(L);
        promptPower(epoch)=abs(P)^2;

        % -------------------------------------------------------------
        % DLL：归一化 Early-minus-Late 包络鉴别器。
        % 把归一化量近似缩放为 chip 误差，再用二阶 PI 修正 code NCO。
        % -------------------------------------------------------------
        eMag = abs(E);
        lMag = abs(L);
        dllNorm = (eMag - lMag) / max(eMag + lMag, eps);
        dllErrChip = (spacing/2) * dllNorm;
        dllError(epoch) = dllErrChip;

        dllIntegratorChipPerSec = dllIntegratorChipPerSec + ...
                                  dllKi * dllErrChip * T;
        codeCorrection = dllKp * dllErrChip + dllIntegratorChipPerSec;
        codeFrequency = codeFrequencyBase + codeCorrection;

        % -------------------------------------------------------------
        % Costas PLL：必须先用 Prompt-I 的符号消除 BPSK 的 ±1 数据翻转。
        % 原先直接使用 atan2(Q, |I|) 并不能消除数据翻转：
        % 当 (I,Q) -> (-I,-Q) 时，Q 仍会反号，因此鉴相误差也反号。
        % 下面的写法等价于 atan(Q/I)，但在 I≈0 时更稳健：
        %     e_phi = atan2(sign(I)*Q, |I|)
        % -------------------------------------------------------------
        promptISign = 1.0;
        if real(P) < 0
            promptISign = -1.0;
        end
        phaseErrCycles = atan2(promptISign * imag(P), ...
                               abs(real(P)) + eps) / (2*pi);
        pllErrorCycles(epoch) = phaseErrCycles;

        pllIntegratorHz = pllIntegratorHz + pllKi * phaseErrCycles * T;
        pllCorrectionHz = pllKp * phaseErrCycles + pllIntegratorHz;

        % -------------------------------------------------------------
        % FLL pull-in：对相邻 Prompt 的相位差先平方，去掉 BPSK 的 π 翻转。
        % angle((P_k * conj(P_{k-1}))^2) / (4*pi*T)
        % -------------------------------------------------------------
        if epoch > 1 && abs(prevPrompt) > 0 && abs(P) > 0
            phaseDiffSquared = angle((P * conj(prevPrompt))^2);
            fllErr = phaseDiffSquared / (4*pi*T);
            fllErrorHz(epoch) = fllErr;
        else
            fllErr = 0;
        end

        % FLL 的作用是修正捕获留下的频率偏差；该偏差作为一个独立状态累计。
        % PLL 的 PI 输出则作为相对于这个拉频结果的锁相修正。
        % 不能把 pllCorrectionHz 每个历元直接加到上一次 carrierFrequency 上，
        % 否则会重复积分同一个 PLL 修正量。
        if epoch <= fllAssistEpochs
            fllFrequencyOffsetHz = fllFrequencyOffsetHz + fllGain*fllErr;
        end
        carrierFrequency = carrierFrequencyInitial + ...
                           fllFrequencyOffsetHz + pllCorrectionHz;

        prevPrompt = P;

        % Code phase 连续推进到下一积分块。
        codePhase = mod(codePhase + N*codeFrequency/fs, ch.CodeLength);

        time_s(epoch) = (epoch-0.5)*T;
        carrierFrequencyHz(epoch) = carrierFrequency;
        dopplerHz(epoch) = carrierFrequency - ch.NominalIF_Hz;
        codeFrequencyHz(epoch) = codeFrequency;

        readIndex = readIndex + N;

        if mod(epoch, max(1,floor(numEpochs/10))) == 0 || epoch == numEpochs
            fprintf(['      epoch %5d / %5d | Doppler %+8.2f Hz | ' ...
                     'DLL %+8.4f chip | PLL %+8.4f cycles\n'], ...
                    epoch, numEpochs, dopplerHz(epoch), ...
                    dllError(epoch), pllErrorCycles(epoch));
        end
    end

    % ---------------------------------------------------------------------
    % 输出结构
    % ---------------------------------------------------------------------
    tr = struct();
    tr.System = ch.System;
    tr.Signal = ch.Signal;
    tr.PRN = ch.PRN;
    tr.Channel = ch.Channel;
    tr.RF_Hz = ch.RF_Hz;
    tr.AcquisitionPeakRatio = ch.PeakRatio;
    tr.AcquisitionDoppler_Hz = ch.Doppler_Hz;
    tr.StartSeconds = actualStartSeconds;
    tr.Integration_s = T;
    tr.Time_s = time_s;
    tr.IE = IE; tr.QE = QE;
    tr.IP = IP; tr.QP = QP;
    tr.IL = IL; tr.QL = QL;
    tr.PromptPower = promptPower;
    tr.DLL_Error_Chips = dllError;
    tr.PLL_Error_Cycles = pllErrorCycles;
    tr.FLL_Error_Hz = fllErrorHz;
    tr.CarrierFrequency_Hz = carrierFrequencyHz;
    tr.Doppler_Hz = dopplerHz;
    tr.CodeFrequency_Hz = codeFrequencyHz;

    % 最后 20% 的结果用于给出一个简单稳定值摘要。
    tailStart = max(1, floor(0.8*numEpochs));
    tr.FinalDoppler_Hz = median(dopplerHz(tailStart:end));
    tr.FinalCodeFrequency_Hz = median(codeFrequencyHz(tailStart:end));
    tr.PromptPowerMedian = median(promptPower(tailStart:end));

    % -----------------------------------------------------------------
    % 跟踪锁定判据：把“捕获候选”进一步筛成“确认锁定通道”。
    % -----------------------------------------------------------------
    tailPrompt = IP(tailStart:end) + 1j*QP(tailStart:end);
    tailEarly  = IE(tailStart:end) + 1j*QE(tailStart:end);
    tailLate   = IL(tailStart:end) + 1j*QL(tailStart:end);

    validPrompt = abs(tailPrompt) > eps;
    if any(validPrompt)
        unitPrompt = tailPrompt(validPrompt) ./ abs(tailPrompt(validPrompt));
        % 平方后 BPSK 的 ±1 翻转消失。载波相位稳定时趋近 1，
        % 相位近似随机时趋近 0。
        tr.CarrierLockMetric = abs(mean(unitPrompt.^2));
    else
        tr.CarrierLockMetric = 0;
    end

    promptAmp = median(abs(tailPrompt));
    earlyAmp  = median(abs(tailEarly));
    lateAmp   = median(abs(tailLate));
    tr.CodeLockMetric = promptAmp / max(0.5*(earlyAmp + lateAmp), eps);

    tr.CarrierLocked  = tr.CarrierLockMetric >= 0.60;
    tr.CodeLocked     = tr.CodeLockMetric >= 1.05;
    tr.TrackingLocked = tr.CarrierLocked && tr.CodeLocked;

    fprintf('Final Doppler (median) : %+0.3f Hz\n', tr.FinalDoppler_Hz);
    fprintf('Final code frequency   : %.6f Hz\n', tr.FinalCodeFrequency_Hz);
    fprintf('Carrier lock metric    : %.3f\n', tr.CarrierLockMetric);
    fprintf('Code lock metric       : %.3f\n', tr.CodeLockMetric);
    if tr.TrackingLocked
        fprintf('Tracking decision      : LOCKED\n');
    else
        fprintf('Tracking decision      : NOT LOCKED\n');
    end
end

%% ========================================================================
%  本地函数 2：从文件中按复采样点读取 sc8 IQ
% =========================================================================
function signal = readSc8IQBySample(iqFile, startComplexSample, numComplex, ...
                                   iqOrder, conjugateIQ)
    fid = fopen(iqFile, 'rb');
    if fid < 0
        error('无法打开 IQ 文件：%s', iqFile);
    end

    byteOffset = round(startComplexSample) * 2;
    status = fseek(fid, byteOffset, 'bof');
    if status ~= 0
        fclose(fid);
        error('无法跳到跟踪起始采样点 %d。', round(startComplexSample));
    end

    raw = fread(fid, 2*numComplex, 'int8=>double');
    fclose(fid);

    if numel(raw) < 2*numComplex
        error('IQ 文件剩余数据不足以完成当前跟踪时长。');
    end

    switch upper(iqOrder)
        case 'IQ'
            I = raw(1:2:end); Q = raw(2:2:end);
        case 'QI'
            Q = raw(1:2:end); I = raw(2:2:end);
        otherwise
            error('iqOrder 只能是 ''IQ'' 或 ''QI''。');
    end

    signal = complex(I,Q)/128.0;
    if conjugateIQ
        signal = conj(signal);
    end
    signal = signal - mean(signal);
end

%% ========================================================================
%  本地函数 3：按连续 code phase 产生本地 E/P/L replica
% =========================================================================
function replica = localReplicaFromPhase(primaryCode, codePhaseChips, modulation)
    codeLength = numel(primaryCode);
    idx = mod(floor(codePhaseChips), codeLength) + 1;
    replica = primaryCode(idx);

    if strcmpi(modulation, 'BOC11')
        subcarrier = 1 - 2*mod(floor(2*codePhaseChips),2);
        replica = replica .* subcarrier;
    end
end

%% ========================================================================
%  本地函数 4：二阶 PI 环路近似增益
% =========================================================================
function [Kp, Ki] = secondOrderLoopGains(noiseBandwidthHz, damping)
    % 常用 GNSS 二阶环近似：
    %   wn = 8*zeta*Bn / (4*zeta^2 + 1)
    %   Kp = 2*zeta*wn
    %   Ki = wn^2
    wn = 8*damping*noiseBandwidthHz / (4*damping^2 + 1);
    Kp = 2*damping*wn;
    Ki = wn^2;
end

%% ========================================================================
%  本地函数 5：跟踪结果绘图
% =========================================================================
function plotTrackingResult(tr)
    if isnan(tr.Channel)
        tag = sprintf('%s %s PRN %d', tr.System, tr.Signal, tr.PRN);
    else
        tag = sprintf('%s %s CH %+d', tr.System, tr.Signal, tr.Channel);
    end

    % 图 1：Prompt I/Q
    figure('Name', [tag ' - Prompt I/Q'], 'NumberTitle', 'off');
    plot(tr.Time_s, tr.IP, 'DisplayName', 'I_P'); hold on;
    plot(tr.Time_s, tr.QP, 'DisplayName', 'Q_P');
    xlabel('Time (s)'); ylabel('Prompt correlation');
    title([tag ' - Prompt I/Q']);
    grid on; legend('show');

    % 图 2：DLL
    figure('Name', [tag ' - DLL'], 'NumberTitle', 'off');
    plot(tr.Time_s, tr.DLL_Error_Chips);
    xlabel('Time (s)'); ylabel('DLL error (chips)');
    title([tag ' - DLL discriminator']);
    grid on;

    % 图 3：PLL
    figure('Name', [tag ' - PLL'], 'NumberTitle', 'off');
    plot(tr.Time_s, tr.PLL_Error_Cycles);
    xlabel('Time (s)'); ylabel('PLL error (cycles)');
    title([tag ' - Costas PLL discriminator']);
    grid on;

    % 图 4：Doppler
    figure('Name', [tag ' - Doppler'], 'NumberTitle', 'off');
    plot(tr.Time_s, tr.Doppler_Hz);
    xlabel('Time (s)'); ylabel('Estimated Doppler / residual offset (Hz)');
    title([tag ' - Carrier tracking']);
    grid on;

    % 图 5：Prompt power
    figure('Name', [tag ' - Prompt Power'], 'NumberTitle', 'off');
    plot(tr.Time_s, 10*log10(tr.PromptPower + eps));
    xlabel('Time (s)'); ylabel('Prompt power (dB, arbitrary reference)');
    title([tag ' - Prompt correlation power']);
    grid on;
end

function out = appendStructArray(a, b)
    if isempty(a)
        out = b;
    else
        out = [a(:); b(:)]; %#ok<AGROW>
    end
end
