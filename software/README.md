# 软件目录

本目录按 ISA、编译、算子、设备访问、任务运行和框架接入分层。

| 目录 | 内容 |
|---|---|
| `isa/spec/` | 指令格式、操作语义、数值约定及本地扩展说明 |
| `isa/encoding/` | 上游编码器接入、汇编/反汇编工具和扩展编码 |
| `isa/simulator/` | ISA 模拟器接入与扩展指令参考 |
| `compiler/` | 降级、tile/buffer 分配、依赖生成与程序打包 |
| `operators/common/` | 公共量化、布局和归约组件 |
| `operators/gemv/` | 单算子冒烟入口 |
| `operators/swiglu/` | 专家三投影与激活流程 |
| `operators/moe/` | miss 专家遍历、路由加权与输出聚合 |
| `driver/` | 用户态设备访问库；`include/`、`src/`、`backends/qdma/`、`backends/mock/`、`tools/` |
| `runtime/` | 程序/权重加载、任务提交、等待、回收及错误恢复 |
| `integration/llama_cpp/` | 框架接入代码、补丁与集成说明 |
| `tools/` | 权重转换、输入导出、指令检查与结果分析 |

driver 向 runtime 提供 BAR 访问和 DMA 传输。runtime 向集成层提供 `load_experts`、`submit`、`wait`、`collect` 等任务级能力；具体 API 随契约落地。

上游编译器、编码器和模拟器优先从固定版本依赖复用，本目录保存适配与扩展。硬件和软件使用的 ABI、寄存器及地址布局统一见 `../contracts/`。

openTPU 运行自身指令程序。加载器处理指令、可选 WAITC 元数据、运行参数和配置校验；原 LPU 的 RV32 ELF 加载与 RUN PC 流程作为平台历史参考。功能冒烟可以调用 QDMA CLI；性能路径使用常驻进程、设备句柄和预分配缓冲。M4 中断作为可选后端，配套源码、驱动与镜像齐全后实施。
