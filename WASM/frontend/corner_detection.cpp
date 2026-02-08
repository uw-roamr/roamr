#include "frontend/corner_detection.h"


constexpr int FAST_N = 9;

constexpr int points = 16;
static constexpr std::array<int, points> dx{
  3, 3, 2, 1, 0,-1,-2,-3,-3,-3,-2,-1, 0, 1, 2, 3
};
static constexpr std::array<int, points> dy{
  0, 1, 2, 3, 3, 3, 2, 1, 0,-1,-2,-3,-3,-3,-2,-1
};




void detect_corners(const CameraConfig& config, grayscale_img& grayscale, std::vector<Keypoint2d>& keypoints2d){
    keypoints2d.clear();
    for(size_t i = 0; i < std::min(config.image_height, config.image_width); ++i){
        keypoints2d.emplace_back(i, i);
    }
}
