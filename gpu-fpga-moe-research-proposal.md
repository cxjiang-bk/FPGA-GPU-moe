# 面向长上下文混合专家推理的图形处理器–现场可编程门阵列分层专家执行

## 1. 核心问题与研究动机

现有 llama.cpp 通过将混合专家（Mixture of Experts, MoE）大语言模型（Large Language Model, LLM）的部分专家权重放入主机内存，使配备 16 GB 显存的图形处理器（Graphics Processing Unit, GPU）RTX 5080 能够运行 Qwen3.6-35B-A3B（总参数量约 350 亿、每个词元激活约 30 亿参数）以及最长 128K 上下文。该方法实现了模型的容量适配，显存缺口对应的运行时代价则由主机专家服务路径承担。随着上下文增长，键值缓存（Key–Value Cache, KV cache）和运行时工作区占用更多显存；为了维持可运行的配置，系统必须减少 GPU 常驻专家、压缩 GPU 专家缓存预算，或者牺牲并发空间。

这一瓶颈沿“显存容量—专家放置—后备执行”逐级传导：长上下文首先挤压 GPU 常驻专家和专家缓存的显存预算，使更多专家权重驻留在主机（Host），或使 GPU cache 只能覆盖部分专家工作集；被选中的 Host 专家随后需要由中央处理器（Central Processing Unit, CPU）计算，或者先从主机双倍数据率内存（Double Data Rate, DDR）读取完整权重，再通过高速串行计算机扩展总线（Peripheral Component Interconnect Express, PCIe）进行主机到设备传输（Host-to-Device, H2D）后由 GPU 计算，最终使逐词元生成阶段（decode）的瓶颈从 GPU 计算转向 CPU、Host DDR 和 PCIe 组成的主机专家服务路径。

完整的问题与方案逻辑链如下：

```text
显存受限的 GPU–Host 异构部署
        ↓
长上下文增大 KV cache 和运行时工作区
        ↓
GPU 常驻专家与专家 cache 的显存预算下降
        ↓
更多专家权重驻留 Host，或 cache miss 增加
        ↓
Host 专家进入两类后备路径
        ├─ CPU 路径：Host DDR 读取权重 → CPU MoE
        └─ GPU miss 路径：Host DDR 读取完整专家权重 → PCIe H2D → GPU 计算
        ↓
CPU、Host DDR 和 PCIe 进入 decode 关键路径
        ↓
引入可计算的 V80 后备专家层
        ├─ GPU cache hit → GPU 计算
        └─ GPU cache miss → 传输激活/路由信息 → V80 读取本地常驻权重并计算
        ↓
目标：以 V80 计算替代 CPU MoE，以激活往返替代完整专家权重 H2D，
      并使 GPU hit 与 V80 miss 两条分支重叠
```

这两类后备路径彼此独立，具体选择由专家放置和缓存状态决定。GPU 专家缓存关闭时，驻留主机的专家可由 CPU 计算；GPU 专家缓存开启时，命中专家留在 GPU，未命中专家需要上传权重后再由 GPU 计算。在混合放置和缓存覆盖部分专家工作集的情况下，CPU MoE 与专家权重传输也可能同时出现在端到端关键路径中。当前系统的核心矛盾源于有限显存需要同时容纳长上下文 KV cache、运行时工作区和专家权重，容量缺口最终由主机专家服务路径承担。

针对这一问题，本研究将 AMD V80 现场可编程门阵列（Field-Programmable Gate Array, FPGA）设计为兼具容量与计算能力的后备专家层。GPU 保留注意力计算（attention）、路由器及 top-k 专家选择（router/top-k）和缓存命中的热点专家；V80 的高带宽内存（High Bandwidth Memory, HBM）常驻其余后备专家，并直接执行 GPU cache 未命中的专家；CPU 负责控制和直接内存访问（Direct Memory Access, DMA）组织。router 完成后，GPU 命中专家与 V80 未命中专家并行执行，V80 接收当前层的隐状态向量（hidden state）、专家编号（expert identifier, ID）和门控权重（gate weight），在本地完成专家计算与加权聚合，再将部分结果返回 GPU 合并。

该设计同时替代现有的两类后备代价：其一，用 V80 专家计算替代 CPU MoE；其二，用小规模激活往返替代当前 token 的完整专家权重 H2D，并尝试将 V80 miss 路径隐藏在 GPU hit 计算之后。V80 带来的收益仍是需要验证的研究假设：只有当“激活发送、V80 专家计算和结果返回”的总时间小于 CPU MoE 路径或“Host 读权重、H2D 和 GPU miss 计算”路径，并且两设备能够有效重叠时，分层专家执行才能缩短关键路径。

![显存容量压力下的主机专家瓶颈与GPU-V80分层执行概念图](assets/gpu-v80-concept-swimlane.svg)

*图：A、B 是共享相同 router、GPU cache-hit 分支和结果合并的两种强化基线，分别用 CPU 计算和“上传权重后由 GPU 计算”处理 miss 专家；C 将 miss 分支替换为 V80 常驻专家计算。A、B 的并行重叠需要修改 llama.cpp，当前主线执行更为串行；三图横轴仅表示事件顺序，块长为设计示意。*

本研究聚焦上下文增长引发的显存容量效应，包括更多专家驻留主机、CPU MoE、专家权重传输，以及 GPU 专家缓存与 KV cache 的容量竞争；Attention 计算和 KV 读取开销作为系统背景与对照变量。第 2 节对比已有的近数据处理（Near-Data Processing, NDP）型 GPU 异构系统、GPU–CPU 和 GPU–FPGA MoE 工作并限定研究增量；第 4 节用已有实验逐项验证上述瓶颈，第 5～8 节再给出 GPU–V80 的对应机制、性能边界和验证方法。

## 2. 相关工作与研究定位

本研究与 GLITCHES 同样使用 GPU–FPGA 异构平台，但二者的任务划分粒度不同。[GLITCHES（GPU–FPGA LLM Inference Through a Collaborative Heterogeneous System）](https://ieeexplore.ieee.org/abstract/document/10938498) 将完整上下文处理阶段（prefill）放在 GPU、完整 decode 放在 FPGA，并在阶段切换时传递 KV cache，解决 GPU 对小批量（batch）decode 利用率较低以及 FPGA prefill 算力受限的问题。本研究保持 attention、router/top-k 和 cache-hit 专家在 GPU，在同一个 MoE 层内将 cache-miss 专家交给 V80；GPU 和 V80 处理同一 token 的不同专家分支。因此，GLITCHES 主要提供 GPU–FPGA 系统组织的参考，更直接的技术基础来自下述 GPU–NDP MoE 工作。

更直接的前置工作来自 GPU–NDP MoE 推理。这类系统通常通过计算快速互连（Compute Express Link, CXL）扩展内存，或者把 NDP 单元集成到双列直插式内存模块（Dual In-line Memory Module, DIMM）中，设备内存还可能采用低功耗双倍数据率内存（Low-Power Double Data Rate, LPDDR）。它们已经建立了“热点专家由 GPU 处理、其余专家在权重驻留处计算、设备间只传激活”的基本范式，即以激活传输（activation movement）替代完整专家参数传输（parameter movement）。本文使用 llama.cpp 的 GGUF 模型文件格式；下文以 GGUF 指代该格式及其量化语义。表中会议简称分别为设计自动化会议（Design Automation Conference, DAC）、欧洲设计自动化与测试会议（Design, Automation & Test in Europe Conference, DATE）和计算机辅助设计国际会议（International Conference on Computer-Aided Design, ICCAD）。下表按照与本研究的综合相关度由高到低排列；相关度综合考虑任务划分粒度、GPU 热点缓存与后备专家机制、目标部署场景以及真实 V80 平台验证四个方面。

| 工作 | 相关程度 | 异构执行方式 | 与本研究重合的基础 | 与本研究的主要差异 |
|---|---|---|---|---|
| [Context-Aware GPU–NDP](https://arxiv.org/html/2512.04476) | 极高 | 用 prefill 路由统计将热点专家固定在 GPU HBM，其余专家在 CXL-NDP 以 1～4 bit 执行 | 与“GPU 热点 cache + 完整后备专家层”的放置策略最接近，并显式重叠 GPU/NDP 执行 | 该工作采用模拟 NDP 和按专家混合精度；本研究聚焦 GGUF 量化语义及真实 GPU–FPGA 通信 |
| [Edge GPU–NDP Scheduling（DATE 2026）](https://arxiv.org/html/2601.03992) | 极高 | 面向 RTX 5080、批大小（batch size）为 1 和 Qwen3-30B-A3B，用 prefill 统计预取 GPU 热点专家，未命中专家由多块 NDP-DIMM 处理 | 目标平台、模型类型和本地显存受限场景均与本研究接近 | 该工作分别用 AttAcc! 和 Ramulator 对 RTX 5080 与 NDP-DIMM 建模；本研究面向商用板卡端到端实现，并考察 32K～128K context 对专家 cache 预算的挤压 |
| [MoNDE（Mixture of Near-Data Experts，DAC 2024）](https://arxiv.org/html/2405.18832) | 极高 | GPU 处理高负载专家，CXL 内存侧 NDP 处理冷专家；两侧并行，以 activation movement 替代冷专家权重搬运 | 给出了 GPU 热专家、后备设备冷专家和同层负载均衡的核心范式 | 该工作面向定制 CXL/LPDDR 架构，并主要通过 Ramulator 周期级模拟获得延迟；本研究面向商用 PCIe FPGA、llama.cpp 和长上下文实测 |
| [TriMoE](https://arxiv.org/html/2603.01058) | 高 | GPU、支持高级矩阵扩展（Advanced Matrix Extensions, AMX）的 CPU、DIMM-NDP 分别处理热、温、冷专家，并按预计完成时间调度 | 说明后备专家具有不同负载特征，并给出三设备并行和性能交叉点（crossover）调度思路 | 该工作通过周期精确模拟评估 DIMM-NDP；本研究测量 V80 低比特专家内核和真实 PCIe 小包同步代价 |
| [MoE-OPU（MoE FPGA 覆盖层处理器，ICCAD 2025）](https://ieeexplore.ieee.org/document/11240807) | 高 | 在 AMD V80 上以 FPGA 可重构覆盖层（overlay）执行 MoE，并针对专家负载不均、量化和稀疏性优化数据通路 | 证明 V80 HBM 与可定制数据流具备执行现代 MoE 专家的硬件基础 | 该工作以 V80 作为主要 MoE 执行平台；本研究将 V80 定位为 GPU cache 的实时后备协处理器，并实现 GPU hit/V80 miss 的同层分叉–汇合（fork–join）执行 |
| [Fiddler](https://arxiv.org/html/2402.07033) | 中 | 对 GPU 未驻留专家，在“传输激活后由 CPU 计算专家”和“上传权重后由 GPU 计算专家”之间选择 | 对应本文强化基线 A、B 的两类后备路径 | 该工作使用 CPU/DDR 或完整权重 H2D 承担后备计算；本研究增加具有独立 HBM 的 V80 协处理路径 |
| [GLITCHES](https://ieeexplore.ieee.org/abstract/document/10938498) | 较低 | GPU 执行完整 prefill，FPGA 执行完整 decode，并在阶段切换时传输 KV cache | 提供了真实 GPU–FPGA 系统组织和跨设备传输的实现参考 | 该工作按推理阶段划分任务；本研究按单层专家划分 GPU cache hit 与 V80 miss，并行执行后汇合 |

这些工作已经奠定 hot/cold expert 分层的基础，本研究进一步回答一个更具体的系统问题：如何在商用 RTX 5080 与 PCIe V80 上，把 GPU cache miss 实现为可运行、可并行且端到端有收益的 FPGA 专家服务路径。现有 GPU–NDP 工作主要采用架构建模或周期级模拟，MoE-OPU 则以真实 V80 承担主要 MoE 计算。本研究将 GPU 专家缓存与 V80 后备计算结合，并覆盖 llama.cpp/GGUF 的量化权重布局、经 Host 中转的 GPU–FPGA 通信、逐层小包 DMA 和同步，以及长上下文 KV cache 对专家缓存预算的挤压。

因此，本研究继承 MoNDE 的 activation-movement 思路和后续工作的热点放置方法，将研究重点放在真实 GPU–FPGA 实现、低比特专家数据流、双设备 fork-join 及长上下文容量压力下的端到端边界。TriMoE 进一步提示采用按负载选择的 miss 路径：首阶段让 V80 执行全部 miss，以隔离其服务能力；最终策略根据每个专家的 token 数、设备排队和实测 crossover，在 V80、CPU 计算与权重 H2D 后 GPU 计算之间选择。

## 3. 实验平台与基线构造

现有原型平台为 AMD Threadripper 9980X（64 核）、372 GiB 主机内存和 RTX 5080（16 GB），运行 llama.cpp 与采用 IQ4_XS 低比特量化格式的 Qwen3.6-35B-A3B 模型。服务器还安装了 V80 和 VCU1525；本研究拟首先使用具有 32 GB HBM 的 V80 保存量化专家权重并执行路由专家计算。

前期实验覆盖 2K～128K context 下的 prefill/decode、CPU/GPU 专家放置、GPU 专家缓存、CPU 核数限制和主机内存带宽限制。下文用于分析关键路径的核心 case 统一为：

| 项目 | 设置 |
|---|---|
| 模型 | Qwen3.6-35B-A3B，IQ4_XS |
| Context | 32K |
| CPU | 固定 8 个物理核 |
| Placement | 40 层中的后 16 层专家位于主机，其余可放置权重位于 GPU |
| GPU expert cache | 0 或 640 MiB |
| KV cache | GPU，16 位浮点（16-bit Floating Point, FP16；命令行参数记为 F16） |
| 性能数据 | Release 二进制 |
| 瓶颈归因 | NVIDIA Tools Extension（NVTX）标记和 NVIDIA Nsight Systems 分析器，对正式 prefill/decode 区间统计 |

8 核设置用于稳定放大 CPU MoE 和主机数据路径，实验结论限定为受限 x86 平台对照。内存竞争实验同样表示经实测带宽校准的受限 x86 环境；目标端侧片上系统（System on Chip, SoC）仍需独立验证。

## 4. 已有实验揭示的瓶颈

### 4.1 长上下文首先造成容量压力，并间接增加主机专家计算

在固定 fit32 placement 下，context 从 2K 增长到 32K 时，decode 吞吐由 171.51 降至 148.84 tok/s，下降 13.2%，反映了 KV 读取随上下文增长带来的代价。扩展到 128K 时，为给 KV cache 和运行时工作区留出显存，需要将主机专家层由 11 层增加到 16 层，decode 进一步降至 98.36 tok/s。此时性能下降同时包含更长 KV 访问和更多主机专家执行，说明长上下文会通过显存容量约束放大 MoE 卸载代价。

GPU 专家缓存能够缓解该问题，但它同样占用稀缺显存。16K、11 个主机专家层时，640 MiB cache 的专家命中率为 80.22%，吞吐只提高 2.91%；将所有专家置于主机并提供 6 GiB cache 的压力测试中，命中率达到 93.22%，吞吐提高到 2.01 倍。较大 cache 能提高命中率，却会直接挤占长上下文 KV cache 和并发请求的显存预算。

由此得到第一个瓶颈：当前系统使用同一份 GPU 显存同时承担 KV cache、运行时工作区和专家缓存，长上下文容量与专家命中率之间存在直接冲突。

### 4.2 GPU 专家缓存关闭时，CPU MoE 位于 decode 关键路径

在 32K、8 核、16 个主机专家层的 case 中，cache=0 的 Release decode 吞吐为 97.34 tok/s。对应的 64-token profile 墙钟为 1032.4 ms，其中 CPU MoE 累计 483.7 ms，占 46.9%。这说明主机除调度外，还承担了接近一半关键路径的专家计算。

该结果给出第二个瓶颈：当显存不足而专家直接在 CPU 执行时，CPU MoE 成为 decode 的主要限制；限制 CPU 核数后，这一问题更加突出。

### 4.3 GPU cache 将 CPU 瓶颈转化为专家 miss 传输

相同条件下启用 640 MiB GPU 专家缓存后，Release decode 吞吐从 97.34 提高到 131.10 tok/s，增幅为 34.7%。这一结果证明：将被选专家转移到 GPU 执行能够明显缩短 CPU MoE 路径。但 profile 同时显示，瓶颈只是发生了迁移：

| 32K、8C、fit128，64-token profile | cache=0 | cache=640 MiB | 变化含义 |
|---|---:|---:|---|
| Decode 墙钟 | 1032.4 ms | 746.8 ms | cache 取得净收益 |
| CPU MoE | 483.7 ms（46.9%） | 170.3 ms（22.8%） | 部分 CPU 专家计算转移到 GPU |
| 专家 miss H2D | 0 | 92.8 ms（12.4%） | 新增关键路径代价 |
| GPU kernel 并集 | 305.5 ms | 331.8 ms | GPU 承担更多专家计算 |
| routed-expert GPU kernel | 47.3 ms | 73.5 ms | 与计算位置转移一致 |

64 个 decode token 共上传约 4.33 GiB 专家权重，平均约 69 MiB/token；专家 H2D 与 GPU kernel 的实测重叠率为 0%。因此，当前 cache miss 的关键路径由“等待主机专家权重到达—执行本层 GPU 计算”构成，主要代价来自计算前的权重读取与传输。

这一归因还得到 DDR 限速对照的支持。保持 cache=640 MiB，将 triad 探针测得的有效内存带宽从 41.83 限制到 16.98 GB/s 后，Release decode 从 131.10 降至 89.43 tok/s，下降 31.8%；profile 中 CPU MoE 和专家 H2D 分别增加约 35% 和 33%，GPU kernel 时间则基本稳定。该变化将性能下降定位到主机内存读取、残余 CPU 专家计算和专家上传，GPU 计算时间的贡献较小。受限带宽组与原生带宽组的重复变异系数（Coefficient of Variation, CV）分别为 3.66% 和 5.34%；现有结果足以判断瓶颈所在，精确收益比例将在独占环境中复测。

由此得到第三个瓶颈：容量有限的 GPU cache 只能覆盖热点专家；未命中时需要沿关键路径搬运远大于激活的数据量，而且本层 router、权重传输和专家计算之间存在串行依赖。DDR 限速结果进一步将这一代价定位到主机专家服务路径，GPU kernel 时间则保持稳定。

## 5. 从已有瓶颈到 GPU–V80 设计

| 已有问题 | 实验证据 | GPU cache 的剩余约束 | GPU–V80 对应机制 | 应观察到的变化 |
|---|---|---|---|---|
| cache 与长上下文争夺显存 | 128K 需要增加主机专家层；大 cache 才有高命中率 | 增大 cache 会压缩 KV 和并发空间 | V80 的独立 HBM 保存完整后备专家，GPU 只保留预算内热点 | 相同 context 下减少 GPU cache 占用，或相同显存下支持更长 context/更多并发 |
| CPU 专家计算过重 | cache=0 时 CPU MoE 占 decode 墙钟 46.9% | cache 太小时仍保留 CPU MoE 或产生频繁 miss | characterization 阶段由 V80 执行全部 GPU miss；最终按实测 crossover 选择后备路径 | 在 V80 占优的负载区间内，CPU MoE 从关键路径消失 |
| miss 搬运专家权重 | cache640 上传 4.33 GiB/64 token，H2D 占 12.4%，重叠率 0% | 提高命中率需要继续增加显存 | V80 权重常驻，只传 hidden、专家 ID 和 gate weight | 专家权重 H2D 消失，跨设备流量降为激活规模 |

这张映射表限定了本研究的目标：GPU 继续承担高速专家计算，在固定 GPU 专家缓存预算下，由 V80 替换 cache miss 后的 CPU MoE 和专家权重上传。GPU cache hit 留在 RTX 5080 上执行，cache miss 专家进入 V80 路径。

### 5.1 单层两类 CPU–GPU 基线与 GPU–V80 路径泳道图

下面的三张泳道图只比较 placement 将 routed-expert 权重放在 Host 的单个 MoE 层。对于专家权重本来就常驻 GPU 的层，三种方案都由 GPU 完整计算，因此图中省略这些相同路径。事件按执行先后排列，块长采用示意比例；图中保留了 router 之后的同步点，以及经 Host 中转通信时使用的 pinned buffer。

![现有CPU-GPU卸载与GPU-V80分层专家执行泳道对比](assets/gpu-v80-bottleneck-swimlane.svg)

*图：三部分都以单个 Host-resident MoE 层为粒度，并且都只执行一次 router/top-k。A 是“GPU cache hit 与 CPU miss 并行”的强化基线，当前 token 只传输激活和 partial result；B 是“GPU cache hit 与 miss 专家权重 H2D 并行，随后由 GPU 计算 miss”的强化基线；C 保留相同的 GPU hit 分支，用 V80 常驻专家计算替代 CPU miss 或 miss 权重上传。A、B 都需要修改 llama.cpp 才能获得图示重叠；横轴表示执行先后，块长为设计示意。*

当前 llama.cpp 主线的 CPU 和 GPU 专家串行关系来自现有计算图和 scheduler 的实现方式。每层只构造一个 `MUL_MAT_ID`：该层的直接 cache-slot 路径关闭时，它读原始 host 权重并按普通 placement/op-offload 规则执行，在本实验 decode 中表现为 CPU MoE；cache slot 开启时，它读 GPU cache bank，先上传 miss 权重，再由 GPU backend 执行整个 op。因此当前的 cache miss 语义更接近 B，实际顺序为“完成 miss 上传—执行包含 hit 和 miss 的统一 GPU op”。图 B 所示的独立 GPU-hit 分支和传输重叠需要重构计算图；scheduler 还会按 split 顺序提交，并在跨 backend 和缓冲区复用时显式同步，因此并行执行需要将统一 op 拆成两条 expert 分支。

实现基线 A 需要在 router 之后根据 cache 状态拆分 expert IDs 和 gate weights；为 GPU hit 与 CPU miss 分别构造 MoE op；将 hidden/IDs/gates 通过设备到主机传输（Device-to-Host, D2H）异步送回主机；在 CPU 计算时并行执行 GPU hit 分支；再将 CPU 的 gate-weighted partial H2D 并在 GPU 求和。关键路径为 `max(T_gpu_hit, T_d2h + T_cpu_miss + T_h2d_partial) + T_merge`，当前 token 的跨设备流量由激活、路由信息和 partial result 构成。

实现基线 B 同样需要拆分 hit/miss expert IDs 和 gate weights，但 miss 分支从 Host DDR 读取整块专家权重并异步 H2D；GPU 先执行 hit 专家，等 DMA event 后再执行 miss 专家并合并。其关键路径为 `max(T_gpu_hit, T_host_read_weight + T_miss_weight_h2d) + T_gpu_miss + T_merge`。它与现有主线的 miss 处理语义一致，并新增 hit/H2D 重叠，可用于衡量“保留权重上传，只优化流水”的上限。已有 trace 给出的极端乐观端到端收益上限约为 10.9%。

基线 A 和 B 目前属于待测设计基线；已有 170.3 ms/64 token CPU MoE 和 92.8 ms/64 token miss H2D 是整段 decode 的跨层聚合值，只适合描述总体开销。二者共同构成 V80 方案的对照：A 衡量 CPU 计算 miss 并充分重叠时的性能，B 衡量保留权重搬运并充分重叠时的性能；C 则用 V80 本地 HBM 与计算同时消除 CPU MoE 和当前 token 的专家权重 H2D。

## 6. GPU 热点缓存与 V80 后备专家协同

每层 router 完成后，调度器将 top-k 专家划分为 GPU hit 和 GPU miss 两组：

1. GPU hit 专家直接读取 GPU cache 中的权重并计算，hidden 保留在 GPU；
2. GPU miss 分支将当前层 hidden、miss expert IDs 和 gate weights 发送到 V80，以激活传输替代阻塞式专家权重上传；
3. V80 从本地 HBM 读取量化权重，完成在线解量化、专家计算和 gate 加权，并返回一个 hidden 维度的聚合结果；
4. GPU 合并本地专家部分结果、V80 返回结果和 shared expert 结果，再进入下一模块；
5. GPU 与 V80 两组专家尽量并行，层延迟由两条路径中较慢者及最终同步决定。

第一阶段采用由冻结 router trace 得到的静态热点集合，关键路径只传输激活和路由信息，并让 V80 执行全部 GPU miss，以便单独验证 V80 服务能力。该设置用于 characterization，最终调度策略将进一步考虑复用收益和实测服务时间：当前 miss 可由 V80 立即服务；预测到足够复用时，系统在后台将专家提升到 GPU cache；低复用专家继续驻留 V80，从而控制阻塞式权重 H2D；当专家 token 数或 V80 排队使其服务时间超过 CPU/GPU 备选路径时，调度器选择更快的路径。

V80 需要以压缩格式保存专家权重，并实现与 IQ4_XS 或重新设计的等价低比特布局相匹配的在线解量化和矩阵向量计算。若将全部量化专家展开为 FP16，容量会超过 32 GB，因此“压缩权重驻留—在线解量化—专家计算—gate 聚合”应作为统一的数据流实现。

## 7. 数据流收益与性能边界

模型 hidden size 为 2048。按 FP16 计算，每个 V80 服务层需要约 4 KiB 输入 hidden，并返回约 4 KiB 聚合结果，专家 ID 和 gate weight 相比之下很小。若 V80 替代 fit128 中的 16 个主机专家层，则逻辑激活负载约为：

    16 × (4 KiB 输入 + 4 KiB 输出) = 128 KiB/token

当前 cache640 实测专家权重上传约为 69 MiB/token，逻辑负载相差超过 500 倍。若 GPU 与 V80 之间必须通过主机 pinned buffer 中转，同一激活会分别经过 GPU–Host 和 Host–V80 DMA，PCIe 总事务量约为 256 KiB/token；即便按这一口径，仍比现有专家权重上传低两个数量级。

数据量优势能否转化为端到端收益，还取决于执行时延。Decode 中 16 个专家层存在逐层依赖，小包 DMA 提交、同步、V80 量化计算以及 GPU 等待都可能成为新的关键路径。现有 cache640 profile 中，CPU MoE 与专家 miss H2D 合计为：

    (170.3 + 92.8) ms / 64 token ≈ 4.11 ms/token

因此可将 4.11 ms/token 作为首轮原型的粗略 break-even 预算：V80 完成 16 个后备专家层的计算、往返和同步若明显低于该值，才有机会超过现有 cache640；若希望端到端吞吐提高约 15%，该路径宜控制在约 2.5 ms/token 以内。该阈值来自带 profiling 开销的时间线，只用于原型筛选，最终收益必须由 Release 端到端实验确认。

另外，V80 调用率需要结合逐层 route set 分析。top-k=8 时，只要一个专家未命中，该层就可能调用 V80。因此实验还需统计每层 route set 全命中率、每个 token 触发 V80 的层数，以及每次 V80 调用包含的 miss 专家数量。

## 8. 研究假设与验证计划

本研究同时验证因果归因和最终吞吐。实验以每输出词元耗时（Time Per Output Token, TPOT）以及第 50、95 和 99 百分位时延（P50、P95 和 P99）描述时延分布：

| 假设 | 对照方法 | 关键指标 | 判定依据 |
|---|---|---|---|
| H1：V80 可消除 decode 的 CPU MoE | cache0 CPU–GPU vs. V80 后备 | CPU MoE、V80计算与等待时间 | CPU MoE退出关键路径，V80服务时间低于被替代时间 |
| H2：激活传输可替代专家权重 H2D | cache640 vs. GPU cache+V80 | 权重H2D、激活DMA字节、暴露传输时间 | miss权重H2D接近零，端到端传输等待下降 |
| H3：独立HBM可缓解显存容量冲突 | 不同context和并发下的cache640 vs. V80 | GPU显存、可运行context、并发slot、命中率 | 固定GPU cache容量时维持性能或扩大容量 |
| H4：V80路径降低对主机DDR的敏感度 | 原生/50%/25%有效DDR带宽 | tok/s、TPOT、P95/P99、DDR敏感度 | DDR降低时，异构方案退化小于CPU–GPU基线 |
| H5：GPU hit与V80 miss并行可隐藏部分后备开销 | 串行执行 vs. 双路径并行 | 两设备时间线、join等待、重叠率 | 端到端专家层时间接近两条路径时间的最大值 |

首轮实验聚焦 32K、8 核、16 个主机专家层的 decode，依次比较：

1. CPU–GPU、cache=0：暴露 CPU MoE 基线；
2. CPU–GPU、cache=640 MiB：现有最佳小缓存基线；
3. GPU cache关闭、全部后备专家由V80执行：隔离V80服务能力；
4. GPU热点cache与V80后备协同：验证最终设计。

各方案固定模型、输入、量化语义和 KV 设置，报告 Release 吞吐、TPOT、P50/P95/P99、GPU 显存、CPU 占用、主机 DDR 带宽、跨设备字节、V80 服务时间和设备同步等待；同时使用 NVTX/FPGA 时间戳构造统一时间线。正确性通过贪心输出、逐步 logits 或困惑度（Perplexity, PPL）回归验证。

首轮 decode 验证通过后，再扩展到 2K/32K/128K context、原生/8 核 CPU、不同 DDR 带宽和多请求并发。首阶段收益结论聚焦 decode，prefill 在后续扩展中验证；实验将分别报告专家相关传输与其他 placement 传输，并比较 ubatch=128/512 下的变化。

## 9. 预期贡献与适用边界

已有 GPU–NDP 工作已经提出热点专家由 GPU 执行、冷专家在权重驻留处计算，并以 activation movement 替代 parameter movement。本研究以这些方法为基础，将预期贡献集中在以下三个方面。

1. **商用 GPU–FPGA 上的可执行后备专家系统。** 在 RTX 5080 与 AMD V80 组成的真实 PCIe 平台上实现 MoE 层内的 expert-level fork-join：GPU 执行 cache-hit 专家，V80 以独立 HBM 保存并执行 cache-miss 专家，CPU 承担控制及经 Host 中转通信时的小规模激活搬运。该实现将实测逐层小包 DMA、Host pinned staging、设备排队、同步和结果合并，并判断这些系统代价对 activation movement 数据量优势的影响。

2. **面向 llama.cpp/GGUF 的低比特专家协处理数据流。** 将 Qwen3.6-35B-A3B 的量化专家以压缩格式驻留 V80 HBM，形成“路由信息接收—在线解量化—专家矩阵向量计算—gate 加权聚合—partial result 返回”的完整数据流，并在 llama.cpp 中实现 GPU hit 与 V80 miss 的异步调度。该贡献的核心是使 GGUF 量化语义、专家路由和跨设备执行在真实推理栈中保持一致，并用贪心输出、logits 或 PPL 回归验证正确性；FPGA 通用矩阵向量乘（General Matrix-Vector Multiplication, GEMV）是其中的计算基础。

3. **长上下文显存竞争下的实测边界与调度依据。** 以已有 2K～128K context、CPU 核数和 DDR 带宽实验为基础，联合测量 KV cache、GPU expert cache、CPU MoE、专家权重 H2D、V80 服务时间和双设备重叠，比较“CPU 计算 miss”“上传权重后 GPU 计算 miss”和“V80 常驻权重计算 miss”三条路径。实验将给出按专家 token 数、route-set 命中、设备排队和 context 长度划分的 crossover，以实测结果明确商用 GPU–FPGA 协同能够获得端到端收益的容量与负载条件。

如果上述三个目标得到验证，本研究将解决前期实验暴露的三项具体代价：CPU MoE、cache-miss 专家权重上传，以及专家 cache 与 KV cache 的显存竞争。研究增量集中在 GPU 热专家与后备设备冷专家机制在真实 RTX–V80 和 llama.cpp 栈中的实现、性能归因与适用边界。

本研究采用条件化性能判断。预期收益主要来自 CPU/DDR 受限、GPU cache 容量紧张、长上下文或多请求导致专家工作集超过显存预算，且 V80 专家服务能够与 GPU hit 有效重叠的场景。对于 GPU cache 命中率极高且显存充足的单请求 decode，GPU 独立执行可能更快；对于 token 数较多的温专家或 prefill，CPU/GPU 路径也可能优于 V80。研究将通过 break-even、三路径 crossover 和分场景实验明确 GPU–V80 协同的适用边界。

实验依据：[Qwen3.6 llama.cpp 系列实验总结](qwen36-llamacpp-final-summary.md)、[细化实验报告](refine-20261012-152810/summary.md)。

