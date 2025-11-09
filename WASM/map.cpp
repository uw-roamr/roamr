// WASM helpers to accept multiple poses and render a simple RGBA map image.
// Coordinate space: inputs are (x, y, theta) in meters; we autoscale to fit.
#include <stdint.h>
#include <float.h>

extern "C" {

// Legacy single-pose API kept for convenience/testing.
void log_pose_f32(float x, float y, float theta) {
	(void)x; (void)y; (void)theta;
}

// Pose storage
static const int32_t MAX_POSES = 4096;
static float POSES[3 * MAX_POSES]; // x,y,theta triples

// Image buffer (RGBA8888)
static const int32_t MAX_W = 512;
static const int32_t MAX_H = 512;
static uint8_t IMAGE[MAX_W * MAX_H * 4];
static int32_t CUR_W = 256;
static int32_t CUR_H = 256;

void reset_poses() {
	for (int32_t i = 0; i < 3 * MAX_POSES; ++i) {
		POSES[i] = 0.0f;
	}
}

// Set a single pose at index (0-based). Extra indices are ignored.
void set_pose(int32_t idx, float x, float y, float theta) {
	if (idx < 0 || idx >= MAX_POSES) return;
	int32_t base = idx * 3;
	POSES[base + 0] = x;
	POSES[base + 1] = y;
	POSES[base + 2] = theta;
}

static inline int32_t clampi(int32_t v, int32_t lo, int32_t hi) {
	return v < lo ? lo : (v > hi ? hi : v);
}

// Very simple nearest-neighbor mapping: autoscale poses to fit into WxH canvas,
// center them, and plot white pixels. Theta is currently unused for rendering.
void draw_pose_map(int32_t count, int32_t width, int32_t height) {
	if (count < 0) count = 0;
	if (count > MAX_POSES) count = MAX_POSES;
	if (width <= 0) width = 256;
	if (height <= 0) height = 256;
	if (width > MAX_W) width = MAX_W;
	if (height > MAX_H) height = MAX_H;
	CUR_W = width;
	CUR_H = height;
	const int32_t stride = CUR_W * 4;

	// Clear to black
	for (int32_t y = 0; y < CUR_H; ++y) {
		for (int32_t x = 0; x < CUR_W; ++x) {
			int32_t o = y * stride + x * 4;
			IMAGE[o + 0] = 0; // R
			IMAGE[o + 1] = 0; // G
			IMAGE[o + 2] = 0; // B
			IMAGE[o + 3] = 255; // A
		}
	}

	// Compute bounds
	float minX = FLT_MAX, minY = FLT_MAX, maxX = -FLT_MAX, maxY = -FLT_MAX;
	bool any = false;
	for (int32_t i = 0; i < count; ++i) {
		int32_t base = i * 3;
		float px = POSES[base + 0];
		float py = POSES[base + 1];
		if (px == 0.0f && py == 0.0f && POSES[base + 2] == 0.0f) continue; // treat zeroed as empty
		if (px < minX) minX = px;
		if (py < minY) minY = py;
		if (px > maxX) maxX = px;
		if (py > maxY) maxY = py;
		any = true;
	}
	if (!any) return;

	// Pad bounds a bit
	const float pad = 0.05f;
	float dx = maxX - minX;
	float dy = maxY - minY;
	if (dx <= 0.0f) dx = 1.0f;
	if (dy <= 0.0f) dy = 1.0f;
	minX -= dx * pad; maxX += dx * pad;
	minY -= dy * pad; maxY += dy * pad;
	dx = maxX - minX; dy = maxY - minY;

	// Maintain aspect ratio
	float scaleX = (float)(CUR_W - 1) / dx;
	float scaleY = (float)(CUR_H - 1) / dy;
	float scale = scaleX < scaleY ? scaleX : scaleY;

	// Centering offsets
	float cx = (minX + maxX) * 0.5f;
	float cy = (minY + maxY) * 0.5f;

	for (int32_t i = 0; i < count; ++i) {
		int32_t base = i * 3;
		float px = POSES[base + 0];
		float py = POSES[base + 1];
		// Map to image coordinates (origin top-left)
		int32_t ix = (int32_t)((px - cx) * scale + (float)CUR_W * 0.5f);
		int32_t iy = (int32_t)((cy - py) * scale + (float)CUR_H * 0.5f);
		ix = clampi(ix, 0, CUR_W - 1);
		iy = clampi(iy, 0, CUR_H - 1);
		// Draw a 3x3 white dot
		for (int dy = -1; dy <= 1; ++dy) {
			for (int dx = -1; dx <= 1; ++dx) {
				int32_t x = clampi(ix + dx, 0, CUR_W - 1);
				int32_t y = clampi(iy + dy, 0, CUR_H - 1);
				int32_t o = y * stride + x * 4;
				IMAGE[o + 0] = 255;
				IMAGE[o + 1] = 255;
				IMAGE[o + 2] = 255;
				IMAGE[o + 3] = 255;
			}
		}
	}
}

// Image accessors
int32_t get_image_width() { return CUR_W; }
int32_t get_image_height() { return CUR_H; }

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

} // extern "C"

