# 验证目录

- `cases/`：小型固定输入、用例配置及 golden。
- `unit/`：ISA、算子与 driver 的局部验证。
- `integration/`：Host↔HBM、GPU↔V80 与单层 fork-join。
- `regression/`：连续请求、数值正确性和性能回归入口。

RTL testbench 与仿真工程入口位于 `hardware/sim/`。测试运行的输出、波形和日志保存到 `build/` 或时间戳结果目录。
