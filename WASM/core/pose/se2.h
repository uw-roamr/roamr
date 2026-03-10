#pragma once
#include "core/pose/coordinate_frames.h"

namespace core{
    struct PoseSE2d{
        double x;
        double y;
        double theta;

        PoseSE2d(double x, double y, double theta): x(x), y(y), theta(theta){};
        PoseSE2d(){};
    };

}; // namespace core
