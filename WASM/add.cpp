#include <stdint.h> // Required for the int32_t type

/**
 * We use extern "C" to prevent C++ from "mangling" the function name.
 * This ensures the function is exported as `add` and not a
 * complex C++-specific name (like `_Z3addii`).
 * The Swift code is looking for the simple name `add`.
 */
extern "C" {

/**
 * This C++ function matches the Wasm signature your Swift code expects:
 * It takes two 32-bit integers and returns one 32-bit integer.
 *
 * @param a The first integer.
 * @param b The second integer.
 * @return The result of our custom logic.
 */
int32_t testadd(int32_t a, int32_t b) {
    return (a + b);
}

} // extern "C"