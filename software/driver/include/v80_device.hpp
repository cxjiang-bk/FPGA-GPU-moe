#pragma once
#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <string>

namespace v80 {
class Device {
public:
    virtual ~Device() = default;
    virtual uint32_t read32(uint32_t offset) = 0;
    virtual void write32(uint32_t offset, uint32_t value) = 0;
    virtual void h2c(uint32_t logical_address, std::span<const std::byte> bytes) = 0;
    virtual void c2h(uint32_t logical_address, std::span<std::byte> bytes) = 0;
};

// Uses an already provisioned QDMA MM queue and the explicitly selected PF1 resource2.
// This class does not bind drivers, create queues, reset a board or load an image.
class QdmaDevice final : public Device {
public:
    QdmaDevice(const std::string& queue, const std::string& bar2_resource,
               uint64_t hbm_physical_base = 0x4000000000ull);
    ~QdmaDevice() override;
    QdmaDevice(const QdmaDevice&) = delete;
    QdmaDevice& operator=(const QdmaDevice&) = delete;
    uint32_t read32(uint32_t offset) override;
    void write32(uint32_t offset, uint32_t value) override;
    void h2c(uint32_t address, std::span<const std::byte> bytes) override;
    void c2h(uint32_t address, std::span<std::byte> bytes) override;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
} // namespace v80
