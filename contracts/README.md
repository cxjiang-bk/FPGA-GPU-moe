# 软硬件共享契约

本目录保存任务 ABI、寄存器布局和内存映射的权威描述及版本。

当前契约：

- `task_abi.yaml`：任务标识、epoch、输入输出、专家信息、完成状态和错误码。
- `registers.yaml`：控制、状态、参数、能力和计数器的寄存器描述。
- `memory_map.yaml`：逻辑地址、HBM 物理窗口、保留区和分配约束。
- `program_image.yaml`：指令长度与对齐、可选 WAITC sidecar、R8～R15 参数、配置标识及程序包校验。

`software/tools/generate_contracts.py` 从寄存器契约生成 C、Python、RTL 和 Tcl 定义，输出到构建目录。上游 ISA opcode 保持在固定版本依赖中；首版使用原生指令与 scoreboard，SEQ_WC 关闭。

地址契约分别描述 BAR 偏移、核内 32 位逻辑地址和 QDMA 使用的 HBM 物理地址。完成契约覆盖程序结束、核内操作收尾、桥内队列和 AXI 写响应；复位/超时后的旧响应通过排空与 epoch 管理。具体要求见[移植审查](../v80-opentpu-porting-review.md)。
