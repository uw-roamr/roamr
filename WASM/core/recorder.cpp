#include "core/recorder.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <errno.h>
#include <sys/stat.h>

#include "core/telemetry.h"

namespace core::recorder {
namespace {

constexpr size_t kMaxPendingWrites = 128;
constexpr size_t kBufferedFlushThreshold = 50;

enum class TargetFile : uint8_t {
  kImuProto,
  kPoseProto,
  kLidarCameraProto,
};

enum class WireType : uint8_t {
  kVarint = 0,
  kFixed64 = 1,
  kLengthDelimited = 2,
};

struct WriteRequest {
  TargetFile target = TargetFile::kImuProto;
  std::vector<uint8_t> bytes;
  bool flush = false;
};

void append_varint(std::vector<uint8_t>* out, uint64_t value) {
  while (value >= 0x80) {
    out->push_back(static_cast<uint8_t>(value) | 0x80);
    value >>= 7;
  }
  out->push_back(static_cast<uint8_t>(value));
}

void append_tag(std::vector<uint8_t>* out, uint32_t field_number, WireType wire_type) {
  append_varint(out, (static_cast<uint64_t>(field_number) << 3) |
                         static_cast<uint8_t>(wire_type));
}

void append_uint64_field(std::vector<uint8_t>* out, uint32_t field_number, uint64_t value) {
  append_tag(out, field_number, WireType::kVarint);
  append_varint(out, value);
}

void append_uint32_field(std::vector<uint8_t>* out, uint32_t field_number, uint32_t value) {
  append_uint64_field(out, field_number, value);
}

void append_enum_field(std::vector<uint8_t>* out, uint32_t field_number, uint32_t value) {
  append_uint64_field(out, field_number, value);
}

void append_double_field(std::vector<uint8_t>* out, uint32_t field_number, double value) {
  append_tag(out, field_number, WireType::kFixed64);
  uint64_t bits = 0;
  std::memcpy(&bits, &value, sizeof(bits));
  for (size_t i = 0; i < sizeof(bits); ++i) {
    out->push_back(static_cast<uint8_t>((bits >> (8 * i)) & 0xFF));
  }
}

void append_bytes_field(
    std::vector<uint8_t>* out,
    uint32_t field_number,
    const uint8_t* data,
    size_t size) {
  if (!data || size == 0) {
    return;
  }
  append_tag(out, field_number, WireType::kLengthDelimited);
  append_varint(out, size);
  out->insert(out->end(), data, data + size);
}

void append_packed_float_field(
    std::vector<uint8_t>* out,
    uint32_t field_number,
    const float* data,
    size_t count) {
  if (!data || count == 0) {
    return;
  }
  append_tag(out, field_number, WireType::kLengthDelimited);
  const size_t byte_count = count * sizeof(float);
  append_varint(out, byte_count);
  const uint8_t* bytes = reinterpret_cast<const uint8_t*>(data);
  out->insert(out->end(), bytes, bytes + byte_count);
}

std::vector<uint8_t> make_length_prefixed(const std::vector<uint8_t>& message) {
  std::vector<uint8_t> output;
  output.reserve(message.size() + 10);
  append_varint(&output, message.size());
  output.insert(output.end(), message.begin(), message.end());
  return output;
}

std::vector<uint8_t> serialize_imu_message(const sensors::IMUData& data, uint64_t sequence) {
  std::vector<uint8_t> message;
  message.reserve(96);
  append_uint64_field(&message, 1, sequence);
  append_double_field(&message, 2, data.timestamp);
  append_uint32_field(&message, 3, static_cast<uint32_t>(data.frame_id));
  append_double_field(&message, 4, data.acc_x);
  append_double_field(&message, 5, data.acc_y);
  append_double_field(&message, 6, data.acc_z);
  append_double_field(&message, 7, data.gyro_x);
  append_double_field(&message, 8, data.gyro_y);
  append_double_field(&message, 9, data.gyro_z);
  return make_length_prefixed(message);
}

std::vector<uint8_t> serialize_pose_message(
    const sensors::PoseLog& pose,
    PoseDataSource source,
    uint64_t sequence) {
  std::vector<uint8_t> message;
  message.reserve(120);
  append_uint64_field(&message, 1, sequence);
  append_double_field(&message, 2, pose.timestamp);
  append_enum_field(&message, 3, static_cast<uint32_t>(source));
  append_double_field(&message, 4, pose.translation.x);
  append_double_field(&message, 5, pose.translation.y);
  append_double_field(&message, 6, pose.translation.z);
  append_double_field(&message, 7, pose.quaternion.x);
  append_double_field(&message, 8, pose.quaternion.y);
  append_double_field(&message, 9, pose.quaternion.z);
  append_double_field(&message, 10, pose.quaternion.w);
  return make_length_prefixed(message);
}

std::vector<uint8_t> serialize_lidar_camera_message(
    const sensors::LidarCameraData& data,
    const sensors::PoseLog& matched_pose,
    const sensors::CameraConfig& camera_config,
    uint64_t sequence) {
  std::vector<uint8_t> message;
  message.reserve(
      128 + data.points_size * sizeof(float) + data.colors_size + data.image_size);
  append_uint64_field(&message, 1, sequence);
  append_double_field(&message, 2, data.timestamp);
  append_uint32_field(&message, 3, static_cast<uint32_t>(data.points_frame_id));
  append_uint32_field(&message, 4, static_cast<uint32_t>(data.image_frame_id));
  append_uint32_field(&message, 5, static_cast<uint32_t>(data.points_size / 3));
  append_packed_float_field(&message, 6, data.points.data(), data.points_size);
  append_bytes_field(&message, 7, data.colors.data(), data.colors_size);
  append_uint32_field(&message, 8, static_cast<uint32_t>(camera_config.image_width));
  append_uint32_field(&message, 9, static_cast<uint32_t>(camera_config.image_height));
  append_uint32_field(&message, 10, static_cast<uint32_t>(camera_config.image_channels));
  append_bytes_field(&message, 11, data.image.data(), data.image_size);
  append_double_field(&message, 12, matched_pose.timestamp);
  return make_length_prefixed(message);
}

class SessionRecorder {
 public:
  void initialize_from_env(const sensors::CameraConfig& camera_config) {
    std::lock_guard<std::mutex> lk(state_mutex_);
    if (initialized_) {
      return;
    }
    initialized_ = true;
    camera_config_ = camera_config;

    const char* enabled_env = std::getenv("ROAMR_RECORDING_ENABLED");
    if (!enabled_env || enabled_env[0] != '1') {
      return;
    }

    const char* dir_env = std::getenv("ROAMR_RECORDING_DIR");
    const std::string dir = (dir_env && dir_env[0] != '\0') ? dir_env : "/data";
    if (!prepare_directory(dir)) {
      return;
    }

    const uint64_t session_id = static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch())
            .count());
    const std::string session_prefix =
        dir + "/session-" + std::to_string(session_id);
    imu_path_ = session_prefix + ".imu.pb";
    pose_path_ = session_prefix + ".pose.pb";
    lidar_camera_path_ = session_prefix + ".lidar_camera.pb";

    imu_file_ = std::fopen(imu_path_.c_str(), "wb");
    if (!imu_file_) {
      log_open_error("imu", imu_path_);
      return;
    }

    pose_file_ = std::fopen(pose_path_.c_str(), "wb");
    if (!pose_file_) {
      log_open_error("pose", pose_path_);
      close_file(&imu_file_);
      return;
    }

    lidar_camera_file_ = std::fopen(lidar_camera_path_.c_str(), "wb");
    if (!lidar_camera_file_) {
      log_open_error("lidar_camera", lidar_camera_path_);
      close_file(&pose_file_);
      close_file(&imu_file_);
      return;
    }

    enabled_ = true;
    writer_thread_ = std::thread([this]() { writer_loop(); });
    writer_thread_.detach();

    std::ostringstream log;
    log << "[recorder] enabled imu=" << imu_path_
        << " pose=" << pose_path_
        << " lidar_camera=" << lidar_camera_path_;
    wasm_log_line(log.str());
  }

  bool is_enabled() const {
    std::lock_guard<std::mutex> lk(state_mutex_);
    return enabled_;
  }

  void enqueue_imu(const sensors::IMUData& data) {
    if (!is_enabled()) {
      return;
    }
    WriteRequest request;
    request.target = TargetFile::kImuProto;
    request.bytes = serialize_imu_message(data, next_imu_sequence_.fetch_add(1));
    enqueue_request(std::move(request));
  }

  void enqueue_pose(const sensors::PoseLog& pose, PoseDataSource source) {
    if (!is_enabled() || pose.timestamp <= 0.0) {
      return;
    }
    WriteRequest request;
    request.target = TargetFile::kPoseProto;
    request.bytes = serialize_pose_message(
        pose, source, next_pose_sequence_.fetch_add(1));
    enqueue_request(std::move(request));
  }

  void enqueue_lidar_frame(
      const sensors::LidarCameraData& data,
      const sensors::PoseLog& pose) {
    if (!is_enabled()) {
      return;
    }
    WriteRequest request;
    request.target = TargetFile::kLidarCameraProto;
    request.flush = true;
    request.bytes = serialize_lidar_camera_message(
        data, pose, camera_config_, next_lidar_camera_sequence_.fetch_add(1));
    enqueue_request(std::move(request));
  }

 private:
  bool prepare_directory(const std::string& dir) {
    if (dir.empty()) {
      wasm_log_line("[recorder] empty recording directory");
      return false;
    }
    if (mkdir(dir.c_str(), 0755) != 0 && errno != EEXIST) {
      std::ostringstream log;
      log << "[recorder] mkdir failed path=" << dir << " errno=" << errno;
      wasm_log_line(log.str());
      return false;
    }
    return true;
  }

  void log_open_error(const char* label, const std::string& path) {
    std::ostringstream log;
    log << "[recorder] failed to open " << label
        << " path=" << path
        << " errno=" << errno;
    wasm_log_line(log.str());
  }

  void close_file(std::FILE** file) {
    if (file && *file) {
      std::fclose(*file);
      *file = nullptr;
    }
  }

  void enqueue_request(WriteRequest request) {
    std::lock_guard<std::mutex> lk(queue_mutex_);
    if (!enabled_) {
      return;
    }
    if (queue_.size() >= kMaxPendingWrites) {
      ++dropped_request_count_;
      if (!drop_warning_emitted_) {
        drop_warning_emitted_ = true;
        wasm_log_line("[recorder] write queue full; dropping samples");
      }
      return;
    }
    queue_.push_back(std::move(request));
    queue_cv_.notify_one();
  }

  std::FILE* target_file(TargetFile target) {
    switch (target) {
      case TargetFile::kImuProto:
        return imu_file_;
      case TargetFile::kPoseProto:
        return pose_file_;
      case TargetFile::kLidarCameraProto:
        return lidar_camera_file_;
    }
    return nullptr;
  }

  size_t* target_flush_counter(TargetFile target) {
    switch (target) {
      case TargetFile::kImuProto:
        return &imu_since_flush_;
      case TargetFile::kPoseProto:
        return &pose_since_flush_;
      case TargetFile::kLidarCameraProto:
        return &lidar_camera_since_flush_;
    }
    return nullptr;
  }

  void writer_loop() {
    while (true) {
      WriteRequest request;
      {
        std::unique_lock<std::mutex> lk(queue_mutex_);
        queue_cv_.wait(lk, [&]() { return !queue_.empty(); });
        request = std::move(queue_.front());
        queue_.pop_front();
      }

      std::FILE* file = target_file(request.target);
      if (!file || request.bytes.empty()) {
        continue;
      }

      const size_t written =
          std::fwrite(request.bytes.data(), 1, request.bytes.size(), file);
      if (written != request.bytes.size()) {
        wasm_log_line("[recorder] short write");
        continue;
      }

      size_t* flush_counter = target_flush_counter(request.target);
      if (flush_counter) {
        ++(*flush_counter);
      }

      if (request.flush ||
          (flush_counter && *flush_counter >= kBufferedFlushThreshold)) {
        std::fflush(file);
        if (flush_counter) {
          *flush_counter = 0;
        }
      }
    }
  }

  mutable std::mutex state_mutex_;
  std::mutex queue_mutex_;
  std::condition_variable queue_cv_;
  std::deque<WriteRequest> queue_;
  std::thread writer_thread_;

  std::FILE* imu_file_ = nullptr;
  std::FILE* pose_file_ = nullptr;
  std::FILE* lidar_camera_file_ = nullptr;
  std::string imu_path_;
  std::string pose_path_;
  std::string lidar_camera_path_;
  sensors::CameraConfig camera_config_{};
  bool initialized_ = false;
  bool enabled_ = false;
  bool drop_warning_emitted_ = false;
  size_t dropped_request_count_ = 0;
  size_t imu_since_flush_ = 0;
  size_t pose_since_flush_ = 0;
  size_t lidar_camera_since_flush_ = 0;
  std::atomic<uint64_t> next_imu_sequence_{1};
  std::atomic<uint64_t> next_pose_sequence_{1};
  std::atomic<uint64_t> next_lidar_camera_sequence_{1};
};

SessionRecorder& recorder() {
  static SessionRecorder instance;
  return instance;
}

}  // namespace

void initialize_from_env(const sensors::CameraConfig& camera_config) {
  recorder().initialize_from_env(camera_config);
}

bool is_enabled() {
  return recorder().is_enabled();
}

void enqueue_imu(const sensors::IMUData& data) {
  recorder().enqueue_imu(data);
}

void enqueue_pose(const sensors::PoseLog& pose, PoseDataSource source) {
  recorder().enqueue_pose(pose, source);
}

void enqueue_lidar_frame(
    const sensors::LidarCameraData& data,
    const sensors::PoseLog& pose) {
  recorder().enqueue_lidar_frame(data, pose);
}

}  // namespace core::recorder
