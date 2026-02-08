#pragma once
#include "sensors/lidar_camera.h"
#include <vector>

struct Keypoint2d{
    double px_;
    double py_;
    Keypoint2d(double px, double py): px_(px), py_(py) {}
};

// FAST
void detect_corners(const CameraConfig& config, grayscale_img& grayscale, std::vector<Keypoint2d>& keypoints2d);