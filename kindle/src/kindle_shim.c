/*
 * Preloaded into Amazon's kindle_browser (Chromium 75) by the MDict plugin.
 *
 * - KO_DEVTOOLS_PIPE=1: starts Chromium's DevTools pipe handler (fds 3 and 4), which
 *   kindle_browser never starts itself, once the browser context exists.
 * - KO_OFFSCREEN=x[,y]: top-level windows are created override-redirect at x,y, so they
 *   map without a window manager (KOReader stops Amazon's) and stay off the screen.
 * - KO_QUIET_LIPC=1: the browser's messages to the rest of the system (the app manager,
 *   the title bar, browser history and settings) are dropped, so it stays invisible to
 *   them: the Kindle does not show the browser's title bar, and nothing is added to
 *   the browser's history.
 *
 * Built against the browser's own C library (glibc 2.27): only old symbol versions.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <X11/Xlib.h>

typedef void (*create_services_fn)(void *self, void *browser_context);
typedef void (*start_pipe_fn)(void);
typedef Window (*create_window_fn)(Display *, Window, int, int, unsigned int, unsigned int, unsigned int,
                                   int, unsigned int, Visual *, unsigned long, XSetWindowAttributes *);
typedef Window (*root_fn)(Display *);
typedef int (*set_str_fn)(void *lipc, const char *service, const char *prop, const char *value);
typedef int (*get_str_fn)(void *lipc, const char *service, const char *prop, char **value);
typedef int (*set_int_fn)(void *lipc, const char *service, const char *prop, int value);
typedef int (*send_event_fn)(void *lipc, void *event);

static long parse_long(const char **s) {
    long sign = 1, v = 0;
    if (**s == '-') { sign = -1; (*s)++; }
    while (**s >= '0' && **s <= '9') { v = v * 10 + (**s - '0'); (*s)++; }
    return sign * v;
}

#define CREATE_SERVICES "_ZN31BrowserContextDependencyManager28CreateBrowserContextServicesEPN7content14BrowserContextE"
#define START_PIPE "_ZN7content17DevToolsAgentHost31StartRemoteDebuggingPipeHandlerEv"

void _ZN31BrowserContextDependencyManager28CreateBrowserContextServicesEPN7content14BrowserContextE(void *self, void *ctx) {
    static int started;
    create_services_fn real = (create_services_fn)dlsym(RTLD_NEXT, CREATE_SERVICES);
    if (real) real(self, ctx);
    if (!started && getenv("KO_DEVTOOLS_PIPE")) {
        start_pipe_fn start = (start_pipe_fn)dlsym(RTLD_DEFAULT, START_PIPE);
        started = 1;
        syslog(LOG_INFO, "ko-mdict-shim: DevTools pipe %s", start ? "started" : "missing");
        if (start) start();
    }
}

Window XCreateWindow(Display *dpy, Window parent, int x, int y, unsigned int w, unsigned int h, unsigned int border,
                     int depth, unsigned int cls, Visual *visual, unsigned long mask, XSetWindowAttributes *attrs) {
    static create_window_fn real;
    static root_fn root;
    const char *off = getenv("KO_OFFSCREEN");
    XSetWindowAttributes local;
    if (!real) real = (create_window_fn)dlsym(RTLD_NEXT, "XCreateWindow");
    if (!root) root = (root_fn)dlsym(RTLD_DEFAULT, "XDefaultRootWindow");
    if (!real) return 0;
    if (off && root && parent == root(dpy)) {
        const char *p = off;
        long ox = parse_long(&p), oy = 0;
        if (*p == ',' || *p == ':') { p++; oy = parse_long(&p); }
        if (!attrs) { attrs = &local; mask = 0; }
        attrs->override_redirect = True;
        mask |= CWOverrideRedirect;
        syslog(LOG_INFO, "ko-mdict-shim: window %ux%u at %d,%d -> override-redirect at %ld,%ld", w, h, x, y, ox, oy);
        x = (int)ox;
        y = (int)oy;
    }
    return real(dpy, parent, x, y, w, h, border, depth, cls, visual, mask, attrs);
}

/* Services the browser must not reach while KOReader uses it. */
static int quiet(const char *service) {
    static const char *const blocked[] = { "com.lab126.appmgrd", "com.lab126.chromebar", "com.lab126.kppbrowser",
                                           "com.lab126.pillow", 0 };
    int i;
    if (!service || !getenv("KO_QUIET_LIPC")) return 0;
    for (i = 0; blocked[i]; i++)
        if (strcmp(service, blocked[i]) == 0) return 1;
    return 0;
}

int LipcSetStringProperty(void *lipc, const char *service, const char *prop, const char *value) {
    static set_str_fn real;
    if (quiet(service)) {
        syslog(LOG_INFO, "ko-mdict-shim: dropped %s %s", service, prop ? prop : "");
        return 0;
    }
    if (!real) real = (set_str_fn)dlsym(RTLD_NEXT, "LipcSetStringProperty");
    return real ? real(lipc, service, prop, value) : 1;
}

int LipcSetIntProperty(void *lipc, const char *service, const char *prop, int value) {
    static set_int_fn real;
    if (quiet(service)) {
        syslog(LOG_INFO, "ko-mdict-shim: dropped %s %s", service, prop ? prop : "");
        return 0;
    }
    if (!real) real = (set_int_fn)dlsym(RTLD_NEXT, "LipcSetIntProperty");
    return real ? real(lipc, service, prop, value) : 1;
}

/* Answers what the app manager would say while the browser is in front. */
int LipcGetStringProperty(void *lipc, const char *service, const char *prop, char **value) {
    static get_str_fn real;
    if (quiet(service)) {
        const char *answer = "";
        if (prop && strcmp(prop, "activeView") == 0) answer = "com.lab126.browser";
        else if (prop && strcmp(prop, "getAllSettings") == 0) answer = "{}";
        syslog(LOG_INFO, "ko-mdict-shim: answered %s %s", service, prop ? prop : "");
        if (value) *value = strdup(answer);
        return 0;
    }
    if (!real) real = (get_str_fn)dlsym(RTLD_NEXT, "LipcGetStringProperty");
    return real ? real(lipc, service, prop, value) : 1;
}

/* The browser's own events (page loaded, title changed...) are for Amazon's UI. */
int LipcSendEvent(void *lipc, void *event) {
    static send_event_fn real;
    if (getenv("KO_QUIET_LIPC")) return 0;
    if (!real) real = (send_event_fn)dlsym(RTLD_NEXT, "LipcSendEvent");
    return real ? real(lipc, event) : 1;
}
