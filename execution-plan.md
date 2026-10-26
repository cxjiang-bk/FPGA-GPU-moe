# GPU–V80 异构原型执行计划

更新：2026-10-26。研究方案见 [proposal](gpu-fpga-moe-research-proposal.md)，详细工程边界、脚本安排及逐步验收见 [V80 移植审查与上板步骤](v80-opentpu-porting-review.md)。

当前已完成离线单算子、AXI/控制联调、用户态库测试、核级 OOC 综合和平台 BD 检查，详见[首轮实现报告](bringup-status-20261026.md)。全平台实现、配套镜像及新核板测继续按 P2 推进。

## 1. 首阶段目标

沿用已经跑通的 V80 平台，部署单 slice 的轻量 openTPU 核，依次完成单算子、GPU–V80 协同计算和真实模型单层接入。首个里程碑是得到一个能够连续运行、结果可核对、各段耗时可测量的异构系统。

首版架构已由用户确认：复用 M3 的 AMR/QDMA/NoC/HBM 和时钟复位，以单 slice openTPU 替换原 LPU/RVCore 用户逻辑，所有新实现与构建产物放在本工程。

“轻量”首先指计算核规模和卸载范围：一套小计算核、一个专家层、少量常驻专家。完整小模型可以选 Qwen3-0.6B 做补充演示；主线直接服务现有 Qwen3.6 的单层专家，逐步扩展后备专家池。

实施顺序：

```text
冻结平台与源码，生成程序/golden，完成核与访存桥仿真
    → Vivado 工程重建、综合实现与配套镜像
    → openTPU 单 slice 的 GEMV / SwiGLU
    → 常驻 driver 与 GPU–Host–V80 数据闭环
    → 固定路由的 GPU hit + V80 miss 单层协同
    → Qwen3.6 真实路由、单层卸载与连续生成
    → IQ4_XS 对齐、多层驻留和并行性能评估
```

首版采用 Host 中转、轮询完成和单请求 decode，复用上游计算模块与现有平台。先测出可运行系统的实际代价，再决定阵列扩展、DMA 流水和设备间直连的投入。

## 2. 已核对的基础与待交接项

### V80 平台

依据同学的[《V80上板适配：流程记录》](https://tju-opentpu.feishu.cn/wiki/WpVIwEqhdi06PLkKFe4c47XUn3d?from=from_copylink)，本次读取 revision **1066**，并核对 `/mnt/data/jiangcx/v80_bringup` 实际源码。M3 成功记录截至 2026-10-20；文档另包含后续 M4 中断验收：

| 项目 | 已有基础 | 本项目使用方式 |
|---|---|---|
| 工具与管理平台 | Vivado/Vitis 2026.1，AMR/AMI/AMC 3.0.0 | 固定相同版本，复用构建与管理流程 |
| 管理与数据通路 | PF0 为 AMI；PF1 为 QDMA，MM 双向队列，poll 模式 | 复用管理入口和 H2C/C2H 驱动 |
| 板上功能验证 | Host↔HBM 回环、PL 侧 HBM 读写、真实 LPU RMSNorm | 作为平台回归用例和接口参考 |
| 地址空间 | 用户逻辑 32 位地址，映射到 `0x4000000000 + logical_addr` | 首版测试池分配在已验证的 4 GiB 空间内 |
| 时钟 | 控制 100 MHz、LPU 核心 75 MHz、NoC 前端 AXI 400 MHz | 首版沿用已验证时钟组织，openTPU 核频率由实现确认 |
| 访存前端 | M3 主路经过 1024→512 位及 CDC，接入普通 NoC NMU | 复用 AXI/CDC/remap 结构，为 openTPU 定义独立封装 |
| 完成通知 | M3 状态锁存、轮询与清除；M4 已完成用户中断板测 | 首版自定义 openTPU 完成协议并轮询，后续取得配套 M4 源码/驱动后接中断 |

四路接口共享同一份 4 GiB 空间。512 位、400 MHz 的单个 AXI 接口理论单方向带宽为 **25.6 GB/s**；该值与板卡整片 HBM 峰值分别记录。首版以实测核供数带宽为依据。

本地 M3 工程为 `/mnt/data/jiangcx/v80_bringup/rtl/fpga/v80/m3_lpumem`，仓库 HEAD `abe224cc2802285414de20492b94041bd56d6704`。BD/Tcl、从干净目录重建、实现、打包及回归入口可读，保护清单检查通过：`protected=196`。历史成功构建为 `build_20261020_132052_718643`，镜像及验收结果记录在 `evidence/acceptance.json`；本次未重新构建或板测。

M2、license 目录和部分 M3 fixture 仍存在读取限制，完整工作树与历史产物审计待补。M4 源码、candidate004 驱动和镜像位于飞书记载的另一套交付目录，当前提供的本地 V80 目录未包含 M4。首版复用 M3 可读源码；中断接入单独交接，部署前重新确认在线板卡状态。审查快照见 [v80-reference-audit.json](configs/v80-reference-audit.json)。

当前 PATH 中的 Vivado 指向 2025.2；本机同时存在 `/opt/Xilinx/Downloads/2026.1/Vivado/bin/vivado`。构建入口应显式选择 2026.1 并保存版本输出。

### openTPU 与 llama.cpp

- openTPU 起始提交：`506e81b1d297e22739dab5ecaeee684493d5c720`，许可证 Apache-2.0。后续升级作为单独变更记录。
- 以该提交的单 slice、小配置为起点：`S=1`、`D=128`、`MCOLS=4`，其余关联参数通过上游 target 配置生成。
- 上游小配置含 `TMEM_PMP=1` 的 2 倍频需求。首版优先评估非倍频 TMEM 实现，统一生成关联参数并通过 ISA/RTL 与 OOC 资源验证后冻结；采用倍频方案时另加同源 2x 时钟与约束验收。
- 首轮采用上游原生 INT8 格式及配套量化参考，先验证计算与通信。IQ4_XS 兼容作为接入现有性能基线前的独立任务。
- llama.cpp 前期实验提交为 `8a1a9b5126126e5228b95fa909d4b08fac65e8b3`，已有 NVTX 修改和未跟踪的 `examples/router-trace/`。接入前重新记录当前 commit、导出 patch、未跟踪文件清单及 SHA256，再建立保留这些修改的隔离工作副本。

## 3. 分阶段任务与验收

下表 P0～P5 为本项目阶段编号，与同学平台记录中的 M1～M4 分开。

P1 的既有平台传输检查可以单独推进；P2 内的程序生成、核/桥仿真先于 Vivado 实现。完整 GPU 计算闭环在 openTPU 板测和常驻 driver 就绪后验收。

| 阶段 | 主要工作 | 进入下一阶段的条件 |
|---|---|---|
| P0：冻结可重建基线 | 交接平台源码、IP、Tcl、镜像及驱动接口；冻结 openTPU 和 llama.cpp；验证工具版本 | 工作副本依赖齐全，镜像配套关系明确，基础回归可复现 |
| P1：GPU–V80 数据通路 | GPU 产生输入，经 Host/QDMA 到 HBM，再返回 GPU；加入任务编号与超时 | 多种长度、变化输入、重复调用均正确，传输耗时可拆分 |
| P2：轻量 openTPU 上板 | 单 slice、访存适配、控制封装、GEMV 与 SwiGLU | ISA/RTL/板上结果按同一数值参考对齐，权重可一次加载后重复使用 |
| P3：单层异构执行 | 固定 hit/miss，GPU 与 V80 各算部分专家并合并 | 串行闭环通过，并能观察两条分支与汇合等待 |
| P4：真实模型接入 | Qwen3.6 的一个真实专家层、实际 top-k、连续生成 | 请求确实经过 V80，输出回归完成，连续运行稳定 |
| P5：扩展与性能比较 | IQ4_XS、多层专家池、通信重叠、32K 主 case | 与固定精度、输入和放置的 CPU–GPU 基线完成端到端比较 |

### P0：交接与冻结

从已可读的 M3 源码建立平台依赖快照，补齐实际构建需要的 IP、工具和 license 条件，保留原工程作为参考。交接内容包括顶层 BD/Tcl、自研 remap、时钟复位和 CDC、用户逻辑接入口、QDMA Host 代码、构建脚本、约束以及配套 BOOT/PLD/XSA/AMC 的校验清单。构建入口应能够从源码重新生成 IP 和工程目录。

固定当前板卡身份、BDF、平台 UUID、镜像 SHA256、驱动和工具版本。BDF、设备节点和队列编号由运行时发现，再与板卡身份对应；飞书中的编号用于核对历史记录。

在独立 openTPU 分支 `feature/v80-smoke` 中实施移植。llama.cpp 工作副本从当前 commit、tracked patch 与未跟踪 router-trace 文件共同恢复，完成差异核对后再修改。

**交付：**依赖锁定清单、平台接口清单、镜像清单和基础回归结果。

### P1：先跑通数据闭环

以 `GPU → Host buffer → QDMA/HBM → Host buffer → GPU` 为首版路径。先验证 QDMA HBM 回环。M3 已移除 M2 ATG；PL 主动读写用 P2 的 openTPU DMA 小程序验证，再串起 GPU 端数据生成与结果消费，额外 copy engine 按需要增加。

使用 4/8/16/64 KiB 数据，覆盖 2048 维 hidden 及小批输入；每组更换输入并执行至少 1000 次，记录超时、数据不一致和任务编号。实现计时应使用常驻进程、预分配缓冲和已打开设备句柄。

优先验证 CUDA pinned buffer 与 QDMA 驱动的兼容性。若两者需要不同 Host buffer，显式执行内存拷贝并记录这段耗时。GPU 与 V80 的状态同步通过 CUDA event、DMA 完成和设备任务完成分别表达。

**交付：**功能比较结果、D2H/H2C/C2H/H2D 与 Host 拷贝延迟，以及空载任务往返的 P50/P95/P99。

### P2：部署单 slice openTPU

首版保留 sequencer、MXU、必要 VPU、片上存储和上游程序生成工具，外围连接既有 V80 平台。V80 负责执行提交的计算程序，Host 负责管理和数据准备。

先完成配置、程序与 ISA/RTL golden，再实现桥/控制仿真；随后依次进行 IP/BD 重建检查、OOC 与全平台综合实现、匹配镜像打包和板测。具体脚本与验收见[上板步骤](v80-opentpu-porting-review.md)。

需要落实三项移植：

1. **访存桥。**openTPU 核内使用 A/B/SW 请求/响应式存储端口；增加适配器，将其转换为 AXI4 请求，经现有 CDC/remap/NoC 访问 HBM。覆盖返回 tag、部分写、背压、请求宽度、读写排空和错误应答。任务完成包含核内操作收尾与 AXI 写响应完成。
2. **器件实现。**上游提供 generic、DSP48E1、DSP48E2 实现。先评估 generic 在 V80 上的综合和小配置时序，再决定是否补充 DSP58 实现；等价性仿真覆盖被替换的计算单元。
3. **控制与运行时。**加载 openTPU 原生指令、可选 WAITC 元数据与运行参数，接入任务提交、状态、错误和完成寄存器，并适配上游 Host 传输抽象到 QDMA。新核定义自己的程序 ABI 和寄存器布局；平台 BAR2 保留 AXCACHE=0 并检查生成 IP 的有效配置。

使用原生 INT8 格式依次运行 256×256 GEMV、512×2048 投影和 2048→512→2048 SwiGLU。形状按上游量化块及存储布局对齐，权重和 scale 由配套转换工具生成。权重在初始化时上传，循环调用只更新输入与结果区。

**交付：**V80 target、适配 RTL、Host 接口、仿真与板上对照、时序/资源报告。原生整数计算及确定性转换对照上游精确参考，浮点模块另列误差与容限。

### P3：固定路由的 GPU hit / V80 miss

构造一个与 Qwen3.6 专家尺寸相同的独立 MoE 层：hidden=2048、中间维=512、top-k=8。先放入 8～16 个专家，以原生 INT8 量化参考生成 GPU 和 V80 两侧一致的测试数据。

固定路由与 gate weights，依次测试 miss 数 0/1/2/4/8。GPU 完成 hit 专家，V80 完成 miss 专家及 gate 加权聚合，GPU 收回部分结果后合并。miss=0 直接使用 GPU 输出；V80 按本次实际 miss 数判断任务完成。

先建立串行调度参考，再加入异步提交和 GPU hit 并行。路由权重沿用完整 top-k 的归一化结果，V80 直接计算 miss 子集的加权和。

**交付：**统一参考结果、真实 GPU/V80 分支时间线、各 miss 数下的服务时间和汇合等待。GPU 数值参考应复现同一量化/激活转换，误差比较同时记录最大绝对误差、相对误差和非有限数。

### P4：真实路由与单层连续生成

从 llama.cpp 的一个目标专家层导出真实输入、top-k 和 gate weights，先离线回放，再接入运行时。GPU 继续执行其余模块，V80 只承接选定层的后备专家。

功能演示可以先采用该层的原生 INT8 权重与激活路径；在参考执行中采用相同转换，结果标为近似原型。IQ4_XS 兼容路径验证后，再与原有 IQ4_XS 性能基线比较。完整小模型演示若需要，选择上游已支持的 Qwen3-0.6B，并沿用同一接口。

首个端到端 case 采用 2K prompt、固定 seed、greedy、生成 32～128 token；接着执行至少 10 次独立请求。prefill 首先沿用现有路径，decode 启用单层 V80 服务。首次预加载专家时机、模型状态和缓存初态明确记录。

**交付：**完整输入输出、V80 调用计数、路由/部分结果抽查、逐步 logits 或量化参考回归，以及真实执行的证明。设备超时通过任务状态显式结束该请求并保存现场，后续请求在完成恢复后启动。

### P5：对齐真实模型并扩大实验

支持 IQ4_XS 的码本、scale、布局与在线解码；离线重排仅改变存储布局，数值变换单独记录。先将一层全部 256 个专家常驻，再扩大到 2/4/16 个后备专家层。

单 slice 的 32 位寻址与既有平台的 4 GiB 映射是容量边界。16 层 IQ4_XS 专家约 6.4 GiB，全量约 15.9 GiB；扩展前明确选择多 slice 分配、bank/window 机制或更宽地址，并同步修改 Host 与硬件内存清单。

GPU 先采用冻结路由统计选出的静态热点集合，当前 miss 由 V80 服务。第一轮配置固定为 8C、32K、fit128、640 MiB GPU 专家预算，比较现有 CPU–GPU 路径、串行 V80 与并行 V80；再扩展 context 和并发。两种后备强化基线的实现顺序结合瓶颈测量安排。

**交付：**Release 吞吐、TPOT/P95/P99、显存与流量、冷/热状态，以及性能变化的时间线证据。

## 4. Host 与 FPGA 的最小任务契约

定义稳定的 Host API，底层使用常驻设备句柄、QDMA 和完成轮询；后续通过相同 API 扩展流水。以下名称是拟议接口：

```text
initialize(config)          建立设备上下文与预分配缓冲
load_experts(pool)          上传并登记常驻专家权重
submit(layer_task)          提交一层的 miss 任务，返回 handle
poll(handle) / wait(handle) 获得完成状态
collect(handle)             取回聚合后的部分结果
```

任务记录至少包含 ABI/配置版本、request/sequence/token/layer、任务编号及 epoch、输入输出位置和 dtype、专家池版本、miss IDs、gate weights 和有效长度。程序包另列指令、可选 WAITC sidecar、参数、长度、对齐和校验。完成记录包含同一任务标识、状态、错误码及硬件周期计数。输入、权重与输出在相应任务完成前保持有效。

首版将寄存器 start/done 与任务记录配合使用，每次启动先清旧状态；复位后更新 epoch。多缓冲和多个在途任务作为 P3 之后的增量。逻辑地址、QDMA 物理地址和 BAR 偏移分别定义。

数值接口首先使用 FP32 hidden 与 FP32 partial，2048 维单层往返逻辑数据约 **16 KiB**；采用 FP16 输入时为约 **12 KiB**。Host staging 下每段 PCIe 流量分别统计。具体转换位置服从量化参考与误差验证。

## 5. 测量、部署与工程交付

### 计时与验收口径

分别保存 GPU CUDA event、Host 单调时钟和 FPGA cycle counter；跨设备时间线通过请求事件建立对应关系。端到端延迟直接测量，分支重叠使用主机 NVTX/CUDA 与 FPGA 任务记录归因。Host 轮询观测延迟与核内运行周期分别报告。

最小矩阵为单请求、同一输入，miss 数 0/1/2/4/8，以及串行/并行调度。每组保存权重预加载时间、每次实际传输字节、队列等待、核执行、结果回收、汇合等待和失败记录。

性能分析采用 `max(T_GPU_hit, T_V80_service) + T_join` 作为分支模型，其中 V80 服务时间包含 Host/DMA、排队和计算。proposal 中约 4.11 ms/token 来自 profile 聚合标签，可作量级参考；可获得的收益以真实分支与 Release 端到端对照确定。

### 平台部署

优先沿用成功平台的 NoC、HBM、时钟、复位及管理通路，在隔离工程中接入计算核。修改后的 PLD 根据父 UUID、构建哈希与平台配置核验兼容性；涉及启动平台配置时，生成同一构建的 BOOT/PLD 配对产物。

板卡加载与队列操作在约定的使用窗口执行，保留已验证镜像和恢复入口。驱动安装、Flash 更新、重启及队列变更采用平台维护流程；本计划编写阶段只读取资料和环境信息。

### 工程目录

完整目录与职责见[仓库结构说明](README.md)。后续实现统一采用以下划分：

```text
FPGA-GPU-moe/
  gpu-fpga-moe-research-proposal.md
  execution-plan.md
  hardware/rtl/                       顶层、访存/控制适配与器件实现
  hardware/vivado/                    Tcl、BD、IP及生成的Vivado工程
  hardware/scripts/                   构建、上板与诊断脚本
  hardware/sim/                       RTL仿真与testbench
  hardware/constraints/v80/           时钟、CDC与布局约束
  hardware/artifacts/<build-id>/      成套镜像、SHA256及实现报告
  software/isa/                       指令格式、编码与模拟器接入
  software/compiler/                  算子降级、存储分配与依赖生成
  software/operators/                 GEMV、SwiGLU、MoE及公共组件
  software/driver/                    QDMA/BAR用户态访问与诊断
  software/runtime/                   程序/权重加载与任务API
  software/integration/llama_cpp/      框架接入代码与补丁
  contracts/                          共享任务ABI、寄存器与内存约定
  configs/                            核参数、平台及依赖版本
  third_party/                        固定上游依赖及隔离llama.cpp副本
  tests/                              用例、单元、集成及回归验证
  build/                              编译输出与生成程序
  results/<timestamp>/                manifest、命令、结果、trace与报告
```

每个阶段保存 commit、patch、未跟踪文件清单、配置、工具版本、镜像 SHA256、实际命令、原始结果和总结；运行结果进入独立时间戳目录。

## 6. 首轮执行清单

- [x] 审查本地 M3 可读源码与飞书 M4 记录，确认替换 LPU/RVCore 的首版架构。
- [ ] P0：建立本工程的固定依赖快照，补齐构建条件，冻结配套镜像与工具链。
- [x] 固定 openTPU 单 slice 配置，完成 GEMV、投影与 SwiGLU 的 ISA/RTL 逐字节对齐。
- [x] 完成核级 OOC 综合和完整平台 BD/地址/时钟/复位/IP 生成检查。
- [ ] P1：完成 GPU–Host–V80 数据闭环，测出空载往返与小包延迟。
- [ ] P2：完成轻量核的 AXI/控制封装，在 V80 重复运行 GEMV 和 SwiGLU。
- [ ] P3：运行 miss=0/1/2/4/8 的 GPU–V80 单层分流与合并。
- [ ] P4：接入真实路由与连续生成，形成首份异构系统运行报告。

## 参考入口

- [V80 平台流程记录，revision 1066](https://tju-opentpu.feishu.cn/wiki/WpVIwEqhdi06PLkKFe4c47XUn3d?from=from_copylink)：平台流程及 M3/M4 历史结果来源。
- [M3 本地工程说明](/mnt/data/jiangcx/v80_bringup/rtl/fpga/v80/m3_lpumem/README.md)、[本次源码审查快照](configs/v80-reference-audit.json)：实际可读工程与审查边界。
- [openTPU 固定提交](https://github.com/FeSens/openTPU/tree/506e81b1d297e22739dab5ecaeee684493d5c720)、[target/器件/平台划分](https://github.com/FeSens/openTPU/blob/506e81b1d297e22739dab5ecaeee684493d5c720/docs/targets.md)、[上游小配置](https://github.com/FeSens/openTPU/blob/506e81b1d297e22739dab5ecaeee684493d5c720/targets/ypcb-00338.toml)：移植结构和起始参数来源。
- [前期实验汇总](/mnt/data/jiangcx/llama-lab/results/qwen36-llamacpp-final-summary.md)、[细化实验报告](/mnt/data/jiangcx/llama-lab/results/refine-20261012-152810/summary.md)：研究基线与性能归因来源。
