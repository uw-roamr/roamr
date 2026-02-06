#pragma once
#include "sensors/lidar_camera.h"
#include <vector>

struct Keypoint2d{
    double px;
    double py;
};

void detect_corners(const CameraConfig& config, grayscale_img& grayscale, std::vector<Keypoint2d>& keypoints2d){
    for(size_t i = 0; i < std::min(config.image_height, config.image_width); ++i){
        keypoints2d.emplace_back(i, i);
    }
}