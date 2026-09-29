/* The screenshot editor's stand-in. The compositor spawns `imscreenshot fd:3`
 * (the suite's im screenshot) with the capture on fd 3 and its settings in
 * the environment; the scenarios put this program on PATH under that name,
 * and it reports what the compositor handed over instead of editing it.
 *
 * The report goes to <IMWAY_SHOT_DIR>/<IMWAY_SHOT_NAME>.shim as key=value
 * lines, one per fact: the source (a self-describing IMW1 memfd read whole,
 * or a dma-buf described by IMWAY_SHOT_DMABUF), its size and layout, and
 * every setting the environment carried. A memfd's pixels are also written
 * next to it as <name>.ppm, for the scenarios that compare the capture with
 * the output. Any action but `save` then maps a window titled like the
 * editor, showing the capture (a memfd's pixels through wl_shm, a dma-buf
 * attached as it is), until it is closed or Escape is pressed. */
#include "wl_util.h"

#include <linux-dmabuf-v1-client-protocol.h>

#include <sys/stat.h>

static const char* env_or(const char* name, const char* fallback) {
    const char* value = getenv(name);
    return value && *value ? value : fallback;
}

static void mkdirs(const char* path) {
    char copy[1024];
    snprintf(copy, sizeof(copy), "%s", path);
    for (char* p = copy + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            mkdir(copy, 0755);
            *p = '/';
        }
    }
    mkdir(copy, 0755);
}

/* the capture fd: fd:N as handed over, or a file named on the command line */
static int take_fd(const char* spec) {
    if (!strncmp(spec, "fd:", 3)) {
        return atoi(spec + 3);
    }
    return open(spec, O_RDONLY | O_CLOEXEC);
}

static uint8_t* read_whole(int fd, size_t* size) {
    size_t cap = 1 << 20, used = 0;
    uint8_t* data = malloc(cap);
    for (;;) {
        if (used == cap) {
            cap *= 2;
            data = realloc(data, cap);
        }
        ssize_t n = pread(fd, data + used, cap - used, (off_t)used);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        used += (size_t)n;
    }
    *size = used;
    return data;
}

/* the scanout's VkFormat as the compositor names it, and the DRM fourcc the
 * same layout goes by on the wire, for the formats a scanout can have */
static uint32_t fourcc_of(unsigned long long vkformat) {
    switch (vkformat) {
        case 44: return 0x34325258u; /* B8G8R8A8_UNORM: XR24 */
        case 37: return 0x34324258u; /* R8G8B8A8_UNORM: XB24 */
        case 58: return 0x30335258u; /* A2R10G10B10_UNORM_PACK32: XR30 */
        case 64: return 0x30334258u; /* A2B10G10R10_UNORM_PACK32: XB30 */
        default: return 0;
    }
}

static void fourcc_name(uint32_t code, char out[5]) {
    for (int i = 0; i < 4; i++) {
        out[i] = code ? (char)((code >> (8 * i)) & 0xff) : '?';
    }
    out[4] = 0;
}

/* the dma-buf as a wl_buffer, for the window to show what the editor was
 * handed without any GPU of its own */
static struct zwp_linux_dmabuf_v1* dmabuf_global;
static int dmabuf_fd = -1;
static uint32_t dmabuf_fourcc, dmabuf_offset, dmabuf_stride;
static unsigned long long dmabuf_modifier;

static void extra_global(void* d, struct wl_registry* r, uint32_t name, const char* iface, uint32_t ver) {
    (void)d;
    (void)ver;
    if (!strcmp(iface, zwp_linux_dmabuf_v1_interface.name)) {
        dmabuf_global = wl_registry_bind(r, name, &zwp_linux_dmabuf_v1_interface, 3);
    }
}

static void extra_remove(void* d, struct wl_registry* r, uint32_t n) {
    (void)d;
    (void)r;
    (void)n;
}

static const struct wl_registry_listener extra_listener = {extra_global, extra_remove};

/* the window: the editor's title and app id over the capture, a memfd's
 * pixels copied into a wl_shm buffer or the dma-buf attached as it came,
 * closed by the compositor or by Escape */
static struct wl_toplevel_ctx window;
static const uint8_t* window_px;
static uint32_t window_w, window_h;

static void shim_xdg_configure(void* d, struct xdg_surface* xs, uint32_t serial) {
    (void)d;
    xdg_surface_ack_configure(xs, serial);
    if (window.committed) return;
    if (dmabuf_fd >= 0) {
        struct zwp_linux_buffer_params_v1* params = zwp_linux_dmabuf_v1_create_params(dmabuf_global);
        zwp_linux_buffer_params_v1_add(params, dmabuf_fd, 0, dmabuf_offset, dmabuf_stride, (uint32_t)(dmabuf_modifier >> 32), (uint32_t)dmabuf_modifier);
        struct wl_buffer* buf = zwp_linux_buffer_params_v1_create_immed(params, (int)window_w, (int)window_h, dmabuf_fourcc, 0);
        zwp_linux_buffer_params_v1_destroy(params);
        wl_surface_attach(window.surface, buf, 0, 0);
        wl_surface_damage(window.surface, 0, 0, (int)window_w, (int)window_h);
        wl_surface_commit(window.surface);
        window.committed = 1;
        return;
    }
    int stride = (int)window_w * 4, size = stride * (int)window_h;
    int fd = memfd_create("shot-shim", 0);
    if (fd < 0 || ftruncate(fd, size) < 0) {
        perror("memfd");
        exit(1);
    }
    uint32_t* px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    for (uint32_t i = 0; i < window_w * window_h; i++) {
        if (window_px) {
            const uint8_t* s = window_px + (size_t)i * 4;
            px[i] = 0xff000000u | ((uint32_t)s[0] << 16) | ((uint32_t)s[1] << 8) | s[2];
        } else {
            px[i] = 0xff404040u;
        }
    }
    munmap(px, size);
    struct wl_shm_pool* pool = wl_shm_create_pool(wl_shm_g, fd, size);
    struct wl_buffer* buf = wl_shm_pool_create_buffer(pool, 0, (int)window_w, (int)window_h, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    wl_surface_attach(window.surface, buf, 0, 0);
    wl_surface_damage(window.surface, 0, 0, (int)window_w, (int)window_h);
    wl_surface_commit(window.surface);
    window.committed = 1;
}

static const struct xdg_surface_listener shim_xdg_listener = {shim_xdg_configure};

int main(int argc, char** argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc < 2) {
        fprintf(stderr, "usage: imscreenshot <path|fd:N>\n");
        return 2;
    }

    const char* dir = env_or("IMWAY_SHOT_DIR", ".");
    const char* name = env_or("IMWAY_SHOT_NAME", "shot");
    const char* action = env_or("IMWAY_SHOT_ACTION", "editor");
    const char* dmabuf = getenv("IMWAY_SHOT_DMABUF");
    int fd = take_fd(argv[1]);

    if (fd < 0) {
        fprintf(stderr, "shim: cannot open %s: %s\n", argv[1], strerror(errno));
        return 1;
    }

    mkdirs(dir);

    char path[1200];
    snprintf(path, sizeof(path), "%s/%s.shim", dir, name);
    FILE* report = fopen(path, "w");
    if (!report) {
        fprintf(stderr, "shim: cannot write %s: %s\n", path, strerror(errno));
        return 1;
    }

    uint8_t* file = NULL;
    size_t bytes = 0;
    uint32_t w = 0, h = 0;

    if (dmabuf) {
        /* W:H:FORMAT:OFFSET:STRIDE:MODIFIER:SIZE:UUID, as the compositor spells it */
        unsigned long long v[7] = {0};
        char uuid[40] = "";
        if (sscanf(dmabuf, "%llu:%llu:%llu:%llu:%llu:%llu:%llu:%39s", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], uuid) != 8) {
            fprintf(report, "source=dmabuf\nerror=bad spec %s\n", dmabuf);
            fclose(report);
            fprintf(stderr, "shim: bad IMWAY_SHOT_DMABUF: %s\n", dmabuf);
            return 1;
        }
        w = (uint32_t)v[0];
        h = (uint32_t)v[1];
        char code[5];
        fourcc_name(fourcc_of(v[2]), code);
        dmabuf_fd = fd;
        dmabuf_fourcc = fourcc_of(v[2]);
        dmabuf_offset = (uint32_t)v[3];
        dmabuf_stride = (uint32_t)v[4];
        dmabuf_modifier = v[5];
        /* a dma-buf tells its size through lseek; a plain file would too, so
         * the fd's own name says which it is */
        char link[64], target[128] = "";
        snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
        ssize_t n = readlink(link, target, sizeof(target) - 1);
        if (n > 0) target[n] = 0;
        off_t end = lseek(fd, 0, SEEK_END);
        fprintf(report, "source=dmabuf\nwidth=%u\nheight=%u\nvkformat=%llu\nfourcc=%s\noffset=%llu\nstride=%llu\nmodifier=%llu\nsize=%llu\nuuid=%s\nfd-size=%lld\nfd-name=%s\n",
                w, h, v[2], code, v[3], v[4], v[5], v[6], uuid, (long long)end, target);
    } else {
        file = read_whole(fd, &bytes);
        const uint32_t* hdr = (const uint32_t*)file;
        if (bytes < 12 || hdr[0] != 0x31574d49u || !hdr[1] || !hdr[2] || bytes < 12 + (size_t)hdr[1] * hdr[2] * 4) {
            fprintf(report, "source=memfd\nerror=not an IMW1 capture (%zu bytes)\n", bytes);
            fclose(report);
            fprintf(stderr, "shim: not an IMW1 capture (%zu bytes)\n", bytes);
            return 1;
        }
        w = hdr[1];
        h = hdr[2];
        fprintf(report, "source=memfd\nwidth=%u\nheight=%u\nbytes=%zu\n", w, h, bytes);
        /* the pixels, RGBA8 rows, as a P6 for the scenarios to compare */
        snprintf(path, sizeof(path), "%s/%s.ppm", dir, name);
        FILE* ppm = fopen(path, "wb");
        if (ppm) {
            fprintf(ppm, "P6\n%u %u\n255\n", w, h);
            const uint8_t* px = file + 12;
            for (size_t i = 0; i < (size_t)w * h; i++) {
                fwrite(px + i * 4, 1, 3, ppm);
            }
            fclose(ppm);
        }
    }

    fprintf(report, "action=%s\nformat=%s\nlossless=%s\nquality=%s\ncolor=%s\nscale=%s\n",
            action, env_or("IMWAY_SHOT_FORMAT", ""), env_or("IMWAY_SHOT_LOSSLESS", ""),
            env_or("IMWAY_SHOT_QUALITY", ""), env_or("IMWAY_SHOT_COLOR", ""), env_or("IMGUI_SCALE", ""));
    fclose(report);
    snprintf(path, sizeof(path), "%s/%s.shim", dir, name);
    printf("shim: %s %ux%u action %s, receipt %s\n", dmabuf ? "dma-buf" : "memfd", w, h, action, path);

    if (!strcmp(action, "save")) {
        free(file);
        return 0;
    }

    if (wl_boot()) {
        free(file);
        return 1;
    }

    if (dmabuf_fd >= 0) {
        struct wl_registry* registry = wl_display_get_registry(wl_dpy);
        wl_registry_add_listener(registry, &extra_listener, NULL);
        wl_display_roundtrip(wl_dpy);
        if (!dmabuf_global || !dmabuf_fourcc) {
            fprintf(stderr, "shim: cannot show the dma-buf: %s\n", dmabuf_global ? "unknown scanout format" : "no linux-dmabuf");
            return 1;
        }
    }

    window_px = file ? file + 12 : NULL;
    window_w = w;
    window_h = h;
    window.w = (int)w;
    window.h = (int)h;
    window.surface = wl_compositor_create_surface(wl_comp);
    window.xs = xdg_wm_base_get_xdg_surface(wl_wm, window.surface);
    xdg_surface_add_listener(window.xs, &shim_xdg_listener, &window);
    window.tl = xdg_surface_get_toplevel(window.xs);
    xdg_toplevel_add_listener(window.tl, &wl_tl_listener, &window);
    xdg_toplevel_set_title(window.tl, "im screenshot");
    xdg_toplevel_set_app_id(window.tl, "im-screenshot");
    wl_surface_commit(window.surface);
    printf("shim: window mapped\n");

    /* Escape leaves as the editor does: with nothing saved */
    wlk_watch_key = 1;
    int escaped = 0;
    while (!escaped && wl_display_dispatch(wl_dpy) != -1) {
        escaped = wlk_watch_hits;
    }
    if (escaped) {
        printf("shim: escape\n");
    }
    free(file);
    return 0;
}
