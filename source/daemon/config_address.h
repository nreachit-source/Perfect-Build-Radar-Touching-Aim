#ifndef CONFIG_ADDRESS_H
#define CONFIG_ADDRESS_H
#include <stdint.h>

/* Config values are RVAs below 4 GiB, otherwise preferred virtual
 * addresses. Runtime addresses are never accepted implicitly. */
static inline uint64_t config_runtime_address(uint64_t value,
                                              uint64_t base,
                                              uint64_t slide) {
    if (!value) return 0;
    uint64_t adjustment = value >= UINT64_C(0x100000000) ? slide : base;
    return value > UINT64_MAX - adjustment ? 0 : value + adjustment;
}
#endif
