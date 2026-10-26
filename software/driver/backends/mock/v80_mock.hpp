#pragma once
#include "v80_device.hpp"
#include "v80_regs.h"
#include <algorithm>
#include <array>
#include <stdexcept>
#include <vector>

namespace v80 {
// Host API test double. Computation and timing are validated by RTL, not by this backend.
class MockDevice final : public Device {
public:
    std::array<uint32_t, 1024> regs{};
    std::vector<std::byte> memory;
    explicit MockDevice(uint32_t cfg_hash, size_t bytes = 2 << 20) : memory(bytes) {
        regs[V80_REG_ID/4] = V80_DEVICE_ID;
        regs[V80_REG_ABI/4] = V80_ABI_VERSION;
        regs[V80_REG_CFG_HASH/4] = cfg_hash;
    }
    uint32_t read32(uint32_t offset) override { check_reg(offset); return regs[offset/4]; }
    void write32(uint32_t offset, uint32_t value) override {
        check_reg(offset);
        if (offset != V80_REG_COMMAND) { regs[offset/4] = value; return; }
        if (value == V80_CMD_CLEAR) { regs[V80_REG_STATUS/4] = 0; regs[V80_REG_ERROR/4] = 0; }
        else if (value == V80_CMD_RUN) {
            regs[V80_REG_STATUS/4] = V80_STATUS_BUSY;
            running_id_ = (uint64_t(regs[V80_REG_TASK_ID_HI/4]) << 32) | regs[V80_REG_TASK_ID_LO/4];
            running_epoch_ = regs[V80_REG_EPOCH/4];
        } else if (value == V80_CMD_ABORT) { complete(V80_ERR_ABORT); regs[V80_REG_EPOCH/4]++; }
    }
    void complete(uint32_t error = 0) {
        regs[V80_REG_DONE_ID_LO/4] = uint32_t(running_id_);
        regs[V80_REG_DONE_ID_HI/4] = uint32_t(running_id_ >> 32);
        regs[V80_REG_DONE_EPOCH/4] = running_epoch_;
        regs[V80_REG_STATUS/4] = V80_STATUS_DONE | (error ? V80_STATUS_ERROR : 0);
        regs[V80_REG_ERROR/4] = error;
        regs[V80_REG_TOTAL_CYCLES_LO/4] = 150;
        regs[V80_REG_EXEC_CYCLES_LO/4] = 100;
    }
    void h2c(uint32_t address, std::span<const std::byte> bytes) override {
        check_span(address, bytes.size()); std::copy(bytes.begin(), bytes.end(), memory.begin()+address);
    }
    void c2h(uint32_t address, std::span<std::byte> bytes) override {
        check_span(address, bytes.size()); std::copy_n(memory.begin()+address, bytes.size(), bytes.begin());
    }
private:
    uint64_t running_id_ = 0;
    uint32_t running_epoch_ = 0;
    static void check_reg(uint32_t offset) {
        if ((offset & 3) || offset >= 4096) throw std::out_of_range("invalid mock MMIO offset");
    }
    void check_span(uint32_t address, size_t size) const {
        if (address > memory.size() || size > memory.size()-address) throw std::out_of_range("invalid mock DMA range");
    }
};
}
