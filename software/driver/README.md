# V80 用户态访问与运行库

`v80_device.hpp` 定义 MMIO 和 DMA 接口；QDMA 后端持有常驻设备 FD 与 BAR2 映射，使用 `pread/pwrite` 完成 H2C/C2H，处理 EINTR、短传输、EOF、地址越界和清理。`DmaBuffer` 提供可复用的 4 KiB 对齐 Host 分配。

`software/runtime/` 提供配置校验、单任务 submit/wait、任务 ID/epoch 核对、硬件周期读取和 Host 超时处理。`mock/` 验证 Host API 状态；RTL 联调验证计算与硬件协议。

构建和离线测试：

```bash
source hardware/scripts/build/env.sh
cmake -S . -B build/host -DCMAKE_BUILD_TYPE=Release
cmake --build build/host -j 8
ctest --test-dir build/host --output-on-failure
```

输出为 `libv80_driver.a`、`v80-info`、`v80-smoke`。设备身份、内核驱动及队列由平台使用窗口提供；本库使用显式指定的 queue 和 PF1 `resource2`，程序本身保持队列与驱动配置。

板测入口是 `software/tools/board_smoke.py`：校验冻结用例文件的 SHA256，默认打印命令；传入 `--run` 后执行。运行库先检查新 openTPU 镜像的 ID/ABI/CFG_HASH，再上传权重、程序和输入；重复任务只更新输入输出缓冲，保存 JSONL 完成信息。原 M3/M4 LPU 镜像需要先替换为配套的新 openTPU 镜像。

首版支持单进程、单线程、单任务在途。Host 等待超时后，HBM 缓冲和任务资源应保留至排空或平台恢复完成。实际 QDMA/CUDA pinned buffer 兼容性、设备传输性能和中断后端待板测。
