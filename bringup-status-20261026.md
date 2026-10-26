# openTPU–V80 首轮实现与验证

日期：2026-10-26。分支：`feature/v80-smoke`。

## 当前结论

单 slice openTPU 已完成源码接入、原生 INT8 单算子、AXI 访存桥、程序加载/任务控制、用户态 QDMA 库及离线联调。三组算子的 RTL 输出与 ISA golden 逐字节一致，核级 Vivado 综合和完整平台 BD 检查均已通过，具备进入全平台布局布线的基础。

当前结果覆盖离线功能与工程构造。端到端性能、QDMA 实机兼容性和 GPU 协同收益在新镜像上板后测量。本轮保留了原 V80 工程、板卡状态、llama.cpp 和已有 proposal。

## 冻结配置与实现

| 项目 | 首版配置 |
|---|---|
| 上游核 | openTPU `506e81b1d297e22739dab5ecaeee684493d5c720`，固定 submodule |
| 平台来源 | M3 `abe224cc2802285414de20492b94041bd56d6704`，40 份集成/AMR 文件快照 |
| 核规模 | S=1、D=128、MCOLS=4、LANES=8，generic 器件实现 |
| 存储 | ACT_ROWS=4、ACT_BLOCKS=16、TMEM=16384 个 word、IMEM=8192 个 word（1024 条指令） |
| 调度 | scoreboard；SEQ_WC、DSTEP/STREAM、PAIR 关闭 |
| TMEM | TMEM_IMPL=0、TMEM_PMP=0，单核时钟 |
| 目标时钟 | 核 75 MHz，平台控制 100 MHz、访存 AXI 400 MHz |
| HBM | 核侧共享 4 GiB，物理基址 `0x4000000000` |
| 控制 | BAR2+`0x10000`，单任务在途、轮询完成、task ID/epoch、取消/超时/恢复 |
| 配置标识 | CFG_HASH=`db17d1cf` |
| 工具 | Vivado 2026.1；Python 3.13.12；Verilator wheel 5.48.0，另锁定可执行文件 SHA256 |

配置见 [v80_smoke.toml](configs/v80_smoke.toml)，版本与契约 SHA256 见 [dependencies.lock.json](configs/dependencies.lock.json)。Verilator wheel 的版本回显包含 `vUNKNOWN`，仿真尾部报告 5.49；本工程以 wheel 版本及 binary SHA256 共同识别，封装脚本补齐 GCC 的 C++20/PCH 参数。

阶段验证清单与产物 SHA256 见 [validation-20261026.json](configs/validation-20261026.json)，完整归档入口为 [本轮 manifest](results/bringup-offline-20261026-132346/manifest.json)。

主要源码入口：

- [计算子系统](hardware/rtl/top/v80_opentpu_core.sv)：真实 slice、集体同步、控制与访存桥。
- [板级 wrapper](hardware/rtl/top/v80_opentpu_wrapper.sv)：沿用平台接口和 HBM remap，原 RV 主端保持空闲。
- [访存桥](hardware/rtl/adapters/otpu_mem_axi.sv)：每口一个 pending、一个 AXI 在途事务，跨口按接收顺序执行。
- [控制器](hardware/rtl/adapters/v80_control.sv)：AXI-Lite、加载、完成、周期计数及错误恢复。
- [共享契约](contracts/README.md)：生成 C/Python/SV/Tcl 定义。
- [用户态库与板测入口](software/driver/README.md)：常驻 FD、BAR、DMA、submit/wait 和冻结用例校验。

## 已完成验证

### 计算与协议

| Case | 指令数 | 输出规模 | RTL/ISA | 独立量化数学参考 relative L2 |
|---|---:|---:|---|---:|
| GEMV，K=256、N=256 | 5 | 256×FP32 | 逐字节一致 | 4.57e-8 |
| 投影，K=2048、N=512 | 5 | 512×FP32 | 逐字节一致 | 3.55e-8 |
| SwiGLU，2048→512→2048 | 14 | 2048×FP32 | 逐字节一致 | 7.62e-8 |

SwiGLU 包含 Gate/Up、SiLU、乘法、再次量化和 Down；算子对应单个 routed expert，层级 RMSNorm 与 residual 由调用方处理。三组同时核对整个已初始化内存区，涵盖输入、权重、scale、程序及输出。

每组执行三次复用权重的正常任务，并验证取消、超时、AXI 读错误和恢复后再次执行。每次核对 task ID、epoch、指令数和完成状态；延迟 AXI B 响应时，任务持续 BUSY，随后完整发布输出。外部仿真内存限制为 8 MiB，计算核参数与冻结 target 一致。

访存桥以 seed=23/117/2026 分别运行，每组 63 项检查：A scale line、B tag/word mask、SW byte enable、背压与握手保持、4 KiB 边界、最高合法地址、跨端口写后读、RRESP/BRESP/异常 RLAST、非法地址和错误清除。

Host 用户态库在 Release 下通过 17 项检查，涵盖配置不匹配、重复提交、stale completion、epoch、Host 超时/取消、真实 FD/mmap/pread/pwrite 的文件后端回环、越界及 EOF。QDMA 实机与 CUDA pinned buffer 兼容性留到板测。

原始记录：[最新 RTL 回归](results/offline-20261026-135508/manifest.json)、[命令](results/offline-20261026-135508/commands.sh)、[桥测试](results/offline-20261026-135508/bridge-seed-23.log)。仿真周期用于检查执行过程，板卡延迟采用实测。

### Vivado

| 检查 | 结果 | 证据 |
|---|---|---|
| 最新计算 IP OOC 综合 | 通过，无 black box | [manifest](hardware/vivado/projects/v80_smoke/ooc-20261026-135819-654982/manifest.json) |
| 综合后资源 | LUT=149757，FF=97671，RAMB36=225，RAMB18=11，DSP Block=122 | [资源报告](hardware/vivado/projects/v80_smoke/ooc-20261026-135819-654982/reports/utilization.rpt) |
| 完整平台 BD/地址/时钟/复位检查、IP 生成 | 通过 | [manifest](hardware/vivado/projects/v80_smoke/check-20261026-141659-770943/manifest.json)、[平台检查](hardware/vivado/projects/v80_smoke/check-20261026-141659-770943/reports/bd_audit.txt) |
| BAR2 AXCACHE | 有效值保持 0 | [属性断言](hardware/vivado/projects/v80_smoke/check-20261026-141659-770943/reports/bar2_attributes.txt) |

122 个 DSP Block 包含 17 个 DSP58 与 105 个 DSP_ALUADD。generic MXU 的较大部分计算映射在 LUT；首版用于打通功能，后续根据板上测量决定技术映射与阵列规模。

OOC 的时序估计尚未包含真实布局布线及平台时钟偏斜。日志保留 RAMB36E5 内部转换、RAM 推断/裁剪等 Warning；完整实现阶段结合资源、时序、CDC、DRC 和板测继续审查。平台检查沿用 M3 的 NoC/时钟断言；其中 legacy event 端口保持空闲，任务状态由新 ABI 管理。

## 本轮解决的接口问题

1. **地址单位。**指令和加载寄存器使用字节地址，slice 的 A/B/SW 使用 word 地址；桥显式转换并检查 4 GiB 越界。
2. **内存顺序。**跨端口按接受时间排序，防止轮询仲裁让较新的读越过已经接受的写；同周期请求采用写优先。
3. **完成与恢复。**任务完成同时覆盖核执行结束、端口与桥队列排空和 AXI 写响应；取消/超时保留外部事务直至排空。
4. **控制 aperture。**IP-XACT 显式声明 BAR2+`0x10000` 的控制范围，核内按低 12 位译码，平台地址保持一致。首次配置失败记录保留于 [failure.txt](hardware/vivado/projects/v80_smoke/check-20261026-135532-395396/failure.txt)。
5. **时钟传播。**IP 时钟跟随平台源传播，实际核频率为 74,999,997 Hz，平台断言按约 75 MHz 核对；精确频率用于接口匹配。

## 下一阶段

1. 执行全平台综合和布局布线，审查实际时序、CDC、bus skew、DRC、未约束路径与 Warning 归属。
2. 冻结 AMC 源码与打包工具，生成同一构建的 BOOT/PLD/XSA/AMC；核验内部镜像一致性、父 UUID、SHA256 及分区容量。
3. 在板卡使用窗口加载配套镜像，用现有板测入口完成三个 case、变化输入和至少 1000 次重复任务。
4. 完成 GPU staging 与常驻运行库闭环，拆分 D2H/H2C/核执行/C2H/H2D，随后测试单层 hit/miss 分流。

全平台实现入口已加入：

```bash
source hardware/scripts/build/env.sh
bash hardware/scripts/build/build.sh --implement
```

该入口创建独立构建目录、综合、route 并生成报告。镜像打包/部署和新核板测属于后续交付；现有在线 V80 平台保持原状。
