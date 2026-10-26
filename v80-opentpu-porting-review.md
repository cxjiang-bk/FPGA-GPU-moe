# V80 部署 openTPU：工程审查与实施步骤

审查日期：2026-10-26。工程根目录：`/mnt/data/jiangcx/FPGA-GPU-moe`。

本文保留初始移植要求；随后完成的源码、RTL/软件验证与 Vivado 检查见[首轮实现报告](bringup-status-20261026.md)。

## 1. 结论与首版范围

现有硬件、软件、共享契约和生成产物的目录划分合理。V80 的管理、QDMA、NoC、HBM 和时钟复位已有验证基础，主要移植工作集中在 openTPU 用户逻辑、访存桥、程序加载及用户态运行库。

用户已确认首版方案：**在独立工程内，以单 slice openTPU 替换原 LPU/RVCore 用户逻辑，复用 M3 平台结构。**先完成原生 INT8 GEMV/SwiGLU、常驻权重和重复执行，再接 GPU hit / V80 miss 协同。首版使用 Host 中转、单任务在途和轮询完成。

初始审查完成资料核对、目录补充和计划修订。后续首轮实施已加入计算封装、AXI 桥、driver 和构建入口，并通过离线回归、核级综合与 BD 检查。板卡镜像、驱动和队列维持原状。

## 2. 参考资料与可复现边界

| 来源 | 本次观察 | 用途 |
|---|---|---|
| [V80 上板记录](https://tju-opentpu.feishu.cn/wiki/WpVIwEqhdi06PLkKFe4c47XUn3d?from=from_copylink) | revision **1066**，已包含 M4 用户中断与真实算子板测 | 平台流程、历史结果和中断参考 |
| `/mnt/data/jiangcx/v80_bringup/rtl` | HEAD `abe224cc2802285414de20492b94041bd56d6704`，提交主题 M3 | 本地可读取的源码基础 |
| `rtl/fpga/v80/m3_lpumem` | BD/Tcl、构建/打包/回归入口、Host 测试、依赖及验收清单可读 | 新工程的平台适配来源 |
| M3 源码保护检查 | `SOURCE_CHECK_PASS protected=196 historical_artifacts=0` | 已核对清单内 RTL/include；历史镜像未重新校验 |
| M3 历史验收清单 | 2026-10-20：WNS +0.322 ns、WHS +0.010 ns；HBM 回环与 8192 BF16 RMSNorm 逐位一致 | 原平台已有证据；新 openTPU 镜像需重新验收 |

本地 M3 目录已经提供从干净源码重建 IP/BD、实现和打包的入口。`m2_mem`、license 目录及 M3 固定测试数据存在权限限制；因此本次没有完成全工作树 diff、旧 fixture 或历史镜像的全面校验。新 openTPU 用例可自行生成。工具 license 由平台维护者配置。

**M3 与 M4 的交付版本需要区分。**飞书 M4 使用 `m4_interrupt` 源码、candidate004 QDMA 驱动和配套镜像；提供的本地 V80 目录没有这套 M4 源码。首版基于 M3 源码构建轮询方案。后续接入中断时，取得 M4 完整源码、驱动 patch、镜像清单和验收记录，并冻结为独立平台版本。当前在线板卡状态须在部署窗口重新发现。

本次已观察的文件 SHA256 与来源记录见 [v80-reference-audit.json](configs/v80-reference-audit.json)。该文件是审查快照，实施时还需冻结完整构建输入和实际镜像。

## 3. 首版硬件与软件结构

```text
Host runtime ── BAR2 ── openTPU 控制 / 参数 / 完成 / 错误 / 周期计数
     │                            │
     │                      单 slice openTPU
     │                    Sequencer / IMEM
     │                 MXU / VPU / Quant / TMEM
     │                            │ A / B / SW
     │                     native → AXI4 桥
     │                            │
     │                 地址映射 / 位宽转换 / CDC
     │                            │
     └──── QDMA H2C/C2H ── NoC ── HBM

GPU ↔ Host staging ↔ QDMA ↔ V80 常驻专家池
```

主访存优先沿用 M3 已验证的 `1024-bit core → 512-bit memory AXI → NoC S08` 形态。原 RV_I/RV_D/RV_U 端口可保留平台通道并由合法空闲 AXI 主端驱动，用户逻辑中移除 RVCore；若裁减通道，则核对 NoC、时钟和启动配置后重新生成平台镜像。

### 3.1 访存桥是首个核心模块

固定上游提交的 [`otpu_slice.sv`](https://github.com/FeSens/openTPU/blob/506e81b1d297e22739dab5ecaeee684493d5c720/rtl/top/otpu_slice.sv) 使用请求/响应存储端口。`D=128` 时：

| 端口 | 接口含义 | AXI 桥要求 |
|---|---|---|
| A | 32 位 word 地址；读响应为包含所需 scale 的对齐 32 B 数据 | word 地址乘 4 转为 AXI 字节地址，提取正确返回行，保持响应顺序 |
| B | 32 位 word 地址；每次数据 128 B，附读 tag；写 mask 以 32 位 word 为单位 | word 地址乘 4，转换 WSTRB，保持返回 tag 与数据对应，处理背压 |
| SW | 32 位数据、4 位 byte enable 的标量写 | 支持部分写及与 B 口写的仲裁 |

指令中的 DRAM 地址及 `ld_addr` 为字节地址，slice 输出的 A/B/SW 地址已经右移 2 位。首版桥检查 word 地址高两位为零，防止超过 4 GiB 的地址被截断。

首版限制桥的在途事务数，先通过随机背压和可变响应延迟验证，再扩大 outstanding。A/B/SW 的 ready、队列、仲裁和返回必须符合上游协议；尤其 ready 不依赖本周期请求形成组合环。

`rd_idle/wr_idle` 覆盖桥内缓冲及已经接受的 AXI 事务，写完成包含 B 响应。仿真覆盖不同地址、tag、部分写、4 KiB 边界、AXI 错误、启动/停止与旧响应排空。程序最终同步与核内操作收尾、端口寄存器和 AXI 队列共同决定任务完成；完成状态发布后，Host 能读到完整输出。

### 3.2 时钟、TMEM 和器件实现

- 复用 M3 的控制 100 MHz、核 75 MHz、存储 AXI 400 MHz 组织；维持各域复位同步释放与 Clocking Wizard locked 条件。
- 上游 [`ypcb-00338:m4`](https://github.com/FeSens/openTPU/blob/506e81b1d297e22739dab5ecaeee684493d5c720/targets/ypcb-00338.toml) 使用 `TMEM_IMPL=3, TMEM_PMP=1`，需要与核时钟同源、相位关系确定的 2 倍频时钟。直接套用该配置会新增时钟与约束要求。
- 首版优先评估上游非倍频 TMEM 实现，例如 `TMEM_IMPL=0, TMEM_PMP=0`；相关 RPB/WPB、调度和派生参数由配置工具统一生成并验证。资源占用经 OOC 综合确认后冻结。后续采用倍频方案时，75/150 MHz 及相关 CDC、时序作为独立变更验收。
- 起点为 `S=1,D=128,MCOLS=4`。ACT/TMEM/IMEM 容量、WIN、SEQ_WC 等关联参数与软件程序生成保持一致，配置标识写入程序包与硬件能力寄存器。
- 上游有 generic、DSP48E1/DSP48E2 实现；V80 使用 Versal DSP58。先综合 generic 并检查 DSP/BRAM/LUT 映射、资源与时序，随后按需要实现 DSP58 技术映射及等价性验证。

### 3.3 地址容量与带宽预期

计算核首版逻辑地址为 32 位，映射到 `0x4000000000 + logical_addr`。M3 用户通路覆盖 HBM0_PC0、HBM0_PC1、HBM1_PC0、HBM1_PC1 四个 1 GiB 窗口，**所有核侧通道共享 4 GiB**。程序、权重、scale、输入、输出和临时区均需计入容量。QDMA 可见空间与核可达空间分别记录。

512-bit × 400 MHz 的单 AXI 通路理论单向带宽为 25.6 GB/s；D=128 的 B 口在 75 MHz、每周期传输一次时为 9.6 GB/s。实际值还受指令供数、桥内在途数、访存布局及背压影响。首版定位为功能原型；扩展后备专家池时再设计多通道、多 slice 或更宽地址。

### 3.4 程序与完成协议

openTPU 指令为 8×32-bit word。Host 上传原生指令包，配置加载地址和指令数，加载到 IMEM 后启动，并设置 R8～R15 运行参数。使用 SEQ_WC 时，WAITC 依赖元数据的加载路径也必须实现。原 LPU 的 RV32 ELF、入口 PC 和 mailbox 协议属于另一套用户逻辑。

共享契约明确：ABI/配置版本、程序与 sidecar 长度、对齐、校验、task ID、epoch、输入输出、专家池版本、完成与错误、周期计数。首版一次一个任务，启动前清旧状态，超时后停止接收新任务并按排空/复位流程恢复。

M3 BAR2 的 `0x10000/0x20000/0x30000` 分别是原 RUN/GPIO/状态窗口。新核在 `contracts/registers.yaml` 定义自己的布局和 ABI，保留平台诊断能力。CPM 的 **`CPM_PCIE1_PF1_BAR2_QDMA_AXCACHE=0`** 必须保留，并检查实际生成 IP 的有效属性，防止寄存器事务扩展后出现 SLVERR。

## 4. 目录与脚本安排

原有目录继续使用，本次补充 `hardware/vivado/filelists/` 和 `software/driver/backends/mock/`。前者保证 IP 打包、仿真和综合使用一致源码，后者支持无板卡的任务生命周期验证。

以下为模块与入口安排，已实现范围及实测结果见首轮实现报告：

| 位置 | 主要文件/职责 |
|---|---|
| `configs/` | `dependencies.lock.json`、`v80_smoke.toml`、平台与工具链配置 |
| `contracts/` | `registers.yaml`、`memory_map.yaml`、`task_abi.yaml`、`program_image.yaml` |
| `hardware/rtl/top/` | `v80_opentpu_wrapper.sv`：核、控制与桥封装 |
| `hardware/rtl/adapters/` | `otpu_mem_axi.sv`、控制寄存器、完成/错误锁存与计数 |
| `hardware/sim/` | 桥/控制/加载 testbench、随机 AXI 存储模型、核联调 |
| `hardware/vivado/filelists/` | 核、板级和仿真文件清单；显式选择器件实现 |
| `hardware/vivado/ip/`、`bd/` | `package_opentpu.tcl`、`v80_opentpu.tcl`；独立于原 LPU 打包入口 |
| `hardware/vivado/tcl/` | 创建工程、平台断言、OOC/综合/布局布线、报告和导出 |
| `hardware/scripts/build/` | `env.sh`、`preflight.sh`、`build.sh`、`package.sh`、镜像一致性核验 |
| `hardware/scripts/deploy/` | 设备检查、配套镜像核对、加载与恢复；显式传入板卡身份和镜像清单 |
| `software/driver/` | 常驻设备访问库、BAR/MMIO、H2C/C2H、对齐/超时/错误；mock 与 QDMA 后端 |
| `software/runtime/` | 程序/权重加载、submit/poll/wait/collect、缓冲与 epoch 管理 |
| `software/operators/`、`tools/` | GEMV/SwiGLU 程序生成、权重打包、golden 和结果比较 |
| `tests/` | 配置/数值/接口回归、板测、重复任务和故障恢复 |

参考 M3 的 `stage2/package_m3.tcl` 仍引用 `fpga/vcu1525/tcl/` helper 与 LPU filelist。提取通用方法时记录来源，新的打包脚本显式列出 openTPU 依赖。参考项目保持只读，构建输出统一进入本项目的 `hardware/vivado/projects/<target>/<build-id>/`。

## 5. 从源码到上板的整体步骤

| 步骤 | 工作与输出 | 验收条件 |
|---|---|---|
| 1. 冻结输入 | 引入固定 openTPU 提交与平台依赖；保存 commit、patch、文件清单及 SHA256；初始化本工程版本管理 | 可读源码、IP、工具和 license 条件明确；历史证据与新构建记录分开 |
| 2. 软件与核离线跑通 | 生成单 slice 配置；复用上游编码器/ISA 模拟器；生成 GEMV、SwiGLU 指令、权重和 golden | 同一配置下 ISA 与 RTL 结果对齐；程序包、依赖元数据可重复生成 |
| 3. 封装与接口仿真 | 实现访存桥、加载器控制、寄存器、完成与错误；mock driver 联调 | 背压、部分写、错误、连续启动、超时恢复通过；完成后数据可见 |
| 4. 构造 Vivado 工程 | 打包 openTPU IP；在 M3 平台工作副本替换用户逻辑；生成 BD、wrapper、IP、约束 | 干净目录可重建；validate_bd_design、地址/时钟/复位/BAR2 断言通过；无黑盒或缺失源码 |
| 5. 综合与实现 | 先 OOC 评估核与桥，再全平台综合、布局布线 | 审查 setup/hold/pulse、CDC、bus skew、DRC、资源及未约束路径；新层次约束匹配有效 |
| 6. 导出与离线打包 | 导出 XSA 与配套 BOOT/PLD；构建 AMC/AMR BIN；生成交付 manifest | XSA 内部镜像与交付 BOOT/PLD 一致，父 UUID/配置匹配，文件大小及 SHA256 完整 |
| 7. 板上验收 | 发现设备身份与当前状态，加载匹配镜像，检查管理/BAR/HBM；运行 PL DMA 小程序、GEMV、SwiGLU 与重复任务 | 新镜像独立通过；结果符合统一参考；权重预加载后可连续调用，无任务串扰 |
| 8. 常驻 driver 与 GPU 闭环 | 使用预分配缓冲、常驻 FD；接入 GPU staging、任务时间线和分段计时 | D2H/H2C/核执行/C2H/H2D 可拆分；固定路由 miss=0/1/2/4/8 后进入真实单层接入 |

步骤 2、3 的离线验证应先于长时间布局布线。已有板卡上的 Host↔HBM 检查可在使用窗口单独进行；M3 已移除 M2 ATG，首版 PL 读写验证可使用 openTPU DMA 小程序，额外 copy engine 按需要增加。

### 构建入口应具备的行为

`preflight.sh` 显式选择 Vivado/Vitis **2026.1**，核对 board part `xilinx.com:v80:part0:2.0`、器件 `xcv80-lsva4737-2MHP-e-S`、IP 来源和工具版本。本机 PATH 当前指向 2025.2，2026.1 安装位于 `/opt/Xilinx/Downloads/2026.1/`。AMC 需要 Arm R5 工具链；原 LPU 的 RV32 工具链无需进入新核程序的构建链。

`build.sh --check-only` 只创建新目录、重建 IP/BD 并做静态检查；`build.sh` 执行综合实现；`package.sh <build-dir>` 只做离线交付。各步骤保存实际命令、配置、日志和退出码，失败保留目录。生成工程不进入版本管理，Tcl、约束、filelist 和配置进入版本管理。

参考 M3 对 HBM 参考时钟引脚做过修正。新工程根据新顶层重新检查 XDC 对象匹配，保留必要 IP 约束；原项目 timing/CDC 报告提供检查模板。

### 镜像加载与恢复

BOOT/PLD/XSA/AMC 按同一构建成套归档。`write_hw_platform` 可能重新生成 PDI，应采用核对过的 XSA 内部配对镜像构建 AMC。PLD-only 更新以实际平台兼容检查为依据，包括 NoC/时钟/启动配置、父 UUID 和构建哈希。

M3 历史 PLD 为 43,977,952 B，大于记录中的 User2 分区 24,117,248 B；部署脚本按实际镜像与分区容量校验。首版使用平台已验证的运行时加载流程，Flash 写入和恢复单列入口。M4 已有在线运行记录，部署前重新读取当前驱动、镜像与队列状态，按所选平台版本加载匹配的一套产物。

### driver 与中断的实施顺序

功能冒烟可复用 `dma-ctl`、`dma-to-device`、`dma-from-device`。性能测试的 C/C++ 库持续打开设备和 BAR，处理短读写、EINTR、超时、缓冲生命周期及 MMIO 顺序；核对 QDMA 与 CUDA pinned buffer 的兼容性，需要中间拷贝时记录其成本。DMA 完成、核任务完成和 CUDA event 各自管理。

M4 已验证共享 PF1 MSI-X 用户中断，candidate004 驱动通过 `m4_irq_count`/`m4_irq_info` sysfs 接口支持 Host 阻塞等待。接入后遵循“先订阅、再使能/启动、读 cause、W1C 清除、重查完成状态”的流程；中断是完成检查的通知，一个任务可对应多个事件或合并通知。首版轮询 API 预留 wait 后端，后续保持上层任务接口稳定。

## 6. 首轮实验与退出条件

1. 原生 INT8：256×256 GEMV、512×2048 投影、2048→512→2048 SwiGLU。生成器覆盖实际量化/布局与转换过程，GPU 和 FPGA 使用同一数值参考。
2. 权重常驻：变化输入，连续执行至少 1000 次；覆盖任务 ID、epoch、复位/超时恢复。权重初次上传单独计时。
3. GPU 数据闭环：4/8/16/64 KiB，保存 D2H、Host copy、H2C、核执行、C2H、H2D 和 P50/P95/P99。
4. 单层协同：固定 top-k=8 与 gate weights，miss=0/1/2/4/8；串行作为正确性参考，再测异步并行和 join 等待。
5. 真实模型：一个 Qwen3.6 专家层、真实路由与连续生成；通过后扩展精度兼容和多层专家池。

原生 INT8 用于首轮功能与通信验证。现有 llama.cpp IQ4_XS 基线的正式收益比较，在量化语义、输入、placement 和任务范围对齐后开展。首个成功标准是“可重复计算、数值可核对、分段耗时可解释”；资源和实测带宽决定下一轮核规模。

## 7. 下一次实施的具体起点

先完成步骤 1～3：在本项目中引入固定上游与可读平台依赖，冻结 `v80_smoke` 非倍频配置，生成 GEMV 程序/golden，定义共享契约并实现访存桥和控制仿真。随后启动 Vivado 静态检查与 OOC 综合。中断后端和扩大 HBM 映射作为后续独立任务。

参考入口：[执行计划](execution-plan.md)、[M3 本地说明](/mnt/data/jiangcx/v80_bringup/rtl/fpga/v80/m3_lpumem/README.md)、[M3 历史验收](/mnt/data/jiangcx/v80_bringup/rtl/fpga/v80/m3_lpumem/evidence/acceptance.json)、[openTPU 固定源码](https://github.com/FeSens/openTPU/tree/506e81b1d297e22739dab5ecaeee684493d5c720)。
