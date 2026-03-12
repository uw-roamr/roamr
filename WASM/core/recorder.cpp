#include "core/recorder.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <iomanip>
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
  kImuCsv,
  kPoseCsv,
  kStandaloneFile,
};

struct WriteRequest {
  TargetFile target = TargetFile::kPoseCsv;
  std::string path;
  std::vector<uint8_t> bytes;
  bool flush = false;
};

bool create_directory_if_needed(const std::string& dir) {
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

const char* pose_source_label(PoseDataSource source) {
  switch (source) {
    case PoseDataSource::kIMU:
      return "imu";
    case PoseDataSource::kWheelOdometry:
      return "wheel_odometry";
    case PoseDataSource::kFusedImuWheelOdometry:
      return "fused_imu_wheel_odometry";
    case PoseDataSource::kUnspecified:
    default:
      return "unspecified";
  }
}

std::vector<uint8_t> serialize_imu_csv_line(
    const sensors::IMUData& data,
    uint64_t sequence) {
  std::ostringstream line;
  line << sequence << ','
       << std::setprecision(17) << data.timestamp << ','
       << static_cast<uint32_t>(data.frame_id) << ','
       << data.acc_x << ','
       << data.acc_y << ','
       << data.acc_z << ','
       << data.gyro_x << ','
       << data.gyro_y << ','
       << data.gyro_z << '\n';
  const std::string text = line.str();
  return std::vector<uint8_t>(text.begin(), text.end());
}

std::vector<uint8_t> serialize_pose_csv_line(
    const sensors::PoseLog& pose,
    PoseDataSource source,
    uint64_t sequence) {
  std::ostringstream line;
  line << sequence << ','
       << std::setprecision(17) << pose.timestamp << ','
       << pose_source_label(source) << ','
       << pose.translation.x << ','
       << pose.translation.y << ','
       << pose.translation.z << ','
       << pose.quaternion.x << ','
       << pose.quaternion.y << ','
       << pose.quaternion.z << ','
       << pose.quaternion.w << '\n';
  const std::string text = line.str();
  return std::vector<uint8_t>(text.begin(), text.end());
}

std::vector<uint8_t> serialize_raw_rgb_image(
    const uint8_t* image,
    size_t image_size,
    int width,
    int height,
    int channels) {
  if (!image || image_size == 0 || width <= 0 || height <= 0) {
    return {};
  }

  const size_t pixel_count = static_cast<size_t>(width) * static_cast<size_t>(height);
  const size_t rgb_size = pixel_count * 3;
  std::vector<uint8_t> rgb(rgb_size, 0);

  if (channels == 3 && image_size >= rgb_size) {
    std::memcpy(rgb.data(), image, rgb_size);
  } else if (channels == 1 && image_size >= pixel_count) {
    for (size_t i = 0; i < pixel_count; ++i) {
      const uint8_t value = image[i];
      const size_t dst = i * 3;
      rgb[dst + 0] = value;
      rgb[dst + 1] = value;
      rgb[dst + 2] = value;
    }
  } else if (channels >= 4 &&
             image_size >= pixel_count * static_cast<size_t>(channels)) {
    for (size_t i = 0; i < pixel_count; ++i) {
      const size_t src = i * static_cast<size_t>(channels);
      const size_t dst = i * 3;
      rgb[dst + 0] = image[src + 0];
      rgb[dst + 1] = image[src + 1];
      rgb[dst + 2] = image[src + 2];
    }
  } else {
    return {};
  }

  return rgb;
}

std::vector<uint8_t> serialize_points_ply(
    const sensors::LidarCameraData& data) {
  const size_t point_count = data.points_size / 3;
  if (point_count == 0) {
    return {};
  }

  const bool has_colors = data.colors_size >= point_count * 3;

  std::ostringstream header;
  header << "ply\n"
         << "format binary_little_endian 1.0\n"
         << "element vertex " << point_count << "\n"
         << "property float x\n"
         << "property float y\n"
         << "property float z\n"
         << "property uchar red\n"
         << "property uchar green\n"
         << "property uchar blue\n"
         << "end_header\n";
  const std::string header_text = header.str();

  constexpr size_t kBytesPerVertex = sizeof(float) * 3 + sizeof(uint8_t) * 3;
  std::vector<uint8_t> output;
  output.reserve(header_text.size() + point_count * kBytesPerVertex);
  output.insert(output.end(), header_text.begin(), header_text.end());

  for (size_t i = 0; i < point_count; ++i) {
    const size_t point_offset = i * 3;
    const float xyz[3] = {
        data.points[point_offset + 0],
        data.points[point_offset + 1],
        data.points[point_offset + 2],
    };
    const uint8_t rgb[3] = {
        has_colors ? data.colors[point_offset + 0] : static_cast<uint8_t>(255),
        has_colors ? data.colors[point_offset + 1] : static_cast<uint8_t>(255),
        has_colors ? data.colors[point_offset + 2] : static_cast<uint8_t>(255),
    };

    const uint8_t* xyz_bytes = reinterpret_cast<const uint8_t*>(xyz);
    output.insert(output.end(), xyz_bytes, xyz_bytes + sizeof(xyz));
    output.insert(output.end(), rgb, rgb + sizeof(rgb));
  }

  return output;
}

std::string make_frame_stem(uint64_t sequence, double timestamp) {
  std::ostringstream name;
  name << "frame-" << std::setw(6) << std::setfill('0') << sequence
       << "-" << std::fixed << std::setprecision(3) << timestamp;
  return name.str();
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
    if (!create_directory_if_needed(dir)) {
      return;
    }

    const uint64_t session_id = static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch())
            .count());
    session_dir_ = dir + "/session-" + std::to_string(session_id);
    if (!create_directory_if_needed(session_dir_)) {
      return;
    }
    image_dir_ = session_dir_ + "/images";
    points_dir_ = session_dir_ + "/points";
    if (!create_directory_if_needed(image_dir_) ||
        !create_directory_if_needed(points_dir_)) {
      return;
    }

    imu_path_ = session_dir_ + "/imu.csv";
    imu_file_ = std::fopen(imu_path_.c_str(), "wb");
    if (!imu_file_) {
      log_open_error("imu", imu_path_);
      return;
    }

    pose_path_ = session_dir_ + "/pose.csv";
    pose_file_ = std::fopen(pose_path_.c_str(), "wb");
    if (!pose_file_) {
      log_open_error("pose", pose_path_);
      close_file(&imu_file_);
      return;
    }

    static constexpr char kImuHeader[] =
        "sequence,timestamp,frame_id,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z\n";
    if (std::fwrite(kImuHeader, 1, sizeof(kImuHeader) - 1, imu_file_) !=
        sizeof(kImuHeader) - 1) {
      log_open_error("imu_header", imu_path_);
      close_file(&pose_file_);
      close_file(&imu_file_);
      return;
    }

    static constexpr char kPoseHeader[] =
        "sequence,timestamp,source,tx,ty,tz,qx,qy,qz,qw\n";
    if (std::fwrite(kPoseHeader, 1, sizeof(kPoseHeader) - 1, pose_file_) !=
        sizeof(kPoseHeader) - 1) {
      log_open_error("pose_header", pose_path_);
      close_file(&pose_file_);
      close_file(&imu_file_);
      return;
    }

    enabled_ = true;
    writer_thread_ = std::thread([this]() { writer_loop(); });
    writer_thread_.detach();

    std::ostringstream log;
    log << "[recorder] enabled session_dir=" << session_dir_
        << " imu=" << imu_path_
        << " pose=" << pose_path_
        << " images=" << image_dir_
        << " points=" << points_dir_;
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
    request.target = TargetFile::kImuCsv;
    request.bytes = serialize_imu_csv_line(
        data, next_imu_sequence_.fetch_add(1));
    enqueue_request(std::move(request));
  }

  void enqueue_pose(const sensors::PoseLog& pose, PoseDataSource source) {
    if (!is_enabled() || pose.timestamp <= 0.0) {
      return;
    }
    WriteRequest request;
    request.target = TargetFile::kPoseCsv;
    request.bytes = serialize_pose_csv_line(
        pose, source, next_pose_sequence_.fetch_add(1));
    enqueue_request(std::move(request));
  }

  void enqueue_lidar_frame(
      const sensors::LidarCameraData& data,
      const sensors::PoseLog& pose) {
    if (!is_enabled()) {
      return;
    }

    const uint64_t sequence = next_lidar_camera_sequence_.fetch_add(1);
    const std::string frame_stem = make_frame_stem(sequence, data.timestamp);

    if (data.image_size > 0) {
      std::vector<uint8_t> image_bytes = serialize_raw_rgb_image(
          data.image.data(),
          data.image_size,
          camera_config_.image_width,
          camera_config_.image_height,
          camera_config_.image_channels);
      if (!image_bytes.empty()) {
        WriteRequest image_request;
        image_request.target = TargetFile::kStandaloneFile;
        std::ostringstream image_name;
        image_name << image_dir_ << "/" << frame_stem
                   << "-" << camera_config_.image_width
                   << "x" << camera_config_.image_height
                   << "x3.rgb";
        image_request.path = image_name.str();
        image_request.bytes = std::move(image_bytes);
        enqueue_request(std::move(image_request));
      }
    }

    std::vector<uint8_t> point_bytes = serialize_points_ply(data);
    if (!point_bytes.empty()) {
      WriteRequest point_request;
      point_request.target = TargetFile::kStandaloneFile;
      point_request.path = points_dir_ + "/" + frame_stem + ".ply";
      point_request.bytes = std::move(point_bytes);
      enqueue_request(std::move(point_request));
    }

    (void)pose;
  }

 private:
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

  size_t* target_flush_counter(TargetFile target) {
    switch (target) {
      case TargetFile::kImuCsv:
        return &imu_since_flush_;
      case TargetFile::kPoseCsv:
        return &pose_since_flush_;
      case TargetFile::kStandaloneFile:
        return nullptr;
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

      if (request.bytes.empty()) {
        continue;
      }

      std::FILE* file = nullptr;
      bool close_after_write = false;
      if (request.target == TargetFile::kImuCsv) {
        file = imu_file_;
      } else if (request.target == TargetFile::kPoseCsv) {
        file = pose_file_;
      } else if (!request.path.empty()) {
        file = std::fopen(request.path.c_str(), "wb");
        close_after_write = true;
      }

      if (!file) {
        log_open_error("write_target", request.path);
        continue;
      }

      const size_t written =
          std::fwrite(request.bytes.data(), 1, request.bytes.size(), file);
      if (written != request.bytes.size()) {
        wasm_log_line("[recorder] short write");
        if (close_after_write) {
          std::fclose(file);
        }
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

      if (close_after_write) {
        std::fclose(file);
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
  std::string imu_path_;
  std::string pose_path_;
  std::string session_dir_;
  std::string image_dir_;
  std::string points_dir_;
  sensors::CameraConfig camera_config_{};
  bool initialized_ = false;
  bool enabled_ = false;
  bool drop_warning_emitted_ = false;
  size_t dropped_request_count_ = 0;
  size_t imu_since_flush_ = 0;
  size_t pose_since_flush_ = 0;
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
