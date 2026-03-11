#include "core/recorder.h"

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

constexpr uint32_t kLidarRecordMagic = 0x524C4431;  // "RLD1"
constexpr uint32_t kLidarRecordVersion = 1;
constexpr size_t kMaxPendingWrites = 128;

enum class TargetFile : uint8_t {
  kImuCsv,
  kLidarBinary,
};

struct WriteRequest {
  TargetFile target = TargetFile::kImuCsv;
  std::vector<uint8_t> bytes;
  bool flush = false;
};

#pragma pack(push, 1)
struct LidarRecordHeader {
  uint32_t magic;
  uint32_t version;
  double timestamp;
  double pose_timestamp;
  double translation[3];
  double quaternion[4];
  uint32_t points_size;
  uint32_t colors_size;
  uint32_t image_size;
  int32_t points_frame_id;
  int32_t image_frame_id;
};
#pragma pack(pop)

class SessionRecorder {
 public:
  void initialize_from_env() {
    std::lock_guard<std::mutex> lk(state_mutex_);
    if (initialized_) {
      return;
    }
    initialized_ = true;

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
    imu_path_ = session_prefix + ".imu.csv";
    lidar_path_ = session_prefix + ".lidar.bin";

    imu_file_ = std::fopen(imu_path_.c_str(), "wb");
    if (!imu_file_) {
      log_open_error("imu", imu_path_);
      return;
    }

    lidar_file_ = std::fopen(lidar_path_.c_str(), "wb");
    if (!lidar_file_) {
      log_open_error("lidar", lidar_path_);
      std::fclose(imu_file_);
      imu_file_ = nullptr;
      return;
    }

    const char* imu_header =
        "timestamp,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z,frame_id\n";
    std::fwrite(imu_header, 1, std::strlen(imu_header), imu_file_);
    std::fflush(imu_file_);

    enabled_ = true;
    writer_thread_ = std::thread([this]() { writer_loop(); });
    writer_thread_.detach();

    std::ostringstream log;
    log << "[recorder] enabled imu=" << imu_path_ << " lidar=" << lidar_path_;
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
    std::ostringstream line;
    line << data.timestamp << ','
         << data.acc_x << ','
         << data.acc_y << ','
         << data.acc_z << ','
         << data.gyro_x << ','
         << data.gyro_y << ','
         << data.gyro_z << ','
         << data.frame_id << '\n';
    std::string text = line.str();
    WriteRequest request;
    request.target = TargetFile::kImuCsv;
    request.bytes.assign(text.begin(), text.end());
    enqueue_request(std::move(request));
  }

  void enqueue_lidar_frame(
      const sensors::LidarCameraData& data,
      const sensors::PoseLog& pose) {
    if (!is_enabled()) {
      return;
    }

    LidarRecordHeader header{};
    header.magic = kLidarRecordMagic;
    header.version = kLidarRecordVersion;
    header.timestamp = data.timestamp;
    header.pose_timestamp = pose.timestamp;
    header.translation[0] = pose.translation.x;
    header.translation[1] = pose.translation.y;
    header.translation[2] = pose.translation.z;
    header.quaternion[0] = pose.quaternion.x;
    header.quaternion[1] = pose.quaternion.y;
    header.quaternion[2] = pose.quaternion.z;
    header.quaternion[3] = pose.quaternion.w;
    header.points_size = static_cast<uint32_t>(data.points_size);
    header.colors_size = static_cast<uint32_t>(data.colors_size);
    header.image_size = static_cast<uint32_t>(data.image_size);
    header.points_frame_id = data.points_frame_id;
    header.image_frame_id = data.image_frame_id;

    const size_t points_bytes =
        data.points_size * sizeof(decltype(data.points)::value_type);
    const size_t colors_bytes =
        data.colors_size * sizeof(decltype(data.colors)::value_type);
    const size_t image_bytes =
        data.image_size * sizeof(decltype(data.image)::value_type);

    WriteRequest request;
    request.target = TargetFile::kLidarBinary;
    request.flush = true;
    request.bytes.resize(sizeof(header) + points_bytes + colors_bytes + image_bytes);

    size_t offset = 0;
    std::memcpy(request.bytes.data() + offset, &header, sizeof(header));
    offset += sizeof(header);
    if (points_bytes > 0) {
      std::memcpy(request.bytes.data() + offset, data.points.data(), points_bytes);
      offset += points_bytes;
    }
    if (colors_bytes > 0) {
      std::memcpy(request.bytes.data() + offset, data.colors.data(), colors_bytes);
      offset += colors_bytes;
    }
    if (image_bytes > 0) {
      std::memcpy(request.bytes.data() + offset, data.image.data(), image_bytes);
    }

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

  void writer_loop() {
    size_t imu_since_flush = 0;
    while (true) {
      WriteRequest request;
      {
        std::unique_lock<std::mutex> lk(queue_mutex_);
        queue_cv_.wait(lk, [&]() { return !queue_.empty(); });
        request = std::move(queue_.front());
        queue_.pop_front();
      }

      std::FILE* file =
          request.target == TargetFile::kImuCsv ? imu_file_ : lidar_file_;
      if (!file || request.bytes.empty()) {
        continue;
      }

      const size_t written =
          std::fwrite(request.bytes.data(), 1, request.bytes.size(), file);
      if (written != request.bytes.size()) {
        wasm_log_line("[recorder] short write");
        continue;
      }

      if (request.target == TargetFile::kImuCsv) {
        ++imu_since_flush;
      }
      if (request.flush || imu_since_flush >= 50) {
        std::fflush(file);
        if (request.target == TargetFile::kImuCsv) {
          imu_since_flush = 0;
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
  std::FILE* lidar_file_ = nullptr;
  std::string imu_path_;
  std::string lidar_path_;
  bool initialized_ = false;
  bool enabled_ = false;
  bool drop_warning_emitted_ = false;
  size_t dropped_request_count_ = 0;
};

SessionRecorder& recorder() {
  static SessionRecorder instance;
  return instance;
}

}  // namespace

void initialize_from_env() {
  recorder().initialize_from_env();
}

bool is_enabled() {
  return recorder().is_enabled();
}

void enqueue_imu(const sensors::IMUData& data) {
  recorder().enqueue_imu(data);
}

void enqueue_lidar_frame(
    const sensors::LidarCameraData& data,
    const sensors::PoseLog& pose) {
  recorder().enqueue_lidar_frame(data, pose);
}

}  // namespace core::recorder
