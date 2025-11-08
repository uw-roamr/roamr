// wasm_host.c

#include <wasm3.h>
#include <string.h>

// 1. Forward-declare the Swift function we will call
void swiftHostPrintCallback(const char* str);

// 2. This is the helper function that does the actual work
//    (It's what swift_host_print used to be)
void do_host_print(IM3Runtime runtime, uint32_t ptr, uint32_t len) {
	
	uint32_t memSize = 0;
	// Get the WASM module's memory
	uint8_t *mem = m3_GetMemory(runtime, &memSize, 0);
	
	// Check for invalid memory access
	if (!mem || (ptr + len) > memSize || (ptr + len) < ptr) {
		swiftHostPrintCallback("Error: host_print with invalid pointer/length");
		return;
	}
	
	char buffer[len + 1];
	memcpy(buffer, mem + ptr, len);
	buffer[len] = 0; // Null-terminate
	
	// Call the actual Swift function
	swiftHostPrintCallback(buffer);
}

// 3. *** THIS IS THE FIX ***
//    This is the generic wrapper that Wasm3 will call.
//    It MUST match the 'M3RawCall' function type.
const void* host_print_wrapper(IM3Runtime runtime, IM3ImportContext _ctx, uint64_t* _sp, void* _mem) {
	
	// The "v(ii)" signature means two i32 args are on the stack.
	// Wasm3 puts arguments onto the stack pointer (_sp).
	
	// Read the arguments from the stack
	uint32_t ptr = (uint32_t) _sp[0];
	uint32_t len = (uint32_t) _sp[1];
	
	// Now call our helper function
	do_host_print(runtime, ptr, len);
	
	// "v" (void) return type means we return NULL
	return NULL;
}
