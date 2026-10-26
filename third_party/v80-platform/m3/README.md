# M3：LPU 访存与 RMSNorm 上板

本目录保存可重建的集成源码、固定测试输入、离线验证脚本和 Host 测试。LPU/RVCore 内部源码继续使用仓库 `design/`、`include/` 中的原文件。

## 已验证架构

四路 `M_AXI/RV_I_AXI/RV_D_AXI/RV_U_AXI` 分别经过地址拼接和独立 SmartConnect 接入 NoC；LPU 主口由 1024 位转换为单路 512 位。地址映射为 `{8'h40, A[31:0]}`，使用 4 GiB HBM，范围 `0x4000000000..0x40ffffffff`。HBM_NMU 未启用。

| 时钟 | 来源 | 使用位置 |
|---|---|---|
| ctrl_clk，100 MHz | CIPS PL0 直连 | Host 控制入口及上游控制互连 |
| core_clk，75 MHz | PL1 → u_core_clk_gen | LPU、四路地址转换、RUN 和完成状态 |
| mem_axi_clk，400 MHz | PL0 → u_mem_clk_gen | 四路 SmartConnect 的内存侧、Register Slice、NoC 入口 |

两个 Clocking Wizard 的 locked 相与后接三个复位控制器的 dcm_locked。三个低有效 aux_reset_in 均为 1（不请求复位）；各域复位由 CIPS 复位和时钟稳定条件控制，并在各域同步释放。RUN_CTRL 软件复位与全局复位分开。

PF1 BAR2 的 RUN、GPIO、完成状态偏移依次为 `0x10000/0x20000/0x30000`，各占 4 KiB。BAR2 的 `CPM_PCIE1_PF1_BAR2_QDMA_AXCACHE=0`，避免控制寄存器事务被扩展；`stage6_impl/configure_bar2.tcl` 对此进行断言。END 和 DONE 分别锁存，STATUS 支持 W1C，同周期事件置位优先。

## 依赖与源码检查

使用 Vivado/Vitis 2026.1、V80 board files 2.0、有效的 Alveo/SMBus license。工具安装、驱动加载、烧录和板卡复位由操作者执行。源码已包含 M1 入库的 AMR 平台及 SMBus IP，不需要旧 M1 工程、镜像或日志。

`dependencies.json` 记录工具版本、operators 固定提交和测试数据来源；`source_manifest.json` 只保护原有 RTL/include 文件的内容，不要求仓库 HEAD 永远停在 M1。

```bash
python3 scripts/verify_sources.py
# 可选：仅在原历史产物仍存在时核验旧归档
python3 scripts/verify_sources.py --historical-manifest stage1/baseline_manifest.json
```

历史 manifest 不属于普通构建输入，也不入库。需要修改受保护源码时，应单独审查并更新基线，不能自动重算哈希掩盖变化。

## 从干净源码建立工程

先加载安装目录中的 Vivado 2026.1 `settings64.sh`，或设置 `VIVADO_BIN`；license 可通过 `XILINXD_LICENSE_FILE` 配置，也支持原机器 `../licenses/*.lic`。所有以下命令在本目录执行。

```bash
bash stage6_impl/run.sh --check-only
# 将上一条打印的 check_* 目录传入：
bash run_regression.sh /absolute/path/to/check_directory
```

该入口在新的 `stage6_impl/check_*` 下打包 IP、从 `stage3/m3_lpumem_export.tcl` 重建 BD、检查地址/时钟/复位/SMBus/BAR2 并生成输出。不会打开旧 `stage3/project`，也不会重新覆盖它。

仿真覆盖四路接口、W1C、两级 SmartConnect 控制译码、扩展读访问的负面用例及真实时钟/复位 IP。它使用模型化的 AXI 主端和内存从端，不代替完整 NoC/PCIe/HBM 或实际 LPU 算子执行。

```bash
bash stage6_impl/run.sh
```

不带参数才执行综合和布局布线，每次创建独立 `build_*`。`reports.tcl` 输出时序、CDC、总线偏斜及 DRC；结果收集、预打包检查和复核脚本位于 `stage6_impl/`。时序收敛不等于零 Warning，也不等于板上功能通过。

## 镜像生成

完成综合实现并审查报告后，设置 `VITIS_SETTINGS` 为 Vitis 2026.1 的 settings64.sh；必要时设置 `ARM_R5_TOOLCHAIN_BIN`，并确认 `bootgen` 可用。

```bash
bash stage6_impl/package.sh /absolute/path/to/build_directory
```

BOOT、PLD、XSA 必须来自同一构建。`package.sh` 包含 XSA 内部镜像一致性核验及 AMC 构建兼容处理；中断后可使用保留的 resume/finish 辅助脚本。本入口仅生成文件，不烧录。镜像保存在构建目录，不加入 Git。

## 算子与 Host 回归

operators 默认与 rtl 同级，也可设置 `OPERATORS_DIR`。固定提交见 `dependencies.json`；如同级存在 vLLM，也会核对其 forward_elf_contract.json。需要 GCC 13.2 RV32IM/ILP32 工具链可在 PATH 中找到。

```bash
bash rmsnorm_elf/build_rmsnorm.sh
python3 rmsnorm_elf/audit_elf.py
python3 m3_rmsnorm.py
```

最后一条为离线检查。固定输入和 Golden 保存在 `stage1/rmsnorm_smoke/extracted/`；seed=1、seq_len=8，来源提交及哈希见 dependencies.json。需要重新生成时使用仓库现有 `unit_test/rvcore_lpu_test/tools/run_operator_case.py --case ... --lpu-root ... --prepare-only`，模型版本须与清单一致。

板卡已加载配套镜像、驱动和队列就绪后，由操作者执行：

```bash
sudo python3 m3_ctrl_test.py --read-only
sudo python3 m3_rmsnorm.py --run
```

`host/qdma_hbm_loopback.sh` 保留已验证的专用板卡约束（BDF、序列号、驱动 srcversion、UUID），默认只检查；`--run/--resume` 会更改驱动/队列并写测试 HBM，必须由操作者显式执行。工具目录可通过 `QDMA_TOOLS_DIR` 设置。迁移板卡时应先审查这些约束。

## 验收与版本管理

`evidence/acceptance.json` 保存 2026-10-20 成功构建的镜像哈希、时序结果、HBM 回环及 RMSNorm 比较结果。RMSNorm 的 8192 个 BF16 元素与固定 Golden 逐位一致。原始构建、运行日志和镜像留在远端归档。

此次源码整理只改变重建与验证入口，不把历史板测结论冒充新构建的结论。重新生成镜像后需重新审查实现结果，并单独完成板测。

本目录 `.gitignore` 使用明确的源码/配置白名单，JSON 仅精确放行配置、依赖、源码基线和验收记录。新增正式文件时需同步调整白名单。生成工程、波形、ELF、PDI/XSA/DCP、运行记录、历史备份和飞书原始缓存不入库。
