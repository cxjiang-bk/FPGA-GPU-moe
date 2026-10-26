#include "v80_buffer.hpp"
#include "v80_runtime.hpp"
#include <algorithm>
#include <fstream>
#include <iostream>
#include <vector>

namespace {
std::vector<std::byte> read_file(const char* path) {
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input) throw std::runtime_error("cannot open input file");
    const auto size = input.tellg();
    if (size < 0) throw std::runtime_error("cannot determine input length");
    std::vector<std::byte> bytes{size_t(size)};
    input.seekg(0);
    if (!input.read(reinterpret_cast<char*>(bytes.data()), size)) throw std::runtime_error("short input file");
    return bytes;
}
}
int main(int argc, char** argv) {
    if (argc != 11) {
        std::cerr << "Use software/tools/board_smoke.py with an explicit case, queue and BAR2.\n";
        return 2;
    }
    try {
        v80::QdmaDevice device(argv[1], argv[2]);
        const auto hash = uint32_t(std::stoul(argv[10], nullptr, 16));
        v80::Runtime runtime(device, hash); // verify image before the first HBM write
        auto image = read_file(argv[3]), golden = read_file(argv[4]);
        const auto address = uint32_t(std::stoul(argv[5]));
        const auto instructions = uint32_t(std::stoul(argv[6]));
        const auto output_address = uint32_t(std::stoul(argv[7]));
        const auto output_bytes = size_t(std::stoul(argv[8]));
        const auto repeats = unsigned(std::stoul(argv[9]));
        if (!repeats || repeats > 100000 || golden.size() != output_bytes ||
            uint64_t(address) + ((uint64_t(instructions)*32+127)&~127ull) > image.size())
            throw std::invalid_argument("invalid case extent or repeat count");
        v80::DmaBuffer upload(image.size()), output(output_bytes);
        std::copy(image.begin(), image.end(), upload.bytes().begin());
        device.h2c(0, upload.bytes());
        for (unsigned i=0; i<repeats; i++) {
            std::fill(output.bytes().begin(), output.bytes().end(), std::byte{0xa5});
            device.h2c(output_address, output.bytes());
            const auto begin = std::chrono::steady_clock::now();
            const auto task = runtime.submit({address,instructions,hash}, uint64_t(i)+1);
            const auto completion = runtime.wait(task, std::chrono::milliseconds(2000));
            if (completion.error) throw std::runtime_error("device task failed: " + std::to_string(completion.error));
            device.c2h(output_address, output.bytes());
            const double us = std::chrono::duration<double,std::micro>(std::chrono::steady_clock::now()-begin).count();
            if (!std::equal(golden.begin(), golden.end(), output.bytes().begin())) throw std::runtime_error("board output mismatch");
            std::cout << "{\"task\":" << task.id << ",\"epoch\":" << task.epoch
                      << ",\"bit_exact\":true,\"exec_cycles\":" << completion.execution_cycles
                      << ",\"total_cycles\":" << completion.total_cycles << ",\"host_us\":" << us << "}\n";
        }
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
