# 综合与仿真文件清单

`v80_local.f` 列出本地计算 IP 源码。`software/tools/configure.py` 从固定上游 target API 生成 `build/generated/opentpu_core.f` 和参数 package。Vivado 输入快照将上游、参数和本地 RTL 合并到本次构建的 `inputs/sources.tcl`。

文件清单与配置一同生成构建输入 manifest。核联调使用相同的上游核与本地核心子系统，测试平台和存储模型另列；板级 wrapper 由 OOC 综合与平台 BD 检查验证。
