// WASM helpers to accept multiple poses and render a simple RGBA map image.
// Coordinate space: inputs are (x, y, theta) in meters; LiDAR points are (x, y) in meters.
// Map is a fixed-size occupancy grid (similar to the ROS node).
#include <stdint.h>
#include <math.h>
#include <string.h>
#include "map_api.h"


	namespace mapping{
	// Legacy single-pose API kept for convenience/testing.
	void log_pose_f32(float x, float y, float theta) {
		(void)x; (void)y; (void)theta;
	}

	// Pose storage
	static const int32_t MAX_POSES = 4096;
	static double POSES[3 * MAX_POSES]; // x,y,theta triples

	// Image buffer (RGBA8888)
	static const int32_t MAX_W = 512;
	static const int32_t MAX_H = 512;
	static uint8_t IMAGE[MAX_W * MAX_H * 4];
	static int32_t CUR_W = 256;
	static int32_t CUR_H = 256;

	// LiDAR points storage (2D projection x,y)
	static const int32_t MAX_POINTS = 20000;
	static float POINTS[2 * MAX_POINTS];
	static int32_t POINTS_COUNT = 0;

	// Planned path storage (grid cells in map coordinates).
	static const int32_t MAX_PLANNED_PATH = 4096;
	static int32_t PLANNED_PATH[2 * MAX_PLANNED_PATH];
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
	static int32_t PIXEL_TO_GX[MAX_W];
	static int32_t PIXEL_TO_GY[MAX_H];
	static uint8_t PIXEL_X_VALID[MAX_W];
	static uint8_t PIXEL_Y_VALID[MAX_H];
	static int32_t PIXEL_LUT_W = -1;
	static int32_t PIXEL_LUT_H = -1;

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
		if (idx < 0 || idx >= MAX_PLANNED_PATH) return;
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
		if (idx < 0 || idx >= MAX_POSES) return;
		int32_t base = idx * 3;
		POSES[base + 0] = x;
		POSES[base + 1] = y;
		POSES[base + 2] = theta;
	}

	// Set a single LiDAR point at index (0-based).
	void set_point(int32_t idx, double x, double y) {
		if (idx < 0 || idx >= MAX_POINTS) return;
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

	static void draw_line_pixel(int32_t x0, int32_t y0, int32_t x1, int32_t y1, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
		int dx = (x1 > x0) ? (x1 - x0) : (x0 - x1);
		int sx = (x0 < x1) ? 1 : -1;
		int dy = (y1 > y0) ? (y0 - y1) : (y1 - y0); // negative
		int sy = (y0 < y1) ? 1 : -1;
		int err = dx + dy;

		int x = x0;
		int y = y0;
		while (1) {
			set_pixel(x, y, r, g, b, a);
			if (x == x1 && y == y1) break;
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

	static void rebuild_pixel_grid_lookup(float scale, float off_x, float off_y) {
		for (int32_t x = 0; x < CUR_W; ++x) {
			float mx = ((float)x - off_x) / scale;
			if (mx < 0.0f || mx >= (float)MAP_SIZE_X) {
				PIXEL_X_VALID[x] = 0;
				PIXEL_TO_GX[x] = 0;
				continue;
			}
			PIXEL_X_VALID[x] = 1;
			PIXEL_TO_GX[x] = (int32_t)mx;
		}
		for (int32_t y = 0; y < CUR_H; ++y) {
			float my = ((float)y - off_y) / scale;
			if (my < 0.0f || my >= (float)MAP_SIZE_Y) {
				PIXEL_Y_VALID[y] = 0;
				PIXEL_TO_GY[y] = 0;
				continue;
			}
			PIXEL_Y_VALID[y] = 1;
			PIXEL_TO_GY[y] = MAP_SIZE_Y - 1 - (int32_t)my;
		}
		PIXEL_LUT_W = CUR_W;
		PIXEL_LUT_H = CUR_H;
	}

	static void draw_planned_path_overlay(float scale, float off_x, float off_y) {
		if (PLANNED_PATH_COUNT <= 1) return;
		for (int32_t i = 1; i < PLANNED_PATH_COUNT; ++i) {
			const int32_t base0 = (i - 1) * 2;
			const int32_t base1 = i * 2;
			const int32_t gx0 = PLANNED_PATH[base0 + 0];
			const int32_t gy0 = PLANNED_PATH[base0 + 1];
			const int32_t gx1 = PLANNED_PATH[base1 + 0];
			const int32_t gy1 = PLANNED_PATH[base1 + 1];
			int32_t px0 = 0, py0 = 0, px1 = 0, py1 = 0;
			if (!grid_to_pixel(gx0, gy0, scale, off_x, off_y, &px0, &py0) ||
				!grid_to_pixel(gx1, gy1, scale, off_x, off_y, &px1, &py1)) {
				continue;
			}
			draw_line_pixel(px0, py0, px1, py1, 0, 120, 255, 255);
		}
	}

	static void draw_goal_marker(float scale, float off_x, float off_y) {
		if (!PLANNED_GOAL_ENABLED) return;
		int32_t px = 0;
		int32_t py = 0;
		if (!grid_to_pixel(PLANNED_GOAL_X, PLANNED_GOAL_Y, scale, off_x, off_y, &px, &py)) {
			return;
		}
		for (int32_t d = -2; d <= 2; ++d) {
			set_pixel(px + d, py, 0, 120, 255, 255);
			set_pixel(px, py + d, 0, 120, 255, 255);
		}
	}

	// Render occupancy map to IMAGE, optionally integrating the current scan.
	void draw_map(int32_t poseCount, int32_t pointCount, int32_t width, int32_t height) {
		if (poseCount < 0) poseCount = 0;
		if (poseCount > MAX_POSES) poseCount = MAX_POSES;
		if (pointCount < 0) pointCount = 0;
		if (pointCount > MAX_POINTS) pointCount = MAX_POINTS;
		if (width <= 0) width = 256;
		if (height <= 0) height = 256;
		if (width > MAX_W) width = MAX_W;
		if (height > MAX_H) height = MAX_H;
		CUR_W = width;
		CUR_H = height;

		int32_t used_points = pointCount;
		if (used_points > POINTS_COUNT) used_points = POINTS_COUNT;

		double pose_x = 0.0;
		double pose_y = 0.0;
		double pose_theta = 0.0;
		if (poseCount > 0) {
			int32_t base = (poseCount - 1) * 3;
			pose_x = POSES[base + 0];
			pose_y = POSES[base + 1];
			pose_theta = POSES[base + 2];
		}

		if (used_points > 0) {
			if (POINTS_IN_WORLD || poseCount > 0) {
				integrate_scan(pose_x, pose_y, pose_theta, used_points, POINTS_IN_WORLD);
			}
		}

		const uint8_t c_unknown = 64;
		const uint8_t c_free = 0;
		const uint8_t c_occ = 255;

		// Fill background as unknown.
		for (int32_t y = 0; y < CUR_H; ++y) {
			for (int32_t x = 0; x < CUR_W; ++x) {
				int32_t o = (y * CUR_W + x) * 4;
				IMAGE[o + 0] = c_unknown;
				IMAGE[o + 1] = c_unknown;
				IMAGE[o + 2] = c_unknown;
				IMAGE[o + 3] = 255;
			}
		}

		// Compute map scale to fit while preserving aspect ratio.
		float scale_x = (float)CUR_W / (float)MAP_SIZE_X;
		float scale_y = (float)CUR_H / (float)MAP_SIZE_Y;
		float scale = (scale_x < scale_y) ? scale_x : scale_y;
		if (scale <= 0.0f) scale = 1.0f;
		float map_w = (float)MAP_SIZE_X * scale;
		float map_h = (float)MAP_SIZE_Y * scale;
		float off_x = ((float)CUR_W - map_w) * 0.5f;
		float off_y = ((float)CUR_H - map_h) * 0.5f;
		if (PIXEL_LUT_W != CUR_W || PIXEL_LUT_H != CUR_H) {
			rebuild_pixel_grid_lookup(scale, off_x, off_y);
		}

		// Render occupancy grid into the image.
		for (int32_t y = 0; y < CUR_H; ++y) {
			if (!PIXEL_Y_VALID[y]) continue;
			int32_t gy = PIXEL_TO_GY[y];
			for (int32_t x = 0; x < CUR_W; ++x) {
				if (!PIXEL_X_VALID[x]) continue;
				int32_t gx = PIXEL_TO_GX[x];
				int32_t idx = grid_index(gx, gy);
				uint8_t v = c_unknown;
				if (!VISITED[idx]) {
					v = c_unknown;
				} else if (CONFIRMED[idx]) {
					v = c_occ;
				} else {
					v = c_free;
				}
				int32_t o = (y * CUR_W + x) * 4;
				IMAGE[o + 0] = v;
				IMAGE[o + 1] = v;
				IMAGE[o + 2] = v;
				IMAGE[o + 3] = 255;
			}
		}

		// Overlay points (red) for debugging.
		if (used_points > 0 && (POINTS_IN_WORLD || poseCount > 0)) {
			const double c = cos(pose_theta);
			const double s = sin(pose_theta);
			for (int32_t i = 0; i < used_points; ++i) {
				int32_t base = i * 2;
				float lx = POINTS[base + 0];
				float ly = POINTS[base + 1];
				if (!is_finite(lx) || !is_finite(ly)) continue;

				double wx = lx;
				double wy = ly;
				if (!POINTS_IN_WORLD) {
					wx = pose_x + c * lx - s * ly;
					wy = pose_y + s * lx + c * ly;
				}

				int32_t gx = 0;
				int32_t gy = 0;
				if (!world_to_grid(wx, wy, &gx, &gy)) continue;
				int32_t px = 0;
				int32_t py = 0;
				if (!grid_to_pixel(gx, gy, scale, off_x, off_y, &px, &py)) continue;
				set_pixel(px, py, 255, 0, 255, 255);
			}
		}

		// Overlay wheel-odometry path as a purple polyline.
		if (poseCount > 1) {
			for (int32_t i = 1; i < poseCount; ++i) {
				const int32_t base0 = (i - 1) * 3;
				const int32_t base1 = i * 3;
				const double x0_world = POSES[base0 + 0];
				const double y0_world = POSES[base0 + 1];
				const double x1_world = POSES[base1 + 0];
				const double y1_world = POSES[base1 + 1];
				int32_t gx0 = 0, gy0 = 0, gx1 = 0, gy1 = 0;
				if (!world_to_grid(x0_world, y0_world, &gx0, &gy0) ||
					!world_to_grid(x1_world, y1_world, &gx1, &gy1)) {
					continue;
				}
				int32_t px0 = 0, py0 = 0, px1 = 0, py1 = 0;
				if (!grid_to_pixel(gx0, gy0, scale, off_x, off_y, &px0, &py0) ||
					!grid_to_pixel(gx1, gy1, scale, off_x, off_y, &px1, &py1)) {
					continue;
				}
				draw_line_pixel(px0, py0, px1, py1, 128, 0, 128, 255);
			}
		}

		draw_planned_path_overlay(scale, off_x, off_y);
		draw_goal_marker(scale, off_x, off_y);

		// Overlay only the latest pose as a 3x3 white dot.
		if (poseCount > 0) {
			int32_t base = (poseCount - 1) * 3;
			const double px_world = POSES[base + 0];
			const double py_world = POSES[base + 1];
			int32_t gx = 0;
			int32_t gy = 0;
			if (world_to_grid(px_world, py_world, &gx, &gy)) {
				int32_t px = 0;
				int32_t py = 0;
				if (grid_to_pixel(gx, gy, scale, off_x, off_y, &px, &py)) {
					for (int dy = -1; dy <= 1; ++dy) {
						for (int dx = -1; dx <= 1; ++dx) {
							int32_t x = clampi(px + dx, 0, CUR_W - 1);
							int32_t y = clampi(py + dy, 0, CUR_H - 1);
							int32_t o = (y * CUR_W + x) * 4;
							IMAGE[o + 0] = 255;
							IMAGE[o + 1] = 255;
							IMAGE[o + 2] = 255;
							IMAGE[o + 3] = 255;
						}
					}
				}
			}
		}

		// Pose axes for the most recent pose: forward=red, left=green.
		if (poseCount > 0) {
			const double axis_len_m = 0.5;
			const int32_t base = (poseCount - 1) * 3;
			const double px_world = POSES[base + 0];
			const double py_world = POSES[base + 1];
			const double theta = POSES[base + 2];
			const double fx_world = px_world + cos(theta) * axis_len_m;
			const double fy_world = py_world + sin(theta) * axis_len_m;
			const double lx_world = px_world - sin(theta) * axis_len_m;
			const double ly_world = py_world + cos(theta) * axis_len_m;

			int32_t gx0 = 0, gy0 = 0, gfx = 0, gfy = 0;
			if (world_to_grid(px_world, py_world, &gx0, &gy0) &&
				world_to_grid(fx_world, fy_world, &gfx, &gfy)) {
				int32_t px0 = 0, py0 = 0, pfx = 0, pfy = 0;
				if (grid_to_pixel(gx0, gy0, scale, off_x, off_y, &px0, &py0) &&
					grid_to_pixel(gfx, gfy, scale, off_x, off_y, &pfx, &pfy)) {
					draw_line_pixel(px0, py0, pfx, pfy, 255, 0, 0, 255);
				}
			}

			int32_t glx = 0, gly = 0;
			if (world_to_grid(px_world, py_world, &gx0, &gy0) &&
				world_to_grid(lx_world, ly_world, &glx, &gly)) {
				int32_t px0 = 0, py0 = 0, plx = 0, ply = 0;
				if (grid_to_pixel(gx0, gy0, scale, off_x, off_y, &px0, &py0) &&
					grid_to_pixel(glx, gly, scale, off_x, off_y, &plx, &ply)) {
					draw_line_pixel(px0, py0, plx, ply, 0, 255, 0, 255);
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
