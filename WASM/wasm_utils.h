#pragma once

#define WASM_IMPORT(A, B) __attribute__((__import_module__((A)), __import_name__((B))))