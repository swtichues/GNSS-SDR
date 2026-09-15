function outputFile = Prepare_Galileo_E1C_Codes(forceRebuild)
%% Prepare_Galileo_E1C_Codes.m
% =========================================================================
% Galileo E1-C primary-code 本地缓存准备程序
%
% 本版本不依赖任何新版本卫星通信工具箱函数。
%
% 工作方式：
%   1. 优先检查同目录 Galileo_E1C_PrimaryCodes.mat；
%   2. 缓存不存在时，读取同目录 sdrcode.c；
%   3. 如果本地没有 sdrcode.c，则通过 webread/urlread 获取公开 GNSS-SDRLIB
%      的 sdrcode.c；
%   4. 只提取 gencode_E1C() 中 SVID 1~50 的 50 组 1023-HEX memory code；
%   5. 转换成 4092 x 50 的 int8(+1/-1) 矩阵并保存。
%
% 使用：
%   Prepare_Galileo_E1C_Codes
%   Prepare_Galileo_E1C_Codes(true)    % 强制重建
%
% 如果采集电脑不能联网：
%   手动下载 GNSS-SDRLIB/src/sdrcode.c，放到本 .m 文件同目录，
%   再运行本函数即可。之后捕获完全离线。
% =========================================================================

    if nargin < 1
        forceRebuild = false;
    end

    baseDir = fileparts(mfilename('fullpath'));
    outputFile = fullfile(baseDir, 'Galileo_E1C_PrimaryCodes.mat');

    fprintf('============================================================\n');
    fprintf('Prepare Galileo E1-C Primary-Code Cache - V3\n');
    fprintf('============================================================\n');
    fprintf('External toolbox needed : NO\n');
    fprintf('Output file             : %s\n', outputFile);

    %% 1. 已有缓存：验证后直接返回
    if ~forceRebuild && exist(outputFile, 'file') == 2
        S = load(outputFile, 'galileoE1CChips');
        if isfield(S, 'galileoE1CChips') && ...
           isequal(size(S.galileoE1CChips), [4092 50]) && ...
           all(abs(double(S.galileoE1CChips(:))) == 1)
            fprintf('Existing cache          : VALID\n');
            fprintf('Matrix size             : 4092 x 50\n');
            fprintf('============================================================\n');
            return;
        end
        fprintf('Existing cache          : INVALID -> rebuild\n');
    end

    %% 2. 取得公开 E1-C memory-code 表所在源码
    localSource = fullfile(baseDir, 'sdrcode.c');
    sourceUrl = ['https://raw.githubusercontent.com/taroz/GNSS-SDRLIB/' ...
                 'refs/heads/master/src/sdrcode.c'];

    sourceText = '';

    if exist(localSource, 'file') == 2
        fprintf('Source                  : local sdrcode.c\n');
        sourceText = fileread(localSource);
    else
        fprintf('Source                  : public GNSS-SDRLIB sdrcode.c\n');
        fprintf('Downloading once to build local cache...\n');

        networkMessage = '';

        if exist('webread', 'file') == 2
            try
                sourceText = webread(sourceUrl);
            catch ME
                networkMessage = ME.message;
            end
        end

        if isempty(sourceText) && exist('urlread', 'file') == 2
            try
                [sourceText, ok] = urlread(sourceUrl); %#ok<URLRD>
                if ~ok
                    sourceText = '';
                end
            catch ME
                if isempty(networkMessage)
                    networkMessage = ME.message;
                end
            end
        end

        if isempty(sourceText)
            error(['无法取得 Galileo E1-C memory-code 表。\n' ...
                   '请手动下载 GNSS-SDRLIB 的 src/sdrcode.c，\n' ...
                   '并把它放在本脚本同目录后再次运行。\n\n' ...
                   '下载地址：\n' sourceUrl '\n\n' ...
                   '当前网络错误：' networkMessage]);
        end
    end

    if isstring(sourceText)
        sourceText = char(sourceText);
    end

    %% 3. 精确截取 gencode_E1C()，防止误读 E1B/E5 码表
    startToken = 'static short *gencode_E1C';
    endToken   = '/* E5aI code';

    startPos = strfind(sourceText, startToken);
    endPos   = strfind(sourceText, endToken);

    if isempty(startPos)
        error('源码中没有找到 Galileo E1-C 的 gencode_E1C()。');
    end

    startPos = startPos(1);
    endPos = endPos(find(endPos > startPos, 1, 'first'));

    if isempty(endPos)
        error('找到 gencode_E1C()，但没有找到其后续代码分界。');
    end

    e1cText = sourceText(startPos:endPos-1);

    % 4092 bits = 1023 HEX characters；应有 SVID 1~50 共 50 组。
    tokenCells = regexp(e1cText, '"([0-9A-Fa-f]{1023})"', 'tokens');

    if numel(tokenCells) ~= 50
        error('E1-C 码表提取失败：得到 %d 组，期望 50 组。', numel(tokenCells));
    end

    fprintf('Extracted codes         : %d\n', numel(tokenCells));

    %% 4. HEX -> 4092 chips
    % GNSS-SDRLIB 的 E1-C gencode 实现最终符号约定为：
    %   binary 0 -> -1
    %   binary 1 -> +1
    galileoE1CChips = int8(zeros(4092, 50));

    for svidIndex = 1:50
        hexCode = upper(tokenCells{svidIndex}{1});
        writeIndex = 1;

        for hexIndex = 1:1023
            v = uint8(hex2dec(hexCode(hexIndex)));
            bits = double([bitget(v,4), bitget(v,3), bitget(v,2), bitget(v,1)]);
            chips = int8(2*bits - 1);

            galileoE1CChips(writeIndex:writeIndex+3, svidIndex) = chips(:);
            writeIndex = writeIndex + 4;
        end
    end

    %% 5. 完整性检查
    if ~isequal(size(galileoE1CChips), [4092 50])
        error('内部错误：E1-C 码表尺寸不是 4092 x 50。');
    end

    if ~all(abs(double(galileoE1CChips(:))) == 1)
        error('内部错误：E1-C 码表包含非 +1/-1 元素。');
    end

    for svidIndex = 1:50
        c = galileoE1CChips(:, svidIndex);
        if ~any(c == 1) || ~any(c == -1)
            error('内部错误：E1-C SVID %d 码序列异常。', svidIndex);
        end
    end

    %% 6. 保存本地缓存
    svid = 1:50;
    codeLength = 4092;
    sourceDescription = 'GNSS-SDRLIB gencode_E1C memory-code table';
    sourceURL = sourceUrl;

    save(outputFile, 'galileoE1CChips', 'svid', 'codeLength', ...
         'sourceDescription', 'sourceURL');

    fprintf('Saved cache             : YES\n');
    fprintf('Matrix size             : %d x %d\n', ...
            size(galileoE1CChips,1), size(galileoE1CChips,2));
    fprintf('============================================================\n');
end
