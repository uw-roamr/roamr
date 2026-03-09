// WASM helpers to accept multiple poses and render a simple RGBA map image.
// Coordinate space: inputs are (x, y, theta) in meters; LiDAR points are (x, y) in meters.
// Map is a fixed-size occupancy grid (similar to the ROS node).
#include <stdint.h>
#include <math.h>
#include <string.h>
#include "map_api.h"

namespace mapping{

	// Pose storage for drawing trajectory
	static double POSES[3 * kMaxMapPoses]; // x,y,theta triples

	// Image buffer (RGBA8888)
	static const int32_t MAX_W = 512;
	static const int32_t MAX_H = 512;
	static uint8_t IMAGE[MAX_W * MAX_H * 4];
	static int32_t CUR_W = 256;
	static int32_t CUR_H = 256;

	// LiDAR points storage (2D projection x,y)
	static float POINTS[2 * kMaxMapPoints];
	static int32_t POINTS_COUNT = 0;

	// Planned path storage (grid cells in map coordinates).
	static const int32_t kMaxPlannedPath = kMaxMapPoses;
	static int32_t PLANNED_PATH[2 * kMaxPlannedPath];
	static int32_t PLANNED_PATH_COUNT = 0;
	static int32_t PLANNED_GOAL_ENABLED = 0;
	static int32_t PLANNED_GOAL_X = 0;
	static int32_t PLANNED_GOAL_Y = 0;

	// Map parameters (mirroring the ROS node)
	static const float GRID_RESOLUTION = 0.02f; // meters
	static const int32_t MAP_SIZE_X = 400;
	static const int32_t MAP_SIZE_Y = 400;
	static const int32_t SCAN_THRESHOLD = 5;
	static const int32_t DECAY_FACTOR = 10;
	static const int32_t CLEAR_THRESHOLD = 1; // clear confirmed cells after enough free-space passes
	static const float MIN_RANGE = 0.1f; // meters

	// Map state
	static int16_t SCAN_COUNT[MAP_SIZE_X * MAP_SIZE_Y];
	static uint8_t CONFIRMED[MAP_SIZE_X * MAP_SIZE_Y];
	static uint8_t VISITED[MAP_SIZE_X * MAP_SIZE_Y];

	static int32_t MAP_ORIGIN_INITIALIZED = 0;
	static float MAP_ORIGIN_OFFSET_X = 0.0f;
	static float MAP_ORIGIN_OFFSET_Y = 0.0f;

	// 0 = points are in robot/laser frame (default), 1 = points already in world/map frame.
	static int32_t POINTS_IN_WORLD = 0;


	void reset_poses() {
		memset(POSES, 0, sizeof(POSES));
	}

	void reset_points() {
		memset(POINTS, 0, sizeof(POINTS));
		POINTS_COUNT = 0;
	}

	void reset_map() {
		memset(SCAN_COUNT, 0, sizeof(SCAN_COUNT));
		memset(CONFIRMED, 0, sizeof(CONFIRMED));
		memset(VISITED, 0, sizeof(VISITED));
		MAP_ORIGIN_INITIALIZED = 0;
		MAP_ORIGIN_OFFSET_X = 0.0f;
		MAP_ORIGIN_OFFSET_Y = 0.0f;
	}

	int32_t get_occupancy_grid(int8_t* out_data, int32_t max_cells) {
		const int32_t total = MAP_SIZE_X * MAP_SIZE_Y;
		if (!out_data || max_cells < total) {
			return 0;
		}
		for (int32_t gy = 0; gy < MAP_SIZE_Y; ++gy) {
			for (int32_t gx = 0; gx < MAP_SIZE_X; ++gx) {
				const int32_t idx = gx + gy * MAP_SIZE_X;
				int8_t value = -1;
				if (VISITED[idx]) {
					value = CONFIRMED[idx] ? 100 : 0;
				}
				out_data[idx] = value;
			}
		}
		return total;
	}

	int32_t get_occupancy_meta(OccupancyGridMeta* out_meta) {
		if (!out_meta) return 0;
		out_meta->width = MAP_SIZE_X;
		out_meta->height = MAP_SIZE_Y;
		out_meta->resolution_m = GRID_RESOLUTION;
		out_meta->origin_x_m = -((double)MAP_SIZE_X * 0.5 * GRID_RESOLUTION) + MAP_ORIGIN_OFFSET_X;
		out_meta->origin_y_m = -((double)MAP_SIZE_Y * 0.5 * GRID_RESOLUTION) + MAP_ORIGIN_OFFSET_Y;
		out_meta->origin_initialized = MAP_ORIGIN_INITIALIZED ? 1 : 0;
		return 1;
	}

	void clear_planned_path() {
		PLANNED_PATH_COUNT = 0;
		PLANNED_GOAL_ENABLED = 0;
	}

	void set_planned_path_cell(int32_t idx, int32_t gx, int32_t gy) {
		if (idx < 0 || idx >= kMaxPlannedPath) return;
		int32_t base = idx * 2;
		PLANNED_PATH[base + 0] = gx;
		PLANNED_PATH[base + 1] = gy;
		if (idx + 1 > PLANNED_PATH_COUNT) {
			PLANNED_PATH_COUNT = idx + 1;
		}
	}

	void set_planned_goal_cell(int32_t gx, int32_t gy, int32_t enabled) {
		PLANNED_GOAL_X = gx;
		PLANNED_GOAL_Y = gy;
		PLANNED_GOAL_ENABLED = enabled ? 1 : 0;
	}

	void set_points_world(int32_t in_world) {
		POINTS_IN_WORLD = in_world ? 1 : 0;
	}

	// Set a single pose at index (0-based). Extra indices are ignored.
	void set_pose(int32_t idx, double x, double y, double theta) {
		if (idx < 0 || idx >= kMaxMapPoses) return;
		int32_t base = idx * 3;
		POSES[base + 0] = x;
		POSES[base + 1] = y;
		POSES[base + 2] = theta;
	}

	// Set a single LiDAR point at index (0-based).
	void set_point(int32_t idx, double x, double y) {
		if (idx < 0 || idx >= kMaxMapPoints) return;
		int32_t base = idx * 2;
		POINTS[base + 0] = static_cast<float>(x);
		POINTS[base + 1] = static_cast<float>(y);
		if (idx + 1 > POINTS_COUNT) POINTS_COUNT = idx + 1;
	}

	static inline int32_t clampi(int32_t v, int32_t lo, int32_t hi) {
		return v < lo ? lo : (v > hi ? hi : v);
	}

	static inline int32_t is_finite(float v) {
		return (v == v) && (v != INFINITY) && (v != -INFINITY);
	}

	static inline int32_t grid_index(int32_t gx, int32_t gy) {
		return gx + gy * MAP_SIZE_X;
	}

	static inline int32_t world_to_grid(double x, double y, int32_t *gx, int32_t *gy) {
		if (MAP_ORIGIN_INITIALIZED) {
			x -= MAP_ORIGIN_OFFSET_X;
			y -= MAP_ORIGIN_OFFSET_Y;
		}
		int32_t ix = (int32_t)(x / GRID_RESOLUTION) + MAP_SIZE_X / 2;
		int32_t iy = (int32_t)(y / GRID_RESOLUTION) + MAP_SIZE_Y / 2;
		if (ix < 0 || ix >= MAP_SIZE_X || iy < 0 || iy >= MAP_SIZE_Y) {
			return 0;
		}
		*gx = ix;
		*gy = iy;
		return 1;
	}

	static inline void maybe_init_origin(double x, double y) {
		if (!MAP_ORIGIN_INITIALIZED) {
			MAP_ORIGIN_OFFSET_X = static_cast<float>(x);
			MAP_ORIGIN_OFFSET_Y = static_cast<float>(y);
			MAP_ORIGIN_INITIALIZED = 1;
		}
	}

	static void integrate_ray(int32_t x0, int32_t y0, int32_t x1, int32_t y1) {
		int dx = (x1 > x0) ? (x1 - x0) : (x0 - x1);
		int sx = (x0 < x1) ? 1 : -1;
		int dy = (y1 > y0) ? (y0 - y1) : (y1 - y0); // negative
		int sy = (y0 < y1) ? 1 : -1;
		int err = dx + dy;

		int x = x0;
		int y = y0;
		while (1) {
			int32_t idx = grid_index(x, y);
			VISITED[idx] = 1;

			if (x == x1 && y == y1) {
				int16_t count = SCAN_COUNT[idx];
				if (count < SCAN_THRESHOLD) count += 1;
				SCAN_COUNT[idx] = count;
				if (count >= SCAN_THRESHOLD) {
					CONFIRMED[idx] = 1;
				}
				break;
			} else {
				int16_t count = SCAN_COUNT[idx];
				count = (int16_t)((count > DECAY_FACTOR) ? (count - DECAY_FACTOR) : 0);
				SCAN_COUNT[idx] = count;
				if (CONFIRMED[idx] && count < CLEAR_THRESHOLD) {
					CONFIRMED[idx] = 0;
				}
			}

			int e2 = 2 * err;
			if (e2 >= dy) { // e2 >= dy
				err += dy;
				x += sx;
			}
			if (e2 <= dx) { // e2 <= dx
				err += dx;
				y += sy;
			}
		}
	}

	static void integrate_scan(double pose_x, double pose_y, double pose_theta, int32_t pointCount, int32_t points_in_world) {
		if (pointCount <= 0) return;
		maybe_init_origin(pose_x, pose_y);

		int32_t start_x = 0;
		int32_t start_y = 0;
		if (!world_to_grid(pose_x, pose_y, &start_x, &start_y)) {
			return;
		}

		const double min_range2 = static_cast<double>(MIN_RANGE) * static_cast<double>(MIN_RANGE);
		const double c = cos(pose_theta);
		const double s = sin(pose_theta);

		for (int32_t i = 0; i < pointCount; ++i) {
			int32_t base = i * 2;
			float lx = POINTS[base + 0];
			float ly = POINTS[base + 1];
			if (!is_finite(lx) || !is_finite(ly)) continue;

			double wx = lx;
			double wy = ly;
			if (!points_in_world) {
				wx = pose_x + c * lx - s * ly;
				wy = pose_y + s * lx + c * ly;
			}

			const double dx = wx - pose_x;
			const double dy = wy - pose_y;
			if ((dx * dx + dy * dy) < min_range2) continue;

			int32_t end_x = 0;
			int32_t end_y = 0;
			if (!world_to_grid(wx, wy, &end_x, &end_y)) continue;

			integrate_ray(start_x, start_y, end_x, end_y);
		}
	}

	static inline void set_pixel(int32_t x, int32_t y, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
		if (x < 0 || x >= CUR_W || y < 0 || y >= CUR_H) return;
		int32_t o = (y * CUR_W + x) * 4;
		IMAGE[o + 0] = r;
		IMAGE[o + 1] = g;
		IMAGE[o + 2] = b;
		IMAGE[o + 3] = a;
	}



	static inline int32_t grid_to_pixel(
		int32_t gx,
		int32_t gy,
		float scale,
		float off_x,
		float off_y,
		int32_t *px,
		int32_t *py
	) {
		if (gx < 0 || gx >= MAP_SIZE_X || gy < 0 || gy >= MAP_SIZE_Y) return 0;
		float fx = off_x + ((float)gx + 0.5f) * scale;
		float fy = off_y + ((float)(MAP_SIZE_Y - 1 - gy) + 0.5f) * scale;
		int32_t ix = (int32_t)fx;
		int32_t iy = (int32_t)fy;
		if (ix < 0 || ix >= CUR_W || iy < 0 || iy >= CUR_H) return 0;
		*px = ix;
		*py = iy;
		return 1;
	}







	// Render occupancy map to IMAGE, optionally integrating the current scan.
	void draw_map(int32_t poseCount, int32_t pointCount, int32_t width, int32_t height) {
		if (poseCount < 0) poseCount = 0;
		if (poseCount > kMaxMapPoses) poseCount = kMaxMapPoses;
		if (pointCount < 0) pointCount = 0;
		if (pointCount > kMaxMapPoints) pointCount = kMaxMapPoints;
		if (width  <= 0) width  = 256;
		if (height <= 0) height = 256;
		if (width  > MAX_W) width  = MAX_W;
		if (height > MAX_H) height = MAX_H;
		CUR_W = width;
		CUR_H = height;

		// Integrate the latest scan into the occupancy grid.
		const int32_t used_points = (pointCount < POINTS_COUNT) ? pointCount : POINTS_COUNT;
		if (used_points > 0 && (POINTS_IN_WORLD || poseCount > 0)) {
			const int32_t base = (poseCount - 1) * 3;
			integrate_scan(POSES[base], POSES[base + 1], POSES[base + 2], used_points, POINTS_IN_WORLD);
		}

		// Scale to fit the map in the image (preserving aspect ratio).
		const float scale_x = (float)CUR_W / (float)MAP_SIZE_X;
		const float scale_y = (float)CUR_H / (float)MAP_SIZE_Y;
		const float scale   = (scale_x < scale_y) ? scale_x : scale_y;
		const float off_x   = ((float)CUR_W - (float)MAP_SIZE_X * scale) * 0.5f;
		const float off_y   = ((float)CUR_H - (float)MAP_SIZE_Y * scale) * 0.5f;

		// Render each pixel: unknown=gray(128), free=black(0), wall=white(255).
		for (int32_t py = 0; py < CUR_H; ++py) {
			for (int32_t px = 0; px < CUR_W; ++px) {
				const int32_t gx = (int32_t)(((float)px - off_x) / scale);
				const int32_t gy = MAP_SIZE_Y - 1 - (int32_t)(((float)py - off_y) / scale);

				uint8_t v = 128; // unknown
				if (gx >= 0 && gx < MAP_SIZE_X && gy >= 0 && gy < MAP_SIZE_Y) {
					const int32_t idx = grid_index(gx, gy);
					if (VISITED[idx]) {
						v = CONFIRMED[idx] ? 255 : 0; // wall=white, free=black
					}
				}

				const int32_t o = (py * CUR_W + px) * 4;
				IMAGE[o + 0] = v;
				IMAGE[o + 1] = v;
				IMAGE[o + 2] = v;
				IMAGE[o + 3] = 255;
			}
		}

		// Draw the most recent global pose as a 3×3 green dot.
		if (poseCount > 0) {
			const int32_t base = (poseCount - 1) * 3;
			int32_t gx = 0, gy = 0;
			if (world_to_grid(POSES[base], POSES[base + 1], &gx, &gy)) {
				int32_t ppx = 0, ppy = 0;
				if (grid_to_pixel(gx, gy, scale, off_x, off_y, &ppx, &ppy)) {
					for (int32_t dy = -1; dy <= 1; ++dy) {
						for (int32_t dx = -1; dx <= 1; ++dx) {
							set_pixel(ppx + dx, ppy + dy, 0, 255, 0, 255);
						}
					}
				}
			}
		}
	}

	// Back-compat: draw only poses
	void draw_pose_map(int32_t count, int32_t width, int32_t height) {
		draw_map(count, 0, width, height);
	}

	// Image accessors
	int32_t get_image_width() { return CUR_W; }
	int32_t get_image_height() { return CUR_H; }

	uint8_t *get_image_rgba_ptr() { return IMAGE; }
	int32_t get_image_rgba_size() { return CUR_W * CUR_H * 4; }

	// Read a pixel as little-endian RGBA packed into a 32-bit value.
	// index = y * width + x
	int32_t get_image_pixel_u32(int32_t index) {
		if (index < 0 || index >= (CUR_W * CUR_H)) return 0;
		const int32_t o = index * 4;
		// Pack RGBA8 -> 0xAABBGGRR little-endian (LSB=R)
		uint32_t r = IMAGE[o + 0];
		uint32_t g = IMAGE[o + 1];
		uint32_t b = IMAGE[o + 2];
		uint32_t a = IMAGE[o + 3];
		uint32_t packed = (a << 24) | (b << 16) | (g << 8) | (r);
		return (int32_t)packed;
	}
};
