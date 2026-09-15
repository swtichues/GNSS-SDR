# Multi-GNSS L1/E1/B1 PCPS Acquisition + Tracking

## 1. 文件

- `MultiGNSS_L1_PCPS_Acquisition.m`
  - 单一入口的多星座捕获脚本。
  - 读取 USRP B210 `signed int8`、I/Q 交织数据。
  - 默认参数：中心频率 `1575.42 MHz`、采样率 `30 MHz`、配置带宽 `30 MHz`。
  - 使用 PCPS：载波擦除 → FFT → 本地码频域共轭相乘 → IFFT → 非相干累加 → 主峰/次峰判决。
  - 捕获结果写入 `MultiGNSS_L1_Acquisition_Result.mat`，其中 `trackingChannels` 直接作为跟踪初始化量。

- `MultiGNSS_L1_Tracking.m`
  - 读取上述捕获 MAT。
  - 对所有 `Detected=true` 通道进行连续跟踪。
  - Early / Prompt / Late 三相关器。
  - 前若干历元使用 FLL 辅助拉频，随后由 Costas PLL 锁相。
  - DLL 使用归一化 Early-minus-Late 包络鉴别器。
  - 保存 Prompt I/Q、DLL/PLL/FLL 鉴别误差、载波频率、多普勒、码频率。
  - 输出 `MultiGNSS_L1_Tracking_Result.mat`。

- `Prepare_Galileo_E1C_Codes.m`
  - Galileo E1-C primary memory code 的兼容辅助脚本。
  - MATLAB R2026a+ 且具有 `galileoCodes` 时可一次性生成 `Galileo_E1C_PrimaryCodes.mat`。

## 2. 当前捕获分支

| 系统 | 信号 | 标称 RF | 捕获本地复制信号 | 默认捕获 Fs |
|---|---|---:|---|---:|
| GPS | L1 C/A | 1575.42 MHz | C/A, BPSK(1) | 4.092 MHz |
| BDS | B1C Pilot-A | 1575.42 MHz | Pilot primary × sinBOC(1,1) | 8.184 MHz |
| BDS | B1I | 1561.098 MHz | B1I, BPSK(2) | 8.184 MHz |
| SBAS | L1 C/A | 1575.42 MHz | C/A family | 4.092 MHz |
| Galileo | E1-C Pilot | 1575.42 MHz | E1C primary × sinBOC(1,1) | 8.184 MHz |
| QZSS | L1 C/A | 1575.42 MHz | C/A family | 4.092 MHz |
| QZSS | L1 C/B | 1575.42 MHz | C/A family dedicated PRNs | 4.092 MHz |
| NavIC | L1 SPS Data | 1575.42 MHz | IZ4 data primary × sinBOC(1,1) | 8.184 MHz |
| GLONASS | L1OF | 1602+k×0.5625 MHz | 511-chip standard code | 2.044 MHz |

### 为什么不是所有信号都直接在 30 Msps 做大 FFT？

原始 IQ 仍然按 30 Msps 读取。对某一信号，先根据 `RF - 1575.42 MHz` 把标称数字中频搬到零频，然后再重采样到适合该信号的捕获采样率。这样保留原 PCPS 物理流程，同时显著降低一次全星座搜索的 FFT/IFFT 规模。

## 3. 1575.42 MHz / 30 MHz 采集文件的物理边界

30 Msps 复采样的理想 Nyquist 区间约为：

`1575.42 ± 15 MHz = 1560.42 ~ 1590.42 MHz`

因此：

- GPS L1、BDS B1C、SBAS L1、Galileo E1、QZSS L1、NavIC L1：位于 1575.42 MHz，可正常进入搜索。
- BDS B1I：1561.098 MHz，对应数字中频约 `-14.322 MHz`。载波中心仍在带内，但已经非常靠近负频率边缘，实际模拟/数字前端可能削弱或截掉一部分信号频谱。因此程序保留 B1I 搜索，但会打印带宽边缘警告。
- GLONASS L1OF：最低常用频道也在约 1598.0625 MHz，超出当前采集范围。程序会把全部 GLONASS L1OF 频道列入结果，但状态为 `OUT_OF_CAPTURE_BAND`，不会伪装成“已经搜索但没捕获”。以后把 USRP 中心频率改到约 1602 MHz 后，同一分支即可执行真正捕获。

## 4. Galileo E1-C 注意事项

Galileo E1-B/E1-C 的 primary code 是 memory code。主捕获脚本按下面顺序取得 E1-C primary code：

1. 当前 MATLAB 有 `galileoCodes`：直接调用；
2. 否则读取同目录 `Galileo_E1C_PrimaryCodes.mat`；
3. 两者都没有时，只跳过 Galileo 分支，其他星座继续运行。

如果 MATLAB 支持 `galileoCodes`，可以先运行 `Prepare_Galileo_E1C_Codes.m` 生成缓存。

当前 Galileo 捕获/跟踪使用 E1-C primary × sinBOC(1,1) 主分量，不做完整 CBOC 两子载波联合处理。这样计算量较低，但相对于完整 CBOC 匹配会有一定相关能量损失。

## 5. NavIC L1

使用 L1 SPS Data 的 IZ4 primary code，PRN 1~64，长度 10230 chips，周期 10 ms。Data primary 没有 pilot overlay code，因此作为第一版捕获/跟踪入口更直接。

程序内嵌了 PRN 1~64 的 R0/R1/C 初始状态，并按 IZ4 反馈逻辑生成主码。开发时已用 ICD 给出的前 24 chips 检查 PRN 1~11，结果一致。

## 6. QZSS

- L1 C/A 默认搜索标准码候选 PRN `193~197, 199~201`。
- PRN 198、202 在接口规范表中标记为 non-standard code，因此默认不作为标准 C/A 本地码候选。
- L1 C/B 搜索 PRN `203~206`。
- L1 C/A 与 L1 C/B 在具体卫星上可能是排他播发，因此同时搜索两个分支是为了让离线文件自己给出结果。

## 7. 运行顺序

### 第一步：修改 IQ 文件

打开 `MultiGNSS_L1_PCPS_Acquisition.m`，修改：

```matlab
iqFile = 'C:/GNSS_Data/your_file.iq';
```

确认：

```matlab
rawFs = 30e6;
captureCenterFrequency = 1575.42e6;
captureBandwidth = 30e6;
iqOrder = 'IQ';
conjugateIQ = false;
```

### 第二步：第一次调试不要全开

全星座、全 PRN、±10 kHz 搜索的计算量很大。第一次建议：

```matlab
searchKeys = ["GPS_L1CA"];
```

确认 GPS 分支可以正常运行后，再逐个打开：

```matlab
"BDS_B1C"
"BDS_B1I"
"SBAS_L1"
"GALILEO_E1C"
"QZSS_L1CA"
"QZSS_L1CB"
"NAVIC_L1"
"GLONASS_L1OF"
```

### 第三步：运行捕获

```matlab
MultiGNSS_L1_PCPS_Acquisition
```

得到：

```text
MultiGNSS_L1_Acquisition_Result.mat
```

### 第四步：运行跟踪

```matlab
MultiGNSS_L1_Tracking
```

得到：

```text
MultiGNSS_L1_Tracking_Result.mat
```

## 8. 捕获到跟踪的接口

捕获成功后，每个 `trackingChannels(k)` 保存：

- `System`
- `Signal`
- `PRN` / GLONASS `Channel`
- `RF_Hz`
- `NominalIF_Hz`
- `Doppler_Hz`
- `CodeRate_Hz`
- `CodeLength`
- `PrimaryCodeChips`
- `CodePhase_Seconds`
- `AcquisitionSkipSeconds`
- `TrackingIntegration_s`
- `DllSpacing_Chips`
- `PeakRatio`

因此跟踪脚本不需要重新猜测“这是哪种信号、码长是多少、B1I 的 -14.322 MHz IF 去哪里了”。

## 9. 跟踪环说明

载波 NCO 初值：

`f_NCO = nominal_IF + acquisition_Doppler`

前 `fllAssistEpochs` 个积分历元：

- FLL 用相邻 Prompt 相位差平方消除 BPSK/secondary-code 的 180° 翻转；
- FLL 负责频率拉入；
- Costas PLL 同时开始建立相位锁定。

之后冻结 FLL 累计偏置，仅由 Costas PLL 的 PI 环进一步锁相。

码环：

- Early / Prompt / Late；
- 归一化 `(E-L)/(E+L)` 包络鉴别；
- 二阶 PI DLL；
- 初始码速率包含由捕获 Doppler 推算的一阶码 Doppler 修正。

## 10. 当前版本没有做的内容

该包完成的是“捕获 + 连续码/载波跟踪”。目前还没有继续做：

- bit/frame synchronization；
- Galileo/B1C/NavIC secondary-code synchronization；
- 导航电文译码；
- 星历解析；
- 伪距形成；
- PVT 定位解算；
- 完整 CBOC/QMBOC/SBOC 多分量联合相关；
- 严格的 C/N0、锁定检测、失锁重捕获状态机。

这些可以在当前 `Prompt I/Q + code/carrier NCO` 输出的基础上继续增加。

## 11. MATLAB 依赖

- `resample()`：Signal Processing Toolbox。
- Galileo：若直接调用 `galileoCodes()`，需要支持该函数的 MATLAB / Satellite Communications Toolbox；如果已有 `Galileo_E1C_PrimaryCodes.mat`，主捕获不需要每次调用该函数。

