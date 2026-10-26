#include "v80_device.hpp"
#include "v80_runtime.hpp"
#include "v80_mock.hpp"
#include "v80_config.h"
#include <array>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <unistd.h>

namespace {
int checks = 0;
void check(bool ok) { if (!ok) throw std::runtime_error("driver test failed"); checks++; }
template<class E, class F> void throws(F fn) {
    try { fn(); } catch (const E&) { checks++; return; }
    throw std::runtime_error("expected exception missing");
}
struct TempFile {
    char path[40] = "/tmp/v80-driver-test-XXXXXX";
    int fd = ::mkstemp(path);
    TempFile() { if (fd < 0) throw std::runtime_error("mkstemp"); }
    ~TempFile() { ::close(fd); ::unlink(path); }
};
}
int main() {
    using namespace v80;
    try {
        MockDevice mock(V80_CFG_ARCH_HASH);
        throws<std::runtime_error>([&] { Runtime wrong(mock, 123); });
        Runtime runtime(mock, V80_CFG_ARCH_HASH);
        Program program{4096, 5, V80_CFG_ARCH_HASH};
        const std::array<uint32_t, 8> arguments{1,2,3,4,5,6,7,8};
        auto task = runtime.submit(program, 0x1234567800000001ull, arguments);
        check(mock.read32(V80_REG_ARG7) == 8);
        throws<std::runtime_error>([&] { runtime.submit(program, 2); });
        mock.complete();
        auto completion = runtime.wait(task, std::chrono::milliseconds(10));
        check(completion.error == 0 && completion.execution_cycles == 100 && completion.total_cycles == 150);
        mock.regs[V80_REG_DONE_EPOCH/4]++;
        throws<std::runtime_error>([&] { runtime.wait(task, std::chrono::milliseconds(10)); });
        throws<std::invalid_argument>([&] { runtime.submit({4097,5,V80_CFG_ARCH_HASH}, 3); });
        throws<std::invalid_argument>([&] { runtime.submit({0xffffff80,5,V80_CFG_ARCH_HASH}, 3); });
        task = runtime.submit(program, 4);
        throws<std::runtime_error>([&] { runtime.wait(task, std::chrono::milliseconds(0)); });
        check(runtime.wait(task, std::chrono::milliseconds(10)).error == V80_ERR_ABORT);
        task = runtime.submit(program, 5); mock.complete();
        check(runtime.wait(task, std::chrono::milliseconds(10)).task.epoch == 1);
        // Exercise the real FD/mmap/pread/pwrite implementation against temporary files.
        TempFile dma, bar;
        check(::ftruncate(dma.fd, 2 << 20) == 0 && ::ftruncate(bar.fd, 0x11000) == 0);
        QdmaDevice file_backend(dma.path, bar.path, 0);
        file_backend.write32(0x80, 0xabcdef01);
        check(file_backend.read32(0x80) == 0xabcdef01);
        throws<std::out_of_range>([&] { file_backend.read32(3); });
        throws<std::out_of_range>([&] { file_backend.write32(4096, 0); });
        alignas(4096) std::array<std::byte, 8192> input{}, output{};
        for (size_t i=0; i<input.size(); i++) input[i] = std::byte(i ^ (i>>8));
        file_backend.h2c(128, input); file_backend.c2h(128, output); check(input == output);
        throws<std::out_of_range>([&] { file_backend.h2c(0xfffffff0, input); });
        throws<std::runtime_error>([&] { file_backend.c2h((2<<20)-16, output); });
        std::cout << "DRIVER_PASS checks=" << checks << '\n';
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
