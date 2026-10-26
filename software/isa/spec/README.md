# 首版 ISA 与程序格式

指令编码和行为复用固定版本的 `third_party/openTPU/opentpu/isa.py` 与 `docs/isa.md`。每条指令为 8 个 32 位 word，以 little-endian 写入 `program.bin`；程序按 128 B 对齐并补零，加载数量以实际指令数计。

首轮程序使用 LD、QACT、MM、VOP、ST 和 HALT。核内 scoreboard 处理执行单元与存储依赖，HALT 等待窗口排空，板级控制继续等待 AXI 请求/响应排空。首版 SEQ_WC、DSTEP/STREAM、PAIR 关闭，单 slice 只使用 BAR 集体同步。

指令及加载寄存器使用字节地址；slice 外部 A/B/SW 使用 word 地址，桥负责乘 4 转换。程序包、运行参数、CFG_HASH 和任务 ABI 见根目录 `contracts/`。当前阶段复用上游编码器与 ISA simulator，量化数学参考与 RTL 对照分别保存。
