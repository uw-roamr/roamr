#include "core/telemetry.h"
#include <algorithm>
#include <cstring>
#include <math.h>
#include <mutex>
#include <stdint.h>

void wasm_log_line(const char* text) {
  if (!text) {
    return;
  }
  WasmTextLog payload{};
  const size_t len = std::min(strlen(text), kWasmTextLogMaxBytes);
  if (len > 0) {
    memcpy(payload.text, text, len);
  }
  payload.text[len] = '\0';
  payload.length = static_cast<uint32_t>(len);
  wasm_log_text(&payload);
}

void wasm_log_line(const std::string& text) {
  wasm_log_line(text.c_str());
}

void log_config(const sensors::CameraConfig& cam_config){
  wasm_log_line("Sensor config initialized");
}
