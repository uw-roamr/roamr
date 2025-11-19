// Save this as add.c

#include <stdint.h> 

/**
 * C function matching the Wasm signature: (i32, i32) -> i32
 */
int32_t testadd(int32_t a, int32_t b) {
    return (a + b);
}