#include <stdint.h>

// __attribute__((used)) prevents the compiler from optimizing this function away.
// __attribute__((export_name...)) tells the linker to make it public.
__attribute__((used))
__attribute__((export_name("get_magic_number")))
int32_t get_magic_number(void) {
    return 42;
}