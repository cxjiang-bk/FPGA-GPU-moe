# GPU–FPGA MoE 异构推理工程

工作根目录：`/mnt/data/jiangcx/FPGA-GPU-moe`。

本工程以 openTPU 为计算核基础，复用 V80 的 AMR/QDMA/HBM 平台，实现 GPU 热点专家与 FPGA 后备专家协同执行。首版采用单 slice openTPU 替换原 LPU/RVCore 用户逻辑，该选择已于 2026-10-26 确认。实施顺序见[执行计划](execution-plan.md)，接口注意事项与逐步交付见[V80 移植审查与上板步骤](v80-opentpu-porting-review.md)，研究背景见[proposal](gpu-fpga-moe-research-proposal.md)。

当前已完成依赖冻结、单 slice 配置与 ABI、GEMV/SwiGLU 程序生成、访存桥与控制 RTL、离线核联调、用户态 QDMA 库、核级 OOC 综合和平台 BD 检查。验证结果与后续任务见[首轮实现报告](bringup-status-20261026.md)。全平台布局布线、镜像打包和板测是下一阶段。

## 本地复现入口

```bash
source hardware/scripts/build/env.sh
python3 software/tools/dependencies.py
python3 software/tools/run_offline.py
cmake -S . -B build/host -DCMAKE_BUILD_TYPE=Release
cmake --build build/host -j 8
ctest --test-dir build/host --output-on-failure
bash hardware/scripts/build/build.sh --check-only
bash hardware/scripts/build/build.sh --ooc
```

本机仿真环境已位于 `.venv/`。新机器先创建 Python 环境并安装 `configs/requirements-smoke.txt`；依赖锁还记录 Python 版本与 Verilator 可执行文件 SHA256，版本变更经核对后显式更新。每次 RTL 回归和 Vivado 构建都建立新目录并保留命令与失败日志。

## 目录结构

```text
FPGA-GPU-moe/
├── README.md
├── execution-plan.md
├── v80-opentpu-porting-review.md
├── gpu-fpga-moe-research-proposal.md
│
├── hardware/                       硬件实现与上板工程
│   ├── rtl/
│   │   ├── top/                    V80 顶层与 openTPU 核封装
│   │   ├── adapters/               内部访存转 AXI、控制、完成状态与地址适配
│   │   ├── tech/                   Versal DSP58、RAM 等器件相关实现
│   │   └── common/                 通用 FIFO、寄存器、握手等模块
│   ├── sim/                        Testbench、仿真模型与运行脚本
│   ├── constraints/v80/            时钟、引脚、CDC 和布局约束
│   ├── vivado/
│   │   ├── filelists/              固定上游与本地 RTL 的综合/仿真文件清单
│   │   ├── tcl/                    创建工程、综合、实现与导出脚本
│   │   ├── bd/                     Block Design 的 Tcl 源码
│   │   ├── ip/                     自定义 IP 的封装描述与生成入口
│   │   └── projects/               生成的 Vivado 工程：.xpr、缓存、runs
│   ├── scripts/
│   │   ├── build/                  工具环境、依赖检查和构建调度
│   │   ├── deploy/                 PLD 加载、板卡检查与恢复脚本
│   │   └── debug/                  ILA、寄存器检查和板上诊断
│   └── artifacts/                  导出的 PDI/BIN/XSA、交付清单和报告
│
├── software/                       软件栈
│   ├── isa/
│   │   ├── spec/                   指令格式、操作语义、量化约定及扩展说明
│   │   ├── encoding/               指令编码/解码、汇编与反汇编适配
│   │   └── simulator/              ISA 模拟器接入与本地扩展参考
│   ├── compiler/                   算子降级、tile/buffer 分配及依赖生成
│   ├── operators/
│   │   ├── common/                 量化、布局、归约等公共算子组件
│   │   ├── gemv/                   首轮矩阵向量乘算子
│   │   ├── swiglu/                 Gate/Up、SiLU、Down 算子
│   │   └── moe/                    专家遍历、路由加权和部分结果聚合
│   ├── driver/
│   │   ├── include/                用户态 driver 的公开 C/C++ 接口
│   │   ├── src/                    设备、BAR、DMA、缓冲及错误处理
│   │   ├── backends/qdma/          官方 QDMA 驱动的用户态后端
│   │   ├── backends/mock/          离线验证任务、超时和错误处理的后端
│   │   └── tools/                  设备枚举、传输冒烟与状态诊断工具
│   ├── runtime/                    程序/专家加载、任务队列、submit/wait/collect
│   ├── integration/llama_cpp/      llama.cpp 接口层、补丁及集成说明
│   └── tools/                      权重转换、指令检查和结果分析工具
│
├── contracts/                      软硬件共享的任务 ABI、寄存器与内存约定
├── configs/                        核参数、平台版本、依赖锁定及实验配置
├── third_party/                    固定版本的 openTPU、AMR、QDMA 等依赖
├── tests/
│   ├── cases/                      小规模输入、配置与 golden
│   ├── unit/                       ISA、算子、driver 等单元验证
│   ├── integration/                Host↔HBM、GPU↔V80、单层 fork-join
│   └── regression/                 连续请求、模型正确性与性能回归
├── build/                          编译输出、指令程序及生成代码
└── results/                        按时间戳保存的实验、trace 与运行记录
```

目录说明与占位文件保留后续扩展位置；已实现文件及验证边界以首轮实现报告为准。

## 软件职责与调用关系

```text
llama.cpp / 测试程序
        ↓
runtime：专家池、任务与完成管理
        ↓
driver：设备访问、BAR、QDMA 传输
        ↓
官方 qdma-pf 内核驱动 → V80

operators → compiler → ISA 编码与依赖元数据 → 可加载程序
                          └→ ISA simulator / golden 验证
```

| 部分 | 负责的内容 |
|---|---|
| ISA | 定义与实现指令层面的编码、解释和数值契约 |
| compiler | 将算子表达转换为指令、存储布局和依赖信息 |
| operators | 描述 GEMV、SwiGLU、MoE 等计算及指令生成流程 |
| driver | 提供设备访问与数据传输，向上暴露稳定用户态 API |
| runtime | 加载程序和权重，管理任务生命周期及异步完成 |
| integration | 将 llama.cpp 的路由结果和张量接入 runtime |

首版 driver 使用固定版本的官方 QDMA 内核驱动及平台所需补丁，`software/driver/` 实现用户态访问库和后端适配。M4 用户中断依赖额外驱动改动，后续取得与镜像匹配的源码后接入；首版使用轮询完成。

## 源码与产物管理

1. **上游与本地代码分工。**openTPU 原始核、编译器和模拟器保存在固定提交的 `third_party/openTPU/`；本地适配放在 `hardware/`、`software/`。文件清单引用上游源码。确需修改上游时，在独立分支保存差异并记录提交与许可证。
2. **ISA 与接口各有权威来源。**既有 opcode 以固定版本的上游定义为准；本地扩展写入 `software/isa/spec/`。任务 ABI、寄存器布局和地址映射统一放在 `contracts/`，C/C++、Python 和 RTL 的派生定义由同一描述生成。
3. **Vivado 工程可重建。**`hardware/vivado/tcl/`、`bd/`、`ip/` 与约束进入版本管理；每次构建在 `hardware/vivado/projects/<target>/<build-id>/` 生成 `.xpr`、IP 缓存和实现目录。
4. **交付镜像成套归档。**`hardware/artifacts/<build-id>/` 保存匹配的 BOOT/PLD/XSA/AMC、SHA256、平台 UUID 和实现报告。构建脚本与上板脚本分别位于 `hardware/scripts/build/` 和 `deploy/`。
5. **集成适配与完整依赖分开。**`software/integration/llama_cpp/` 保存接入代码与补丁；完整 llama.cpp 工作副本位于 `third_party/llama.cpp/`，恢复已有 NVTX patch 与 router-trace 文件后再实施。
6. **生成结果按目录忽略。**编译缓存、大型镜像和实验原始产物分别进入 `build/`、`hardware/artifacts/`、`results/`。小型配置、测试向量及选定验收清单保留在版本管理中。

本工程已初始化 Git，开发分支为 `feature/v80-smoke`。openTPU 以固定提交的 submodule 引入，M3/AMR 复用部分保存为带来源与 SHA256 的选定源码快照。

初始平台审查见 `configs/v80-reference-audit.json`，当前依赖锁见 `configs/dependencies.lock.json`。现有 V80 参考工程、llama.cpp 和 proposal 保持原样。
