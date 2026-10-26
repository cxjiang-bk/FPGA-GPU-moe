# 硬件目录

本目录保存 V80 集成层源码、仿真、约束、Vivado 构建与上板脚本。

- `rtl/top/`：顶层连接与 openTPU 核封装。
- `rtl/adapters/`：内部存储协议转 AXI、BAR 控制、完成状态和地址转换。
- `rtl/tech/`：Versal 器件相关实现。
- `rtl/common/`：通用模块。
- `sim/`：模块级及平台接口仿真。
- `constraints/v80/`：XDC 和布局约束。
- `vivado/filelists/`：固定提交的上游 RTL、本地封装、技术实现及仿真文件清单。
- `vivado/tcl/`、`vivado/bd/`、`vivado/ip/`：可重建工程的源码入口。
- `vivado/projects/`：生成的 `.xpr` 工程与综合、实现目录。
- `scripts/build/`：环境选择与构建调度；调用 Vivado Tcl。
- `scripts/deploy/`：镜像核对、加载、基础回归和恢复入口。
- `scripts/debug/`：ILA 与板上诊断。
- `artifacts/`：配套镜像、校验清单和实现报告。

openTPU 核源码通过文件清单从 `../third_party/openTPU/` 引入。本地 RTL 与固定上游依赖共同构成综合输入。

首版以单 slice openTPU 替换 LPU/RVCore，复用 AMR/QDMA/NoC/HBM。原 M3 IP 打包脚本包含 LPU/VCU1525 文件清单依赖，新的封装采用独立文件清单。上游小配置中的 TMEM 2 倍频、存储桥和完成语义均需先在仿真中验证。

寄存器、任务 ABI 和内存约定见 `../contracts/`；实施顺序见[执行计划](../execution-plan.md)，详细边界及交付见[移植审查](../v80-opentpu-porting-review.md)。
