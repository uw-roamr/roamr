#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <vector>

#include "ml/model.h"
#include "semantic/bbox_lidar_correspondence.h"

namespace semantic {

enum class FruitLabel : uint8_t {
  kUnknown = 0,
  kApple = 1,
  kOrange = 2,
};

struct FruitLandmark {
  uint64_t id = 0;
  FruitLabel label = FruitLabel::kUnknown;
  core::Vector3d world_point{};
  float mean_score = 0.0f;
  int32_t observation_count = 0;
  int32_t last_bbox_match_count = 0;
  int32_t last_inlier_count = 0;
  double first_timestamp = 0.0;
  double last_timestamp = 0.0;
};

struct FruitMapperConfig {
  const char* manifest_path = "detector_bundle/manifest.json";
  float apple_score_threshold = 0.35f;
  float orange_score_threshold = 0.35f;
  double max_frame_lidar_dt_sec = 0.20;
  double min_process_interval_sec = 0.25;
  double landmark_merge_radius_m = 0.18;
  int32_t min_reported_observations = 2;
};

class FruitMapper {
 public:
  FruitMapper() = default;
  ~FruitMapper() = default;

  bool initialize(const FruitMapperConfig& config = FruitMapperConfig{});
  void process_lidar_frame(
      const sensors::LidarCameraDataV2& lidar_data,
      const sensors::PoseLog& pose);

  bool initialized() const;
  uint64_t landmark_revision() const;
  void copy_landmarks(std::vector<FruitLandmark>* out_landmarks) const;
  void copy_reportable_landmarks(std::vector<FruitLandmark>* out_landmarks) const;

  static const char* label_name(FruitLabel label);

 private:
  struct CandidateDetection {
    FruitLabel label = FruitLabel::kUnknown;
    float score = 0.0f;
    ml::Detection detection{};
  };

  bool ensure_initialized() const;
  float score_threshold_for_label(FruitLabel label) const;
  void collect_candidate_detections(
      const ml::RunLatestCameraFrameRequest& request,
      std::vector<CandidateDetection>* out_candidates) const;
  void upsert_landmark(
      FruitLabel label,
      const core::Vector3d& world_point,
      float score,
      int32_t matched_points,
      int32_t inlier_points,
      double timestamp);
  void log_detection_skip(double frame_timestamp, double lidar_timestamp) const;

  FruitMapperConfig config_{};
  int32_t model_id_ = 0;
  mutable std::mutex landmarks_mutex_;
  std::vector<FruitLandmark> landmarks_;
  std::atomic<uint64_t> landmark_revision_{0};
  uint64_t next_landmark_id_ = 1;
  double last_processed_frame_timestamp_ = -1.0;
  double last_processed_lidar_timestamp_ = -1.0;
  mutable double last_timestamp_mismatch_log_timestamp_ = -1.0;
  bool initialized_ = false;
};

}  // namespace semantic
