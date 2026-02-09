#pragma once
#include <cmath>

inline double norm(const double x, const double y, const double z) noexcept{
    return std::sqrt(x * x + y * y + z * z);
}