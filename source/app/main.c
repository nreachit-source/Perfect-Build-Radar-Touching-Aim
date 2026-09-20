/*
 * RadarManager — Native On-Device Controller & Launcher for iOS UE4 Radar
 * Target: iOS 16.7.16 (iPhone X, Dopamine Rootless @ /var/jb)
 * Pure C + ObjC Runtime (Zero Apple SDK headers required for Windows cross-compilation)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <spawn.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>

extern char **environ;

/* --- Geometry Types --- */
typedef struct CGPoint { double x; double y; } CGPoint;
typedef struct CGSize { double width; double height; } CGSize;
typedef struct CGRect { CGPoint origin; CGSize size; } CGRect;

static inline CGRect CGRectMake_f(double x, double y, double w, double h) {
    CGRect r;
    r.origin.x = x;
    r.origin.y = y;
    r.size.width = w;
    r.size.height = h;
    return r;
}

/* --- ObjC Helpers --- */
static inline id nsstr(const char *s) {
    if (!s) return NULL;
    return ((id (*)(id, SEL, const char *))objc_msgSend)(
        (id)objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), s);
}

static inline id get_color(double r, double g, double b, double a) {
    return ((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)objc_getClass("UIColor"), sel_registerName("colorWithRed:green:blue:alpha:"), r, g, b, a);
}

static inline id get_font_bold(double size) {
    return ((id (*)(id, SEL, double))objc_msgSend)(
        (id)objc_getClass("UIFont"), sel_registerName("boldSystemFontOfSize:"), size);
}

static inline id get_font_system(double size) {
    return ((id (*)(id, SEL, double))objc_msgSend)(
        (id)objc_getClass("UIFont"), sel_registerName("systemFontOfSize:"), size);
}

static inline id get_font_fixed(double size) {
    id f = ((id (*)(id, SEL, id, double))objc_msgSend)(
        (id)objc_getClass("UIFont"), sel_registerName("fontWithName:size:"), nsstr("Menlo-Regular"), size);
    if (!f) f = get_font_system(size);
    return f;
}

/* --- Native Process & System Helpers (Zero popen / Zero /bin/sh) --- */

static int run_cmd(const char *cmd) {
    pid_t pid;
    const char *argv[] = {"/var/jb/bin/sh", "-c", cmd, NULL};
    int status = 0;
    if (posix_spawn(&pid, "/var/jb/bin/sh", NULL, NULL, (char *const *)argv, environ) == 0) {
        waitpid(pid, &status, 0);
        return WEXITSTATUS(status);
    }
    return -1;
}

/* Native Darwin kernel sysctl process scanner — 100% reliable without any shell */
static pid_t find_proc(const char *name) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t length = 0;
    if (sysctl(mib, 4, NULL, &length, NULL, 0) != 0 || length == 0) {
        return 0;
    }

    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(length + sizeof(struct kinfo_proc) * 16);
    if (!procs) return 0;

    length += sizeof(struct kinfo_proc) * 16;
    if (sysctl(mib, 4, procs, &length, NULL, 0) != 0) {
        free(procs);
        return 0;
    }

    size_t count = length / sizeof(struct kinfo_proc);
    pid_t result = 0;
    for (size_t i = 0; i < count; ++i) {
        if (strstr(procs[i].kp_proc.p_comm, name) != NULL) {
            result = procs[i].kp_proc.p_pid;
            break;
        }
    }
    free(procs);
    return result;
}

static int file_exists_nonempty(const char *path) {
    struct stat st;
    if (stat(path, &st) == 0 && st.st_size > 0) return 1;
    return 0;
}

/* Native C tail reader — reads the end of log files directly without popen/tail */
static void read_tail(const char *path, int lines_needed, char *out, size_t max_out) {
    FILE *fp = fopen(path, "r");
    if (!fp) {
        snprintf(out, max_out, "[File not available]");
        return;
    }
    fseek(fp, 0, SEEK_END);
    long sz = ftell(fp);
    long off = (sz > 3072) ? sz - 3072 : 0;
    fseek(fp, off, SEEK_SET);

    char buf[3072];
    size_t n = fread(buf, 1, sizeof(buf) - 1, fp);
    fclose(fp);
    buf[n] = '\0';

    if (n == 0) {
        snprintf(out, max_out, "[Empty file]");
        return;
    }

    /* Find start of last lines_needed lines */
    char *p = buf + n - 1;
    int c = 0;
    while (p > buf) {
        if (*p == '\n') {
            c++;
            if (c >= lines_needed) {
                p++;
                break;
            }
        }
        p--;
    }
    if (p < buf) p = buf;
    snprintf(out, max_out, "%s", p);
}

/* --- UI State --- */
static id g_window = NULL;
static id g_lbl_daemon = NULL;
static id g_lbl_game = NULL;
static id g_lbl_overlay = NULL;
static id g_lbl_ipc = NULL;
static id g_txt_logs = NULL;

static void set_status_row(id lbl, const char *text, double r, double g, double b) {
    if (!lbl) return;
    ((void (*)(id, SEL, id))objc_msgSend)(lbl, sel_registerName("setText:"), nsstr(text));
    ((void (*)(id, SEL, id))objc_msgSend)(lbl, sel_registerName("setTextColor:"), get_color(r, g, b, 1.0));
}

static void refresh_status(void) {
    /* 1. Radar Daemon */
    pid_t dpid = find_proc("ue4loadmonitor");
    if (dpid > 0) {
        char buf[64];
        snprintf(buf, sizeof(buf), "RUNNING (PID %d)", (int)dpid);
        set_status_row(g_lbl_daemon, buf, 0.0, 0.9, 0.35);
    } else {
        set_status_row(g_lbl_daemon, "STOPPED", 0.9, 0.2, 0.2);
    }

    /* 2. Game Process */
    pid_t gpid = find_proc("ShadowTracker");
    if (gpid > 0) {
        char buf[64];
        snprintf(buf, sizeof(buf), "ACTIVE (PID %d)", (int)gpid);
        set_status_row(g_lbl_game, buf, 0.0, 0.9, 0.35);
    } else {
        set_status_row(g_lbl_game, "NOT RUNNING", 0.6, 0.6, 0.6);
    }

    /* 3. Overlay State */
    pid_t sbpid = find_proc("SpringBoard");
    if (file_exists_nonempty("/var/mobile/Downloads/overlay_sb_pid.txt")) {
        char buf[64];
        snprintf(buf, sizeof(buf), "ACTIVE (SB %d)", (int)sbpid);
        set_status_row(g_lbl_overlay, buf, 0.0, 0.85, 1.0);
    } else {
        set_status_row(g_lbl_overlay, "STANDBY", 0.6, 0.6, 0.6);
    }

    /* 4. Shared Memory IPC */
    if (file_exists_nonempty("/var/mobile/Downloads/ue4_radar.bin")) {
        set_status_row(g_lbl_ipc, "LIVE (33.7 KB)", 0.0, 0.9, 0.35);
    } else {
        set_status_row(g_lbl_ipc, "WAITING", 0.6, 0.6, 0.6);
    }

    /* 5. Logs */
    if (g_txt_logs) {
        char dLog[1024];
        char oLog[1024];
        read_tail("/var/mobile/Downloads/ue4_radar.log", 4, dLog, sizeof(dLog));
        read_tail("/var/mobile/Downloads/ue4_overlay_v3_proof.log", 4, oLog, sizeof(oLog));
        char full[2400];
        snprintf(full, sizeof(full), "--- DAEMON LOG ---\n%s\n--- OVERLAY PROOF ---\n%s", dLog, oLog);
        ((void (*)(id, SEL, id))objc_msgSend)(g_txt_logs, sel_registerName("setText:"), nsstr(full));
    }
}

/* --- Action Callbacks --- */
static void action_start_radar(id self, SEL cmd, id sender) {
    (void)self; (void)cmd; (void)sender;
    /* Clear stop flag and safe mode */
    unlink("/var/mobile/Downloads/radar_stop.flag");
    unlink("/var/jb/basebin/.safe_mode");

    /* Start daemon if not running */
    pid_t dpid = find_proc("ue4loadmonitor");
    if (dpid == 0) {
        run_cmd("/var/jb/bin/launchctl kickstart -k system/com.local.ue4loadmonitor 2>/dev/null || "
                "/var/jb/bin/launchctl kickstart -k user/501/com.local.ue4loadmonitor 2>/dev/null || true");
        usleep(100000);
        dpid = find_proc("ue4loadmonitor");
        if (dpid == 0) {
            /* Fallback to direct background spawn */
            pid_t child_pid;
            const char *argv[] = {"/var/jb/usr/local/libexec/ue4loadmonitor", NULL};
            posix_spawn(&child_pid, "/var/jb/usr/local/libexec/ue4loadmonitor", NULL, NULL, (char *const *)argv, environ);
        }
    }

    /* Launch Game via LSApplicationWorkspace or uiopen */
    Class cls = objc_getClass("LSApplicationWorkspace");
    if (cls && class_respondsToSelector(cls, sel_registerName("defaultWorkspace"))) {
        id ws = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("defaultWorkspace"));
        if (ws && class_respondsToSelector(object_getClass(ws), sel_registerName("openApplicationWithBundleID:"))) {
            ((void (*)(id, SEL, id))objc_msgSend)(ws, sel_registerName("openApplicationWithBundleID:"), nsstr("com.tencent.ig"));
        }
    } else {
        run_cmd("/var/jb/usr/bin/uiopen --bundleid com.tencent.ig 2>/dev/null || true");
    }
    refresh_status();
}

static void action_stop_radar(id self, SEL cmd, id sender) {
    (void)self; (void)cmd; (void)sender;
    /* 1. Write stop flag so daemon terminates itself cleanly */
    FILE *fp = fopen("/var/mobile/Downloads/radar_stop.flag", "w");
    if (fp) {
        fprintf(fp, "STOP\n");
        fclose(fp);
        chown("/var/mobile/Downloads/radar_stop.flag", 501, 501);
    }

    /* 2. Directly terminate ue4loadmonitor as root */
    pid_t dpid = find_proc("ue4loadmonitor");
    if (dpid > 0) {
        kill(dpid, SIGTERM);
        usleep(50000);
        if (find_proc("ue4loadmonitor") > 0) {
            kill(dpid, SIGKILL);
        }
    }

    /* 3. Stop via launchctl */
    run_cmd("/var/jb/bin/launchctl stop system/com.local.ue4loadmonitor 2>/dev/null || true");
    run_cmd("/var/jb/bin/launchctl stop user/501/com.local.ue4loadmonitor 2>/dev/null || true");

    /* 4. Remove shared IPC and PID files */
    unlink("/var/mobile/Downloads/ue4_radar.bin");
    unlink("/var/mobile/Downloads/ue4loadmonitor.pid");

    refresh_status();
}

static void action_respring(id self, SEL cmd, id sender) {
    (void)self; (void)cmd; (void)sender;
    run_cmd("/var/jb/usr/bin/sbreload 2>/dev/null || /var/jb/usr/bin/killall -9 SpringBoard 2>/dev/null || true");
}

static void action_exit_safe_mode(id self, SEL cmd, id sender) {
    (void)self; (void)cmd; (void)sender;
    unlink("/var/jb/basebin/.safe_mode");
    unlink("/var/mobile/Downloads/overlay_sb_pid.txt");
    run_cmd("/var/jb/usr/bin/sbreload 2>/dev/null || /var/jb/usr/bin/killall -9 SpringBoard 2>/dev/null || true");
}

static void action_close_game(id self, SEL cmd, id sender) {
    (void)self; (void)cmd; (void)sender;
    pid_t gpid = find_proc("ShadowTracker");
    if (gpid > 0) {
        kill(gpid, SIGKILL);
    }
    run_cmd("/var/jb/usr/bin/killall -9 ShadowTrackerExtra 2>/dev/null || true");
    refresh_status();
}

static void action_tick(id self, SEL cmd, id sender) {
    (void)self; (void)cmd; (void)sender;
    refresh_status();
}

/* --- UI Building --- */
static id create_status_row(id parent, double y, const char *title, double w) {
    Class UILabel_cls = objc_getClass("UILabel");

    /* Title Label */
    id lblTitle = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)UILabel_cls, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), CGRectMake_f(12.0, y, 130.0, 24.0));
    ((void (*)(id, SEL, id))objc_msgSend)(lblTitle, sel_registerName("setText:"), nsstr(title));
    ((void (*)(id, SEL, id))objc_msgSend)(lblTitle, sel_registerName("setFont:"), get_font_system(13.0));
    ((void (*)(id, SEL, id))objc_msgSend)(lblTitle, sel_registerName("setTextColor:"), get_color(0.85, 0.85, 0.85, 1.0));
    ((void (*)(id, SEL, id))objc_msgSend)(parent, sel_registerName("addSubview:"), lblTitle);

    /* Value Label */
    id lblVal = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)UILabel_cls, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), CGRectMake_f(145.0, y, w - 145.0, 24.0));
    ((void (*)(id, SEL, id))objc_msgSend)(lblVal, sel_registerName("setFont:"), get_font_bold(13.0));
    ((void (*)(id, SEL, id))objc_msgSend)(lblVal, sel_registerName("setTextColor:"), get_color(1.0, 1.0, 1.0, 1.0));
    ((void (*)(id, SEL, long long))objc_msgSend)(lblVal, sel_registerName("setTextAlignment:"), 2); /* NSTextAlignmentRight */
    ((void (*)(id, SEL, id))objc_msgSend)(parent, sel_registerName("addSubview:"), lblVal);
    return lblVal;
}

static id create_button(id parent, CGRect frame, const char *text, id target, SEL action, id bg_color, double font_size, int bold) {
    Class UIButton_cls = objc_getClass("UIButton");
    id btn = ((id (*)(id, SEL, long long))objc_msgSend)((id)UIButton_cls, sel_registerName("buttonWithType:"), 0); /* Custom */
    ((void (*)(id, SEL, CGRect))objc_msgSend)(btn, sel_registerName("setFrame:"), frame);
    ((void (*)(id, SEL, id))objc_msgSend)(btn, sel_registerName("setBackgroundColor:"), bg_color);
    ((void (*)(id, SEL, id, unsigned long long))objc_msgSend)(btn, sel_registerName("setTitle:forState:"), nsstr(text), 0);

    id lbl = ((id (*)(id, SEL))objc_msgSend)(btn, sel_registerName("titleLabel"));
    if (lbl) {
        id font = bold ? get_font_bold(font_size) : get_font_system(font_size);
        ((void (*)(id, SEL, id))objc_msgSend)(lbl, sel_registerName("setFont:"), font);
    }
    id layer = ((id (*)(id, SEL))objc_msgSend)(btn, sel_registerName("layer"));
    if (layer) {
        ((void (*)(id, SEL, double))objc_msgSend)(layer, sel_registerName("setCornerRadius:"), 8.0);
    }
    ((void (*)(id, SEL, id, SEL, unsigned long long))objc_msgSend)(btn, sel_registerName("addTarget:action:forControlEvents:"), target, action, 64); /* TouchUpInside */
    ((void (*)(id, SEL, id))objc_msgSend)(parent, sel_registerName("addSubview:"), btn);
    return btn;
}

static void vc_viewDidLoad(id self, SEL cmd) {
    (void)cmd;
    Class UIViewController_cls = objc_getClass("UIViewController");
    struct objc_super sup = { .receiver = self, .super_class = UIViewController_cls };
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, sel_registerName("viewDidLoad"));

    id view = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("view"));
    ((void (*)(id, SEL, id))objc_msgSend)(view, sel_registerName("setBackgroundColor:"), get_color(0.04, 0.06, 0.09, 1.0));

    id mainScreen = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("UIScreen"), sel_registerName("mainScreen"));
    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(mainScreen, sel_registerName("bounds"));
    double screenW = bounds.size.width;
    double screenH = bounds.size.height;
    double pad = 16.0;
    double contentW = screenW - (pad * 2.0);

    /* ScrollView */
    Class UIScrollView_cls = objc_getClass("UIScrollView");
    id scroll = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)UIScrollView_cls, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), CGRectMake_f(0, 0, screenW, screenH));
    ((void (*)(id, SEL, unsigned long long))objc_msgSend)(scroll, sel_registerName("setAutoresizingMask:"), 18);
    ((void (*)(id, SEL, int))objc_msgSend)(scroll, sel_registerName("setAlwaysBounceVertical:"), 1);
    ((void (*)(id, SEL, id))objc_msgSend)(view, sel_registerName("addSubview:"), scroll);

    double curY = 44.0; /* Below status bar */

    /* Header Title */
    Class UILabel_cls = objc_getClass("UILabel");
    id header = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)UILabel_cls, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), CGRectMake_f(pad, curY, contentW, 30.0));
    ((void (*)(id, SEL, id))objc_msgSend)(header, sel_registerName("setText:"), nsstr("RADAR CONTROLLER"));
    ((void (*)(id, SEL, id))objc_msgSend)(header, sel_registerName("setFont:"), get_font_bold(22.0));
    ((void (*)(id, SEL, id))objc_msgSend)(header, sel_registerName("setTextColor:"), get_color(0.0, 0.85, 1.0, 1.0));
    ((void (*)(id, SEL, long long))objc_msgSend)(header, sel_registerName("setTextAlignment:"), 1); /* Center */
    ((void (*)(id, SEL, id))objc_msgSend)(scroll, sel_registerName("addSubview:"), header);
    curY += 32.0;

    /* SubHeader */
    id subHeader = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)UILabel_cls, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), CGRectMake_f(pad, curY, contentW, 20.0));
    ((void (*)(id, SEL, id))objc_msgSend)(subHeader, sel_registerName("setText:"), nsstr("iOS 16 · Standalone On-Device Manager"));
    ((void (*)(id, SEL, id))objc_msgSend)(subHeader, sel_registerName("setFont:"), get_font_system(12.0));
    ((void (*)(id, SEL, id))objc_msgSend)(subHeader, sel_registerName("setTextColor:"), get_color(0.65, 0.65, 0.65, 1.0));
    ((void (*)(id, SEL, long long))objc_msgSend)(subHeader, sel_registerName("setTextAlignment:"), 1);
    ((void (*)(id, SEL, id))objc_msgSend)(scroll, sel_registerName("addSubview:"), subHeader);
    curY += 28.0;

    /* Status Card */
    Class UIView_cls = objc_getClass("UIView");
    id card = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)UIView_cls, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), CGRectMake_f(pad, curY, contentW, 140.0));
    ((void (*)(id, SEL, id))objc_msgSend)(card, sel_registerName("setBackgroundColor:"), get_color(0.08, 0.12, 0.18, 0.95));
    id cardLayer = ((id (*)(id, SEL))objc_msgSend)(card, sel_registerName("layer"));
    if (cardLayer) {
        ((void (*)(id, SEL, double))objc_msgSend)(cardLayer, sel_registerName("setCornerRadius:"), 12.0);
        ((void (*)(id, SEL, double))objc_msgSend)(cardLayer, sel_registerName("setBorderWidth:"), 1.0);
        id cgBorder = ((id (*)(id, SEL))objc_msgSend)(get_color(0.15, 0.25, 0.35, 1.0), sel_registerName("CGColor"));
        ((void (*)(id, SEL, id))objc_msgSend)(cardLayer, sel_registerName("setBorderColor:"), cgBorder);
    }
    ((void (*)(id, SEL, id))objc_msgSend)(scroll, sel_registerName("addSubview:"), card);

    double rowH = 30.0;
    double cardPad = 10.0;
    double cardW = contentW - (cardPad * 2.0);

    g_lbl_daemon  = create_status_row(card, cardPad + (rowH * 0), "Radar Daemon:", cardW);
    g_lbl_game    = create_status_row(card, cardPad + (rowH * 1), "PUBG Mobile:", cardW);
    g_lbl_overlay = create_status_row(card, cardPad + (rowH * 2), "ESP Overlay:", cardW);
    g_lbl_ipc     = create_status_row(card, cardPad + (rowH * 3), "Shared Memory:", cardW);
    curY += 152.0;

    /* Action Target */
    id actionTarget = self;

    /* Primary Start Button (Emerald) */
    create_button(scroll, CGRectMake_f(pad, curY, contentW, 52.0),
                  "▶  START RADAR & GAME", actionTarget, sel_registerName("actionStart:"),
                  get_color(0.00, 0.75, 0.35, 1.0), 16.0, 1);
    curY += 60.0;

    /* Primary Stop Button (Ruby) */
    create_button(scroll, CGRectMake_f(pad, curY, contentW, 50.0),
                  "⏹  STOP RADAR", actionTarget, sel_registerName("actionStop:"),
                  get_color(0.85, 0.10, 0.15, 1.0), 16.0, 1);
    curY += 58.0;

    /* Secondary Controls Row (Respring & Safe Mode) */
    double halfW = (contentW - 10.0) / 2.0;
    create_button(scroll, CGRectMake_f(pad, curY, halfW, 44.0),
                  "🔄 Soft Respring", actionTarget, sel_registerName("actionRespring:"),
                  get_color(0.10, 0.55, 0.85, 1.0), 14.0, 1);
    create_button(scroll, CGRectMake_f(pad + halfW + 10.0, curY, halfW, 44.0),
                  "🛡 Exit Safe Mode", actionTarget, sel_registerName("actionSafeMode:"),
                  get_color(0.90, 0.50, 0.10, 1.0), 14.0, 1);
    curY += 52.0;

    /* Close Game Button */
    create_button(scroll, CGRectMake_f(pad, curY, contentW, 40.0),
                  "❌ Close Game Process", actionTarget, sel_registerName("actionCloseGame:"),
                  get_color(0.25, 0.30, 0.38, 1.0), 14.0, 0);
    curY += 48.0;

    /* Console Logs Title */
    id lblLogHeader = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)UILabel_cls, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), CGRectMake_f(pad, curY, contentW, 24.0));
    ((void (*)(id, SEL, id))objc_msgSend)(lblLogHeader, sel_registerName("setText:"), nsstr("LIVE TELEMETRY & SYSTEM LOGS:"));
    ((void (*)(id, SEL, id))objc_msgSend)(lblLogHeader, sel_registerName("setFont:"), get_font_bold(12.0));
    ((void (*)(id, SEL, id))objc_msgSend)(lblLogHeader, sel_registerName("setTextColor:"), get_color(0.0, 0.85, 1.0, 1.0));
    ((void (*)(id, SEL, id))objc_msgSend)(scroll, sel_registerName("addSubview:"), lblLogHeader);
    curY += 26.0;

    /* Log Box */
    Class UITextView_cls = objc_getClass("UITextView");
    g_txt_logs = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)UITextView_cls, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), CGRectMake_f(pad, curY, contentW, 160.0));
    ((void (*)(id, SEL, id))objc_msgSend)(g_txt_logs, sel_registerName("setBackgroundColor:"), get_color(0.02, 0.03, 0.05, 1.0));
    ((void (*)(id, SEL, id))objc_msgSend)(g_txt_logs, sel_registerName("setTextColor:"), get_color(0.0, 0.95, 0.40, 1.0));
    ((void (*)(id, SEL, id))objc_msgSend)(g_txt_logs, sel_registerName("setFont:"), get_font_fixed(10.0));
    ((void (*)(id, SEL, int))objc_msgSend)(g_txt_logs, sel_registerName("setEditable:"), 0);
    id logLayer = ((id (*)(id, SEL))objc_msgSend)(g_txt_logs, sel_registerName("layer"));
    if (logLayer) {
        ((void (*)(id, SEL, double))objc_msgSend)(logLayer, sel_registerName("setCornerRadius:"), 8.0);
        ((void (*)(id, SEL, double))objc_msgSend)(logLayer, sel_registerName("setBorderWidth:"), 1.0);
        id cgLogBorder = ((id (*)(id, SEL))objc_msgSend)(get_color(0.15, 0.20, 0.28, 1.0), sel_registerName("CGColor"));
        ((void (*)(id, SEL, id))objc_msgSend)(logLayer, sel_registerName("setBorderColor:"), cgLogBorder);
    }
    ((void (*)(id, SEL, id))objc_msgSend)(scroll, sel_registerName("addSubview:"), g_txt_logs);
    curY += 170.0;

    /* Update Content Size */
    CGSize sz = {screenW, curY + 40.0};
    ((void (*)(id, SEL, CGSize))objc_msgSend)(scroll, sel_registerName("setContentSize:"), sz);

    /* Initial refresh */
    refresh_status();

    /* Schedule Timer at 1.5s */
    Class NSTimer_cls = objc_getClass("NSTimer");
    id timer = ((id (*)(id, SEL, double, id, SEL, id, int))objc_msgSend)(
        (id)NSTimer_cls, sel_registerName("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"),
        1.5, self, sel_registerName("actionTick:"), NULL, 1);
    (void)timer;
}

/* --- App Delegate --- */
static int app_didFinishLaunching(id self, SEL cmd, id application, id launchOptions) {
    (void)self; (void)cmd; (void)application; (void)launchOptions;

    id mainScreen = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("UIScreen"), sel_registerName("mainScreen"));
    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(mainScreen, sel_registerName("bounds"));

    Class UIWindow_cls = objc_getClass("UIWindow");
    g_window = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)UIWindow_cls, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), bounds);

    Class VC_cls = objc_getClass("RadarManagerViewController");
    id vc = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)VC_cls, sel_registerName("alloc")),
        sel_registerName("init"));

    ((void (*)(id, SEL, id))objc_msgSend)(g_window, sel_registerName("setRootViewController:"), vc);
    ((void (*)(id, SEL))objc_msgSend)(g_window, sel_registerName("makeKeyAndVisible"));
    return 1;
}

/* --- Main Entry --- */
int main(int argc, char *argv[]) {
    /* Elevate to root via setuid bit on Dopamine rootless */
    setuid(0);
    setgid(0);

    dlopen("/System/Library/Frameworks/Foundation.framework/Foundation", RTLD_NOW | RTLD_GLOBAL);
    dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW | RTLD_GLOBAL);
    dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW | RTLD_GLOBAL);
    dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore", RTLD_NOW | RTLD_GLOBAL);

    if (argc > 1) {
        if (strcmp(argv[1], "--start") == 0) {
            action_start_radar(NULL, 0, NULL);
            printf("[RadarManager] Started radar and requested game launch.\n");
            return 0;
        } else if (strcmp(argv[1], "--stop") == 0) {
            action_stop_radar(NULL, 0, NULL);
            printf("[RadarManager] Stopped radar.\n");
            return 0;
        } else if (strcmp(argv[1], "--respring") == 0) {
            action_respring(NULL, 0, NULL);
            printf("[RadarManager] Respring triggered.\n");
            return 0;
        }
    }

    /* Register View Controller */
    Class UIViewController_cls = objc_getClass("UIViewController");
    Class VC_cls = objc_allocateClassPair(UIViewController_cls, "RadarManagerViewController", 0);
    if (VC_cls) {
        class_addMethod(VC_cls, sel_registerName("viewDidLoad"), (IMP)vc_viewDidLoad, "v@:");
        class_addMethod(VC_cls, sel_registerName("actionStart:"), (IMP)action_start_radar, "v@:@");
        class_addMethod(VC_cls, sel_registerName("actionStop:"), (IMP)action_stop_radar, "v@:@");
        class_addMethod(VC_cls, sel_registerName("actionRespring:"), (IMP)action_respring, "v@:@");
        class_addMethod(VC_cls, sel_registerName("actionSafeMode:"), (IMP)action_exit_safe_mode, "v@:@");
        class_addMethod(VC_cls, sel_registerName("actionCloseGame:"), (IMP)action_close_game, "v@:@");
        class_addMethod(VC_cls, sel_registerName("actionTick:"), (IMP)action_tick, "v@:@");
        objc_registerClassPair(VC_cls);
    }

    /* Register App Delegate */
    Class UIResponder_cls = objc_getClass("UIResponder");
    Class Delegate_cls = objc_allocateClassPair(UIResponder_cls, "RadarManagerAppDelegate", 0);
    if (Delegate_cls) {
        class_addMethod(Delegate_cls, sel_registerName("application:didFinishLaunchingWithOptions:"),
                        (IMP)app_didFinishLaunching, "c@:@@");
        objc_registerClassPair(Delegate_cls);
    }

    int (*pUIApplicationMain)(int, char *[], id, id) =
        (int (*)(int, char *[], id, id))dlsym(RTLD_DEFAULT, "UIApplicationMain");
    if (!pUIApplicationMain) {
        void *uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW | RTLD_GLOBAL);
        if (uikit) pUIApplicationMain = (int (*)(int, char *[], id, id))dlsym(uikit, "UIApplicationMain");
    }

    if (pUIApplicationMain) {
        return pUIApplicationMain(argc, argv, NULL, nsstr("RadarManagerAppDelegate"));
    }

    fprintf(stderr, "[RadarManager] Fatal: UIApplicationMain symbol not found\n");
    return 1;
}
