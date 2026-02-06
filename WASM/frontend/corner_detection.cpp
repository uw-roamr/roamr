#include "frontend/corner_detection.h"

void detect_corners(const CameraConfig& config, grayscale_img& grayscale, std::vector<Keypoint2d>& keypoints2d){
    keypoints2d.clear();
    for(size_t i = 0; i < std::min(config.image_height, config.image_width); ++i){
        keypoints2d.emplace_back(i, i);
    }
}
