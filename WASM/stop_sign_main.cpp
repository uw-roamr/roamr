#include <algorithm>
#include <chrono>
#include <cstdint>
#include <sstream>
#include <string>
#include <thread>

#include "controls/motors.h"
#include "core/telemetry.h"
#include "ml/model.h"

namespace {

constexpr const char* kDefaultManifestPath = "stop_sign_bundle/manifest.json";
// Update this to match the exported stop-sign class in your model bundle.
constexpr int32_t kStopSignClassId = 11;
constexpr float kStopScoreThreshold = 0.8f;
constexpr int32_t kStopHoldMs = 250;
constexpr int kLoopSleepMs = 100;
constexpr int kIdleRetrySleepMs = 50;

void write_stop_command() {
  const controls::MotorCommand stop{0, 0, kStopHoldMs};
  controls::write_motors(&stop);
}

bool has_stop_sign_detection(
    const ml::RunLatestCameraFrameRequest& request,
    float* out_best_score = nullptr) {
  float best_score = 0.0f;
  const int32_t max_count = static_cast<int32_t>(ml::kMaxDetections);
  const int32_t detection_count =
      std::max<int32_t>(0, std::min<int32_t>(request.detection_count, max_count));
  for (int32_t i = 0; i < detection_count; ++i) {
    const ml::Detection& detection = request.detections[i];
    if (detection.class_id != kStopSignClassId) {
      continue;
    }
    best_score = std::max(best_score, detection.score);
    if (detection.score >= kStopScoreThreshold) {
      if (out_best_score) {
        *out_best_score = best_score;
      }
      return true;
    }
  }
  if (out_best_score) {
    *out_best_score = best_score;
  }
  return false;
}

}  // namespace

int main() {
  wasm_log_line("[stop_sign] loading model bundle");

  int32_t model_id = 0;
  const int32_t open_status = ml::open_model(kDefaultManifestPath, &model_id);
  if (open_status != ml::kSuccess) {
    std::ostringstream log;
    log << "[stop_sign] failed to open model path=" << kDefaultManifestPath
        << " status=" << ml::status_name(open_status)
        << " code=" << open_status;
    wasm_log_line(log.str());
    return 1;
  }

  {
    std::ostringstream log;
    log << "[stop_sign] model ready id=" << model_id
        << " class_id=" << kStopSignClassId
        << " threshold=" << kStopScoreThreshold;
    wasm_log_line(log.str());
  }

  bool stop_latched = false;
  double last_log_timestamp = -1.0;

  while (true) {
    ml::RunLatestCameraFrameRequest request{};
    const int32_t status = ml::run_latest_camera_frame(model_id, &request);

    if (status == ml::kNoFrameAvailable) {
      std::this_thread::sleep_for(std::chrono::milliseconds(kIdleRetrySleepMs));
      continue;
    }

    if (status != ml::kSuccess) {
      std::ostringstream log;
      log << "[stop_sign] inference failed status=" << ml::status_name(status)
          << " code=" << status;
      wasm_log_line(log.str());
      std::this_thread::sleep_for(std::chrono::milliseconds(kLoopSleepMs));
      continue;
    }

    float best_score = 0.0f;
    const bool saw_stop = has_stop_sign_detection(request, &best_score);
    if (saw_stop) {
      write_stop_command();
      if (!stop_latched || request.frame_timestamp - last_log_timestamp >= 1.0) {
        std::ostringstream log;
        log << "[stop_sign] STOP score=" << best_score
            << " detections=" << request.detection_count
            << " frame_t=" << request.frame_timestamp;
        wasm_log_line(log.str());
        last_log_timestamp = request.frame_timestamp;
      }
      stop_latched = true;
    } else if (stop_latched && request.frame_timestamp - last_log_timestamp >= 1.0) {
      std::ostringstream log;
      log << "[stop_sign] clear frame_t=" << request.frame_timestamp;
      wasm_log_line(log.str());
      last_log_timestamp = request.frame_timestamp;
      stop_latched = false;
    }

    std::this_thread::sleep_for(std::chrono::milliseconds(kLoopSleepMs));
  }

  const int32_t close_status = ml::close_model(model_id);
  if (close_status != ml::kSuccess) {
    std::ostringstream log;
    log << "[stop_sign] close model status=" << ml::status_name(close_status)
        << " code=" << close_status;
    wasm_log_line(log.str());
  }
  return 0;
}
