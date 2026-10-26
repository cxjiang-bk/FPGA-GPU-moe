#include "v80_device.hpp"
#include "v80_regs.h"
#include <iostream>
int main(int argc, char** argv) {
    if (argc != 3) { std::cerr << "usage: v80-info /dev/qdma...-MM-N /sys/bus/pci/devices/BDF/resource2\n"; return 2; }
    try {
        v80::QdmaDevice device(argv[1], argv[2]);
        std::cout << std::hex << "id=0x" << device.read32(V80_REG_ID)
                  << " abi=0x" << device.read32(V80_REG_ABI)
                  << " cfg_hash=0x" << device.read32(V80_REG_CFG_HASH)
                  << " status=0x" << device.read32(V80_REG_STATUS) << '\n';
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
