#include <stdio.h>
#include <stdlib.h>

int main() {
    // Attempt to allocate 10MB to demonstrate
    void* big_chunk = malloc(1 * 1024 * 1024); 
    if (big_chunk) {
        printf("Memory allocation successful.\n");
        free(big_chunk);
    } else {
        printf("Memory allocation failed.\n");
    }
    return 0;
}