#include "v80_device.hpp"
#include <algorithm>
#include <atomic>
#include <bit>
#include <cerrno>
#include <fcntl.h>
#include <limits>
#include <stdexcept>
#include <system_error>
#include <sys/mman.h>
#include <unistd.h>

namespace v80 {
static_assert(std::endian::native == std::endian::little, "V80 driver requires little-endian host");
namespace {
constexpr size_t window_bytes = 4096;
constexpr off_t window_offset = 0x10000;
void check_address(uint32_t address, size_t bytes) {
    if (bytes > (1ull << 32) - address)
        throw std::out_of_range("DMA extends outside the shared 4 GiB core window");
}
void check_register(uint32_t offset) {
    if ((offset & 3u) || offset >= window_bytes)
        throw std::out_of_range("unaligned or out-of-window control register");
}
}
struct QdmaDevice::Impl {
    int read_fd = -1, write_fd = -1, bar_fd = -1;
    void* mapping = MAP_FAILED;
    uint64_t base;
    explicit Impl(uint64_t value) : base(value) {}
    ~Impl() {
        if (mapping != MAP_FAILED) ::munmap(mapping, window_bytes);
        if (bar_fd >= 0) ::close(bar_fd);
        if (write_fd >= 0) ::close(write_fd);
        if (read_fd >= 0) ::close(read_fd);
    }
};
QdmaDevice::QdmaDevice(const std::string& queue, const std::string& bar2, uint64_t base)
    : impl_(std::make_unique<Impl>(base)) {
    if (base > uint64_t(std::numeric_limits<off_t>::max()) - (1ull << 32))
        throw std::out_of_range("HBM base exceeds off_t range");
    impl_->read_fd = ::open(queue.c_str(), O_RDWR | O_CLOEXEC);
    if (impl_->read_fd < 0) throw std::system_error(errno, std::generic_category(), "open QDMA read queue");
    impl_->write_fd = ::open(queue.c_str(), O_RDWR | O_CLOEXEC);
    if (impl_->write_fd < 0) throw std::system_error(errno, std::generic_category(), "open QDMA write queue");
    impl_->bar_fd = ::open(bar2.c_str(), O_RDWR | O_SYNC | O_CLOEXEC);
    if (impl_->bar_fd < 0) throw std::system_error(errno, std::generic_category(), "open PF1 BAR2");
    impl_->mapping = ::mmap(nullptr, window_bytes, PROT_READ | PROT_WRITE, MAP_SHARED,
                            impl_->bar_fd, window_offset);
    if (impl_->mapping == MAP_FAILED) throw std::system_error(errno, std::generic_category(), "mmap control window");
}
QdmaDevice::~QdmaDevice() = default;
uint32_t QdmaDevice::read32(uint32_t offset) {
    check_register(offset);
    const auto p = reinterpret_cast<volatile uint32_t*>(static_cast<std::byte*>(impl_->mapping) + offset);
    const uint32_t value = *p;
    std::atomic_thread_fence(std::memory_order_seq_cst);
    return value;
}
void QdmaDevice::write32(uint32_t offset, uint32_t value) {
    check_register(offset);
    auto p = reinterpret_cast<volatile uint32_t*>(static_cast<std::byte*>(impl_->mapping) + offset);
    std::atomic_thread_fence(std::memory_order_seq_cst);
    *p = value;
    std::atomic_thread_fence(std::memory_order_seq_cst);
    // Readback flushes posted MMIO writes before a later task operation.
    (void)read32(0x10);
}
void QdmaDevice::h2c(uint32_t address, std::span<const std::byte> bytes) {
    check_address(address, bytes.size());
    size_t done = 0;
    while (done < bytes.size()) {
        const size_t count = std::min(bytes.size() - done, size_t(1u << 20));
        const auto n = ::pwrite(impl_->write_fd, bytes.data() + done, count, off_t(impl_->base + address + done));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) throw std::system_error(errno, std::generic_category(), "QDMA H2C");
        if (n == 0) throw std::runtime_error("QDMA H2C made no progress");
        done += size_t(n);
    }
}
void QdmaDevice::c2h(uint32_t address, std::span<std::byte> bytes) {
    check_address(address, bytes.size());
    size_t done = 0;
    while (done < bytes.size()) {
        const size_t count = std::min(bytes.size() - done, size_t(1u << 20));
        const auto n = ::pread(impl_->read_fd, bytes.data() + done, count, off_t(impl_->base + address + done));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) throw std::system_error(errno, std::generic_category(), "QDMA C2H");
        if (n == 0) throw std::runtime_error("QDMA C2H reached EOF");
        done += size_t(n);
    }
}
} // namespace v80
