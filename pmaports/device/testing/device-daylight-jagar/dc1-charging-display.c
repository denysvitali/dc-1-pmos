/* Take over LK's inherited image, then shut down the panel through DRM.
 * A disable on an initially inactive CRTC can be a no-op: first establish
 * Linux ownership with one white frame at the existing preferred 60 Hz mode.
 * Never steal a compositor's DRM master, change timings, or issue DCS reads.
 */
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

static int preferred_mode(const drmModeModeInfo *mode)
{
	double hz = mode->htotal && mode->vtotal ?
		(double)mode->clock * 1000 / mode->htotal / mode->vtotal : 0;
	return mode->hdisplay == 1200 && mode->vdisplay == 1600 &&
		(mode->type & DRM_MODE_TYPE_PREFERRED) && hz >= 59 && hz <= 61;
}

static int blank_and_disable(int fd, uint32_t connector, uint32_t crtc,
			     drmModeModeInfo *mode)
{
	struct drm_mode_create_dumb create = {
		.width = mode->hdisplay, .height = mode->vdisplay, .bpp = 32,
	};
	struct drm_mode_map_dumb map = {0};
	struct drm_mode_destroy_dumb destroy = {0};
	uint32_t handles[4] = {0}, pitches[4] = {0}, offsets[4] = {0}, fb = 0;
	void *pixels = MAP_FAILED;
	int result = -1, enabled = 0;
	drmModeCrtc *state;

	if (drmSetMaster(fd) < 0) {
		perror("charging display: acquire DRM master");
		return -1;
	}
	if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &create) < 0)
		goto out;
	destroy.handle = handles[0] = create.handle;
	pitches[0] = create.pitch;
	if (drmModeAddFB2(fd, create.width, create.height, DRM_FORMAT_XRGB8888,
			 handles, pitches, offsets, &fb, 0) < 0)
		goto out;
	map.handle = create.handle;
	if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &map) < 0)
		goto out;
	pixels = mmap(NULL, create.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, map.offset);
	if (pixels == MAP_FAILED)
		goto out;
	memset(pixels, 0xff, create.size);
	enabled = 1;
	if (drmModeSetCrtc(fd, crtc, fb, 0, 0, &connector, 1, mode) < 0)
		goto out;
	usleep(100000);
	if (drmModeSetCrtc(fd, crtc, 0, 0, 0, NULL, 0, NULL) < 0)
		goto out;
	enabled = 0;
	state = drmModeGetCrtc(fd, crtc);
	if (state) {
		result = state->mode_valid || state->buffer_id ? -1 : 0;
		drmModeFreeCrtc(state);
	}
out:
	/* Best effort on error too; do not leave our test scanout running. */
	if (enabled)
		drmModeSetCrtc(fd, crtc, 0, 0, 0, NULL, 0, NULL);
	if (pixels != MAP_FAILED)
		munmap(pixels, create.size);
	if (fb)
		drmModeRmFB(fd, fb);
	if (destroy.handle)
		drmIoctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
	drmDropMaster(fd);
	if (result)
		fprintf(stderr, "charging display: panel shutdown was not confirmed\n");
	return result;
}

static int run_card(const char *path, int check_only)
{
	int fd = open(path, O_RDWR | O_CLOEXEC), result = -1;
	drmVersionPtr version;
	drmModeRes *resources;
	if (fd < 0)
		return -1;
	version = drmGetVersion(fd);
	if (!version || !version->name || strcmp(version->name, "mediatek")) {
		if (version) drmFreeVersion(version);
		close(fd);
		return -1;
	}
	drmFreeVersion(version);
	resources = drmModeGetResources(fd);
	if (!resources) {
		close(fd);
		return -1;
	}
	for (int i = 0; i < resources->count_connectors && result; i++) {
		drmModeConnector *conn = drmModeGetConnector(fd, resources->connectors[i]);
		if (!conn)
			continue;
		if (conn->connector_type == DRM_MODE_CONNECTOR_DSI &&
		    conn->connection == DRM_MODE_CONNECTED) {
			for (int m = 0; m < conn->count_modes && result; m++) {
				if (!preferred_mode(&conn->modes[m]))
					continue;
				for (int e = 0; e < conn->count_encoders && result; e++) {
					drmModeEncoder *enc = drmModeGetEncoder(fd, conn->encoders[e]);
					if (!enc) continue;
					for (int c = 0; c < resources->count_crtcs && c < 32; c++) {
						if (!(enc->possible_crtcs & (1u << c))) continue;
						printf("charging display: %s DSI connector %u CRTC %u preferred 60 Hz%s\n",
						       path, conn->connector_id, resources->crtcs[c],
						       check_only ? " (inspection only)" : "");
						result = check_only ? 0 : blank_and_disable(fd, conn->connector_id,
							resources->crtcs[c], &conn->modes[m]);
						result = result ? 1 : 0;
						/* One power sequence only, even if it failed. */
						drmModeFreeEncoder(enc);
						drmModeFreeConnector(conn);
						goto out;
					}
					drmModeFreeEncoder(enc);
				}
			}
		}
		drmModeFreeConnector(conn);
	}
out:
	drmModeFreeResources(resources);
	close(fd);
	return result;
}

int main(int argc, char **argv)
{
	char target[256];
	glob_t cards = {0};
	int check_only = argc == 2 && !strcmp(argv[1], "--check");
	if (argc != 2 || (!check_only && strcmp(argv[1], "--off"))) {
		fprintf(stderr, "usage: %s --check|--off\n", argv[0]);
		return 2;
	}
	if (!check_only) {
		ssize_t length = readlink("/run/systemd/generator.early/default.target", target, sizeof(target) - 1);
		if (length < 0) {
			perror("charging display: no charging-boot marker");
			return 1;
		}
		target[length] = 0;
		if (strcmp(target, "/usr/lib/systemd/system/dc1-charging.target")) {
			fprintf(stderr, "charging display: refusing outside a charging boot\n");
			return 1;
		}
	}
	/* The GPU may be card0; identify the actual KMS device and DSI connector. */
	for (int attempt = 0; attempt < (check_only ? 1 : 10); attempt++) {
		if (!glob("/dev/dri/card[0-9]*", 0, NULL, &cards)) {
			for (size_t i = 0; i < cards.gl_pathc; i++) {
				int result = run_card(cards.gl_pathv[i], check_only);
				if (result >= 0) {
					globfree(&cards);
					return result;
				}
			}
		}
		globfree(&cards);
		memset(&cards, 0, sizeof(cards));
		if (!check_only) sleep(1);
	}
	fprintf(stderr, "charging display: no usable preferred 60 Hz DSI output\n");
	return 1;
}
