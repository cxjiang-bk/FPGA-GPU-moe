#pragma once
#include <cstddef>
#include <cstdlib>
#include <new>
#include <span>

namespace v80 {
// Page-aligned, reusable Host allocation. CUDA pinning compatibility is a board test.
class DmaBuffer {
public:
    explicit DmaBuffer(size_t bytes) : size_(bytes) {
        if (bytes && ::posix_memalign(&pointer_, 4096, bytes) != 0) throw std::bad_alloc();
    }
    ~DmaBuffer() { std::free(pointer_); }
    DmaBuffer(const DmaBuffer&) = delete;
    DmaBuffer& operator=(const DmaBuffer&) = delete;
    std::span<std::byte> bytes() { return {static_cast<std::byte*>(pointer_), size_}; }
private:
    void* pointer_ = nullptr;
    size_t size_;
};
}
