#include "sensors/lidar_camera.h"

constexpr double red_to_gray = 0.299;
constexpr double green_to_gray = 0.587;
constexpr double blue_to_gray = 0.114;
void img_to_grayscale(const CameraConfig& config, const src_img& src, grayscale_img& grayscale){
    for(size_t i = 0; i < config.image_height * config.image_width; ++i){
        grayscale[i] = blue_to_gray * src[i] + green_to_gray * src[i] + red_to_gray * src[i];
    }
}