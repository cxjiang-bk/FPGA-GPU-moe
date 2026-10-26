# RTL 回归

```bash
source hardware/scripts/build/env.sh
python3 software/tools/run_offline.py
```

`tb_mem_axi.sv` 验证独立 AXI 桥，包含三个固定 seed、随机 AXI 背压、部分写、地址边界、跨端口顺序及错误处理。

`tb_v80_core.sv` 实例化真实 openTPU slice、新控制器和 AXI 桥，从内存加载生成的原生程序，执行三组算子，核对重复任务、完成可见性、取消、超时、错误及恢复。`axi_memory_model.sv` 是支持独立 AW/W 握手与延迟 R/B 响应的测试模型。

结果按时间戳保存到 `results/offline-*/`，包含全部命令、配置、输入、权重、指令、ISA golden、RTL 内存、误差、log 与 manifest。回归比较整个已初始化内存区，检查精确结果和写入范围。仿真内存容量为 8 MiB，核配置与硬件 target 一致。
