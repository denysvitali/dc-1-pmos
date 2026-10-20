/* Mock the DRM boundary: no display, root or DRM master is used by tests. */
#include <assert.h>
#include <stdlib.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <sys/mman.h>
#include <unistd.h>

#define main charging_display_main
#define drmSetMaster test_master
#define drmDropMaster test_drop
#define drmIoctl test_ioctl
#define drmModeAddFB2 test_addfb
#define drmModeRmFB test_rmfb
#define drmModeSetCrtc test_setcrtc
#define drmModeGetCrtc test_getcrtc
#define drmModeFreeCrtc test_freecrtc
#define mmap test_map
#define munmap test_unmap
#define usleep test_sleep

static int test_master(int);
static int test_drop(int);
static int test_ioctl(int, unsigned long, void *);
static int test_addfb(int, uint32_t, uint32_t, uint32_t, const uint32_t[4],
                     const uint32_t[4], const uint32_t[4], uint32_t *, uint32_t);
static int test_rmfb(int, uint32_t);
static int test_setcrtc(int, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t *, int, drmModeModeInfoPtr);
static drmModeCrtc *test_getcrtc(int, uint32_t);
static void test_freecrtc(drmModeCrtc *);
static void *test_map(void *, size_t, int, int, int, off_t);
static int test_unmap(void *, size_t);
static int test_sleep(useconds_t);

#include "../../pmaports/device/testing/device-daylight-jagar/dc1-charging-display.c"
#undef main

static int master_busy, enable_fails, disable_fails, readback_active, addfb_fails;
static int enables, disables, creates, destroys, drops, removes, maps;
static unsigned char pixels[1200 * 1600 * 4];
static drmModeModeInfo mode = { .hdisplay = 1200, .vdisplay = 1600,
    .htotal = 1310, .vtotal = 3324, .clock = 261267,
    .type = DRM_MODE_TYPE_PREFERRED };

static void reset(void) {
    master_busy = enable_fails = disable_fails = readback_active = addfb_fails = 0;
    enables = disables = creates = destroys = drops = removes = maps = 0;
    memset(pixels, 0, sizeof(pixels));
}
static int test_master(int fd) { assert(fd == 9); if (master_busy) { errno = EBUSY; return -1; } return 0; }
static int test_drop(int fd) { assert(fd == 9); drops++; return 0; }
static int test_ioctl(int fd, unsigned long request, void *data) {
    assert(fd == 9);
    if (request == DRM_IOCTL_MODE_CREATE_DUMB) {
        struct drm_mode_create_dumb *create = data;
        assert(create->width == 1200 && create->height == 1600 && create->bpp == 32);
        create->handle = 12; create->pitch = 4800; create->size = sizeof(pixels); creates++;
    } else if (request == DRM_IOCTL_MODE_MAP_DUMB) {
        assert(((struct drm_mode_map_dumb *)data)->handle == 12);
    } else {
        assert(request == DRM_IOCTL_MODE_DESTROY_DUMB);
        assert(((struct drm_mode_destroy_dumb *)data)->handle == 12); destroys++;
    }
    return 0;
}
static int test_addfb(int fd, uint32_t w, uint32_t h, uint32_t format,
    const uint32_t handles[4], const uint32_t pitches[4], const uint32_t offsets[4],
    uint32_t *fb, uint32_t flags) {
    assert(fd == 9 && w == 1200 && h == 1600 && format == DRM_FORMAT_XRGB8888);
    assert(handles[0] == 12 && pitches[0] == 4800 && !offsets[0] && !flags);
    if (addfb_fails) return -1;
    *fb = 13; return 0;
}
static int test_rmfb(int fd, uint32_t fb) { assert(fd == 9 && fb == 13); removes++; return 0; }
static void *test_map(void *addr, size_t size, int prot, int flags, int fd, off_t offset) {
    (void)addr; (void)prot; (void)flags; (void)offset;
    assert(fd == 9 && size == sizeof(pixels)); maps++; return pixels;
}
static int test_unmap(void *addr, size_t size) {
    assert(addr == pixels && size == sizeof(pixels)); maps--; return 0;
}
static int test_setcrtc(int fd, uint32_t crtc, uint32_t fb, uint32_t x, uint32_t y,
    uint32_t *connectors, int count, drmModeModeInfoPtr selected) {
    assert(fd == 9 && crtc == 57 && !x && !y);
    if (fb) {
        assert(fb == 13 && count == 1 && *connectors == 36 && preferred_mode(selected));
        for (size_t i = 0; i < sizeof(pixels); i++) assert(pixels[i] == 255);
        enables++; return enable_fails ? -1 : 0;
    }
    assert(!connectors && !count && !selected);
    disables++; return disable_fails ? -1 : 0;
}
static drmModeCrtc *test_getcrtc(int fd, uint32_t crtc) {
    assert(fd == 9 && crtc == 57);
    drmModeCrtc *state = calloc(1, sizeof(*state));
    assert(state); state->mode_valid = readback_active; return state;
}
static void test_freecrtc(drmModeCrtc *state) { free(state); }
static int test_sleep(useconds_t duration) { assert(duration == 100000); return 0; }

int main(void) {
    assert(preferred_mode(&mode));
    drmModeModeInfo fast = mode; fast.vtotal = 1662;
    assert(!preferred_mode(&fast));
    reset(); assert(!blank_and_disable(9, 36, 57, &mode));
    assert(enables == 1 && disables == 1 && destroys == 1 && removes == 1 && drops == 1 && maps == 0);
    reset(); master_busy = 1; assert(blank_and_disable(9, 36, 57, &mode));
    assert(!creates && !enables && !disables && !drops);
    reset(); enable_fails = 1; assert(blank_and_disable(9, 36, 57, &mode));
    assert(enables == 1 && disables == 1 && destroys == 1 && removes == 1 && !maps);
    reset(); disable_fails = 1; assert(blank_and_disable(9, 36, 57, &mode));
    assert(enables == 1 && disables == 2 && destroys == 1 && drops == 1 && !maps);
    reset(); readback_active = 1; assert(blank_and_disable(9, 36, 57, &mode));
    reset(); addfb_fails = 1; assert(blank_and_disable(9, 36, 57, &mode));
    assert(!enables && destroys == 1 && !removes && !maps);
    puts("charging display DRM tests passed");
    return 0;
}
