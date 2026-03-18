#include "semantic/semantic_mapper.h"

#include <algorithm>
#include <cmath>
#include <sstream>

#include "core/telemetry.h"

namespace semantic {
namespace {

// This detector bundle uses a COCO label list with "__background__" at index 0.
// That shifts apple/orange to 53/55 instead of the common 47/49 convention.
constexpr int32_t kAppleClassId = 53;
constexpr int32_t kOrangeClassId = 55;
constexpr size_t kMaxLandmarkFootprintPoints = 32;
constexpr double kFootprintMergeDistanceM = 0.03;

const char* detection_log_label(SemanticLabel label) {
  switch (label) {
    case SemanticLabel::kApple:
      return "APPLE DETECTED";
    case SemanticLabel::kOrange:
      return "ORANGE DETECTED";
    case SemanticLabel::kUnknown:
    default:
      return "SEMANTIC DETECTED";
  }
}

SemanticLabel semantic_label_from_class_id(int32_t class_id) {
  switch (class_id) {
    case kAppleClassId:
      return SemanticLabel::kApple;
    case kOrangeClassId:
      return SemanticLabel::kOrange;
    default:
      return SemanticLabel::kUnknown;
  }
}

double planar_distance_squared(
    const core::Vector3d& a,
    const core::Vector3d& b) {
  const double dx = a.x - b.x;
  const double dy = a.y - b.y;
  return dx * dx + dy * dy;
}

void merge_footprint_points(
    std::vector<core::Vector3d>* dst_points,
    const std::vector<core::Vector3d>& src_points) {
  if (!dst_points) {
    return;
  }
  const double merge_distance2 =
      kFootprintMergeDistanceM * kFootprintMergeDistanceM;
  for (const core::Vector3d& src_point : src_points) {
    bool already_present = false;
    for (const core::Vector3d& dst_point : *dst_points) {
      if (planar_distance_squared(dst_point, src_point) <= merge_distance2) {
        already_present = true;
        break;
      }
    }
    if (already_present) {
      continue;
    }
    if (dst_points->size() >= kMaxLandmarkFootprintPoints) {
      break;
    }
    dst_points->push_back(src_point);
  }
}

}  // namespace

bool SemanticMapper::initialize(const SemanticMapperConfig& config) {
  if (initialized_) {
    return true;
  }
  config_ = config;

  const int32_t open_status = ml::open_model(config_.manifest_path, &model_id_);
  if (open_status != ml::kSuccess) {
    std::ostringstream log;
    log << "[semantic] failed to open model path=" << config_.manifest_path
        << " status=" << ml::status_name(open_status)
        << " code=" << open_status;
    wasm_log_line(log.str());
    model_id_ = 0;
    initialized_ = false;
    return false;
  }

  std::ostringstream log;
  log << "[semantic] model ready id=" << model_id_
      << " manifest=" << config_.manifest_path
      << " apple_class=" << kAppleClassId
      << " orange_class=" << kOrangeClassId;
  wasm_log_line(log.str());
  initialized_ = true;
  return true;
}

bool SemanticMapper::initialized() const {
  return initialized_;
}

uint64_t SemanticMapper::landmark_revision() const {
  return landmark_revision_.load(std::memory_order_acquire);
}

void SemanticMapper::copy_landmarks(std::vector<SemanticLandmark>* out_landmarks) const {
  if (!out_landmarks) {
    return;
  }
  std::lock_guard<std::mutex> lk(landmarks_mutex_);
  *out_landmarks = landmarks_;
}

void SemanticMapper::copy_reportable_landmarks(
    std::vector<SemanticLandmark>* out_landmarks) const {
  if (!out_landmarks) {
    return;
  }
  std::lock_guard<std::mutex> lk(landmarks_mutex_);
  out_landmarks->clear();
  out_landmarks->reserve(landmarks_.size());
  for (const SemanticLandmark& landmark : landmarks_) {
    if (landmark.observation_count < config_.min_reported_observations) {
      continue;
    }
    out_landmarks->push_back(landmark);
  }
}

const char* SemanticMapper::label_name(SemanticLabel label) {
  switch (label) {
    case SemanticLabel::kApple:
      return "apple";
    case SemanticLabel::kOrange:
      return "orange";
    case SemanticLabel::kUnknown:
    default:
      return "unknown";
  }
}

bool SemanticMapper::ensure_initialized() const {
  return initialized_ && model_id_ > 0;
}

float SemanticMapper::score_threshold_for_label(SemanticLabel label) const {
  switch (label) {
    case SemanticLabel::kApple:
      return config_.apple_score_threshold;
    case SemanticLabel::kOrange:
      return config_.orange_score_threshold;
    case SemanticLabel::kUnknown:
    default:
      return 1.0f;
  }
}

void SemanticMapper::collect_candidate_detections(
    const ml::RunLatestCameraFrameRequest& request,
    std::vector<CandidateDetection>* out_candidates) const {
  if (!out_candidates) {
    return;
  }
  out_candidates->clear();
  const int32_t detection_count = std::max<int32_t>(
      0,
      std::min<int32_t>(
          request.detection_count,
          static_cast<int32_t>(ml::kMaxDetections)));
  for (int32_t i = 0; i < detection_count; ++i) {
    const ml::Detection& detection = request.detections[i];
    const SemanticLabel label = semantic_label_from_class_id(detection.class_id);
    if (label == SemanticLabel::kUnknown) {
      continue;
    }
    if (detection.score < score_threshold_for_label(label)) {
      continue;
    }
    CandidateDetection candidate{};
    candidate.label = label;
    candidate.score = detection.score;
    candidate.detection = detection;
    out_candidates->push_back(candidate);
  }
  std::sort(
      out_candidates->begin(),
      out_candidates->end(),
      [](const CandidateDetection& a, const CandidateDetection& b) {
        return a.score > b.score;
      });
}

void SemanticMapper::log_detection_skip(
    double frame_timestamp,
    double lidar_timestamp) const {
  if (frame_timestamp <= 0.0 || lidar_timestamp <= 0.0) {
    return;
  }
  const double anchor_timestamp = std::max(frame_timestamp, lidar_timestamp);
  if (last_timestamp_mismatch_log_timestamp_ > 0.0 &&
      (anchor_timestamp - last_timestamp_mismatch_log_timestamp_) < 1.0) {
    return;
  }
  std::ostringstream log;
  log << "[semantic] skipping frame due to timestamp mismatch frame_t="
      << frame_timestamp
      << " lidar_t=" << lidar_timestamp
      << " dt=" << std::fabs(frame_timestamp - lidar_timestamp);
  wasm_log_line(log.str());
  last_timestamp_mismatch_log_timestamp_ = anchor_timestamp;
}

void SemanticMapper::process_lidar_frame(
    const sensors::LidarCameraDataV2& lidar_data,
    const sensors::PoseLog& pose) {
  if (!ensure_initialized() ||
      !pose_log_valid(pose) ||
      lidar_data.timestamp <= 0.0 ||
      lidar_data.points_size == 0 ||
      lidar_data.pixel_coords_size == 0) {
    return;
  }
  if (last_processed_lidar_timestamp_ > 0.0 &&
      (lidar_data.timestamp - last_processed_lidar_timestamp_) <
          config_.min_process_interval_sec) {
    return;
  }

  ml::RunLatestCameraFrameRequest request{};
  const int32_t status = ml::run_latest_camera_frame(model_id_, &request);
  if (status == ml::kNoFrameAvailable) {
    return;
  }
  if (status != ml::kSuccess) {
    std::ostringstream log;
    log << "[semantic] inference failed status=" << ml::status_name(status)
        << " code=" << status;
    wasm_log_line(log.str());
    return;
  }
  if (request.frame_timestamp <= 0.0 ||
      request.frame_timestamp == last_processed_frame_timestamp_) {
    return;
  }

  last_processed_frame_timestamp_ = request.frame_timestamp;
  last_processed_lidar_timestamp_ = lidar_data.timestamp;

  const double frame_dt = std::fabs(request.frame_timestamp - lidar_data.timestamp);
  if (frame_dt > config_.max_frame_lidar_dt_sec) {
    log_detection_skip(request.frame_timestamp, lidar_data.timestamp);
    return;
  }

  std::vector<CandidateDetection> candidates;
  collect_candidate_detections(request, &candidates);
  if (candidates.empty()) {
    return;
  }

  for (const CandidateDetection& candidate : candidates) {
    BoundingBoxPixels box{};
    if (!detection_to_bounding_box_pixels(request, candidate.detection, &box)) {
      continue;
    }
    LidarBoundingBoxQueryResult lidar_query{};
    if (!query_lidar_bbox_coordinates(lidar_data, box, &lidar_query)) {
      std::ostringstream log;
      log << "[semantic] " << label_name(candidate.label)
          << " bbox had no LiDAR correspondence"
          << " score=" << candidate.score
          << " bbox=(" << box.x_min << "," << box.y_min << ")-("
          << box.x_max << "," << box.y_max << ")";
      wasm_log_line(log.str());
      continue;
    }

    const core::Vector3d world_point =
        body_point_to_world_point(lidar_query.body_point, pose);
    std::vector<core::Vector3d> footprint_world_points;
    footprint_world_points.reserve(lidar_query.inlier_body_points.size());
    for (const core::Vector3d& body_point : lidar_query.inlier_body_points) {
      footprint_world_points.push_back(body_point_to_world_point(body_point, pose));
    }
    {
      std::ostringstream log;
      log << detection_log_label(candidate.label)
          << " score=" << candidate.score
          << " world=(" << world_point.x << "," << world_point.y << ","
          << world_point.z << ")"
          << " bbox_points=" << lidar_query.matched_points
          << " inliers=" << lidar_query.inlier_points;
      wasm_log_line(log.str());
    }
    upsert_landmark(
        candidate.label,
        world_point,
        footprint_world_points,
        candidate.score,
        lidar_query.matched_points,
        lidar_query.inlier_points,
        request.frame_timestamp);
  }
}

void SemanticMapper::upsert_landmark(
    SemanticLabel label,
    const core::Vector3d& world_point,
    const std::vector<core::Vector3d>& footprint_world_points,
    float score,
    int32_t matched_points,
    int32_t inlier_points,
    double timestamp) {
  const double merge_radius2 =
      config_.landmark_merge_radius_m * config_.landmark_merge_radius_m;
  std::lock_guard<std::mutex> lk(landmarks_mutex_);

  SemanticLandmark* best_landmark = nullptr;
  double best_dist2 = merge_radius2;
  for (SemanticLandmark& landmark : landmarks_) {
    if (landmark.label != label) {
      continue;
    }
    const double dist2 = planar_distance_squared(landmark.world_point, world_point);
    if (dist2 > best_dist2) {
      continue;
    }
    best_dist2 = dist2;
    best_landmark = &landmark;
  }

  if (!best_landmark) {
    SemanticLandmark landmark{};
    landmark.id = next_landmark_id_++;
    landmark.label = label;
    landmark.world_point = world_point;
    merge_footprint_points(&landmark.footprint_world_points, footprint_world_points);
    landmark.mean_score = score;
    landmark.observation_count = 1;
    landmark.last_bbox_match_count = matched_points;
    landmark.last_inlier_count = inlier_points;
    landmark.first_timestamp = timestamp;
    landmark.last_timestamp = timestamp;
    landmarks_.push_back(landmark);
    landmark_revision_.fetch_add(1, std::memory_order_acq_rel);

    std::ostringstream log;
    log << "[semantic] new landmark id=" << landmark.id
        << " label=" << label_name(label)
        << " world=(" << world_point.x << "," << world_point.y << "," << world_point.z << ")"
        << " score=" << score
        << " bbox_points=" << matched_points
        << " inliers=" << inlier_points;
    wasm_log_line(log.str());
    return;
  }

  const int32_t previous_count = best_landmark->observation_count;
  const double next_count = static_cast<double>(previous_count + 1);
  best_landmark->world_point = core::Vector3d{
      ((best_landmark->world_point.x * previous_count) + world_point.x) / next_count,
      ((best_landmark->world_point.y * previous_count) + world_point.y) / next_count,
      ((best_landmark->world_point.z * previous_count) + world_point.z) / next_count};
  merge_footprint_points(&best_landmark->footprint_world_points, footprint_world_points);
  best_landmark->mean_score =
      ((best_landmark->mean_score * previous_count) + score) /
      static_cast<float>(next_count);
  best_landmark->observation_count = previous_count + 1;
  best_landmark->last_bbox_match_count = matched_points;
  best_landmark->last_inlier_count = inlier_points;
  best_landmark->last_timestamp = timestamp;
  landmark_revision_.fetch_add(1, std::memory_order_acq_rel);

  if (previous_count + 1 == config_.min_reported_observations) {
    std::ostringstream log;
    log << "[semantic] landmark confirmed id=" << best_landmark->id
        << " label=" << label_name(best_landmark->label)
        << " world=(" << best_landmark->world_point.x << ","
        << best_landmark->world_point.y << ","
        << best_landmark->world_point.z << ")"
        << " observations=" << best_landmark->observation_count
        << " mean_score=" << best_landmark->mean_score;
    wasm_log_line(log.str());
  }
}

}  // namespace semantic
