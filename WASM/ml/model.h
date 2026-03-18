#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "core/wasm_utils.h"

namespace ml {

constexpr std::size_t kManifestPathCapacity = 512;
constexpr std::size_t kMaxDetections = 32;

enum Status : int32_t {
  kSuccess = 0,
  kNotFound = -1,
  kInvalidManifest = -2,
  kUnsupportedTask = -3,
  kRuntimeUnavailable = -4,
  kInvalidModel = -5,
  kNoFrameAvailable = -6,
  kInferenceFailed = -7,
  kUnsupportedBackend = -8,
  kBadRequest = -9,
};

struct OpenModelRequest {
  char manifest_path[kManifestPathCapacity];
  int32_t model_id;
  int32_t status;
};
static_assert(sizeof(OpenModelRequest) == 520, "OpenModelRequest layout changed");

struct Detection {
  int32_t class_id;
  float score;
  float x_min;
  float y_min;
  float x_max;
  float y_max;
};
static_assert(sizeof(Detection) == 24, "Detection layout changed");

struct RunLatestCameraFrameRequest {
  int32_t model_id;
  int32_t status;
  double frame_timestamp;
  int32_t image_width;
  int32_t image_height;
  int32_t detection_count;
  Detection detections[kMaxDetections];
};
static_assert(offsetof(RunLatestCameraFrameRequest, frame_timestamp) == 8,
              "RunLatestCameraFrameRequest timestamp offset changed");
static_assert(offsetof(RunLatestCameraFrameRequest, detections) == 28,
              "RunLatestCameraFrameRequest detections offset changed");

struct CloseModelRequest {
  int32_t model_id;
  int32_t status;
};
static_assert(sizeof(CloseModelRequest) == 8, "CloseModelRequest layout changed");

WASM_IMPORT("host", "ml_open_model") void ml_open_model(OpenModelRequest *request);
WASM_IMPORT("host", "ml_run_latest_camera_frame") void ml_run_latest_camera_frame(
    RunLatestCameraFrameRequest *request);
WASM_IMPORT("host", "ml_close_model") void ml_close_model(CloseModelRequest *request);

inline const char *status_name(int32_t status) {
  switch (status) {
    case kSuccess:
      return "success";
    case kNotFound:
      return "not_found";
    case kInvalidManifest:
      return "invalid_manifest";
    case kUnsupportedTask:
      return "unsupported_task";
    case kRuntimeUnavailable:
      return "runtime_unavailable";
    case kInvalidModel:
      return "invalid_model";
    case kNoFrameAvailable:
      return "no_frame_available";
    case kInferenceFailed:
      return "inference_failed";
    case kUnsupportedBackend:
      return "unsupported_backend";
    case kBadRequest:
      return "bad_request";
    default:
      return "unknown";
  }
}

inline OpenModelRequest make_open_model_request(const char *manifest_path) {
  OpenModelRequest request{};
  if (manifest_path && manifest_path[0] != '\0') {
    std::snprintf(request.manifest_path, sizeof(request.manifest_path), "%s", manifest_path);
  }
  return request;
}

inline int32_t open_model(const char *manifest_path, int32_t *out_model_id = nullptr) {
  OpenModelRequest request = make_open_model_request(manifest_path);
  ml_open_model(&request);
  if (out_model_id) {
    *out_model_id = request.model_id;
  }
  return request.status;
}

inline int32_t run_latest_camera_frame(int32_t model_id, RunLatestCameraFrameRequest *out_request) {
  if (!out_request) {
    return kBadRequest;
  }
  std::memset(out_request, 0, sizeof(*out_request));
  out_request->model_id = model_id;
  ml_run_latest_camera_frame(out_request);
  return out_request->status;
}

inline int32_t close_model(int32_t model_id) {
  CloseModelRequest request{};
  request.model_id = model_id;
  ml_close_model(&request);
  return request.status;
}

}  // namespace ml
