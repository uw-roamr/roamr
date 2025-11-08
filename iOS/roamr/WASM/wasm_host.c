//
//  WASMHost.c
//  roamr
//
//  Created by Anders Tai on 2025-11-05.
//


#include <stdio.h>
#include <string.h>
#include "m3_api_defs.h"

// Forward-declare the Swift function we will call
// This function must be defined in Swift with @_silgen_name
void swiftHostPrintCallback(const char* str);

// This is the C function that Wasm3 calls
// Its name "swift_host_print" matches the bridging header
void swift_host_print(IM3Runtime runtime, uint32_t ptr, uint32_t len) {
    
    uint32_t memSize = 0;
    uint8_t *mem = m3_GetMemory(runtime, &memSize, 0);
    if (!mem || (ptr + len) > memSize) {
        // Invalid memory access
        return;
    }
    
    // Create a local buffer and copy the string
    // Add 1 for null terminator
    char buffer[len + 1];
    memcpy(buffer, mem + ptr, len);
    buffer[len] = 0; // Null-terminate the string
    
    // Call the Swift function
    swiftHostPrintCallback(buffer);
}