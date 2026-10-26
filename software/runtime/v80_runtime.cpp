#include "v80_runtime.hpp"
#include "v80_regs.h"
#include "v80_config.h"
#include <stdexcept>
#include <thread>

namespace v80 {
Runtime::Runtime(Device& device, uint32_t expected) : device_(device), cfg_hash_(expected) {
    if (device_.read32(V80_REG_ID) != V80_DEVICE_ID || device_.read32(V80_REG_ABI) != V80_ABI_VERSION)
        throw std::runtime_error("incompatible V80 control ABI");
    if (device_.read32(V80_REG_CFG_HASH) != expected) throw std::runtime_error("V80 configuration hash mismatch");
}
uint64_t Runtime::read64(uint32_t low) {
    for (;;) {
        const auto hi = device_.read32(low+4);
        const auto lo = device_.read32(low);
        if (hi == device_.read32(low+4)) return (uint64_t(hi) << 32) | lo;
    }
}
Task Runtime::submit(Program p, uint64_t id, const std::array<uint32_t, 8>& args) {
    if (p.cfg_hash != cfg_hash_ || p.address % 128 || !p.instructions || p.instructions > V80_CFG_IMEM_WORDS/8 ||
        uint64_t(p.address) + ((uint64_t(p.instructions)*32+127) & ~127ull) > (1ull << 32))
        throw std::invalid_argument("invalid or incompatible native program");
    if (device_.read32(V80_REG_STATUS) & V80_STATUS_BUSY) throw std::runtime_error("V80 task already in flight");
    device_.write32(V80_REG_COMMAND, V80_CMD_CLEAR);
    const auto clear_deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(100);
    while (device_.read32(V80_REG_STATUS) & (V80_STATUS_ERROR | V80_STATUS_DONE)) {
        if (std::chrono::steady_clock::now() >= clear_deadline) throw std::runtime_error("V80 status did not clear");
        std::this_thread::yield();
    }
    Task task{id, device_.read32(V80_REG_EPOCH)};
    device_.write32(V80_REG_TASK_ID_LO, uint32_t(id));
    device_.write32(V80_REG_TASK_ID_HI, uint32_t(id >> 32));
    device_.write32(V80_REG_PROGRAM_ADDR, p.address);
    device_.write32(V80_REG_PROGRAM_COUNT, p.instructions);
    for (size_t i = 0; i < args.size(); i++) device_.write32(V80_REG_ARG0 + uint32_t(4*i), args[i]);
    device_.write32(V80_REG_COMMAND, V80_CMD_RUN);
    return task;
}
Completion Runtime::wait(Task task, std::chrono::milliseconds timeout) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    for (;;) {
        const auto status = device_.read32(V80_REG_STATUS);
        if (status & V80_STATUS_DONE) {
            if ((status & V80_STATUS_BUSY) || read64(V80_REG_DONE_ID_LO) != task.id ||
                device_.read32(V80_REG_DONE_EPOCH) != task.epoch)
                throw std::runtime_error("stale or inconsistent V80 completion");
            return {task, device_.read32(V80_REG_ERROR), read64(V80_REG_TOTAL_CYCLES_LO),
                    read64(V80_REG_EXEC_CYCLES_LO)};
        }
        if (std::chrono::steady_clock::now() >= deadline) {
            if ((status & V80_STATUS_BUSY) && !(status & V80_STATUS_ERROR))
                device_.write32(V80_REG_COMMAND, V80_CMD_ABORT);
            throw std::runtime_error("V80 wait timeout; buffers must stay alive until drain or platform recovery");
        }
        std::this_thread::yield();
    }
}
} // namespace v80
