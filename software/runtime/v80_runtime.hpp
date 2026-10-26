#pragma once
#include "v80_device.hpp"
#include <array>
#include <chrono>

namespace v80 {
struct Program { uint32_t address, instructions, cfg_hash; };
struct Task { uint64_t id; uint32_t epoch; };
struct Completion { Task task; uint32_t error; uint64_t total_cycles, execution_cycles; };
class Runtime {
public:
    Runtime(Device& device, uint32_t expected_cfg_hash);
    Task submit(Program program, uint64_t id, const std::array<uint32_t, 8>& args = {});
    Completion wait(Task task, std::chrono::milliseconds timeout);
private:
    Device& device_;
    uint32_t cfg_hash_;
    uint64_t read64(uint32_t low_offset);
};
} // namespace v80
