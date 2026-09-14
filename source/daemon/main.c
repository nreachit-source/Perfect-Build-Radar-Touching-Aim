#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>

#include "ue4_sdk.h"
#include "radar_reader.h"
#include "remote_memory.h"
#include "aslr_slide.h"

static const char kTargetExecutable[] = "ShadowTrackerExtra";
static const char kDownloadsDirectory[] = "/var/mobile/Downloads";
static const char kMarkerPath[] =
    "/var/mobile/Downloads/I_have_loaded.txt";
static const char kMarkerText[] = "I have loaded. I am running.\n";

static volatile sig_atomic_t gRunning = 1;
static void *g_daemon_txn = NULL;

static void hold_daemon_transaction(void) {
    typedef void *(*txn_create_fn)(const char *);
    txn_create_fn create_fn = (txn_create_fn)dlsym(RTLD_DEFAULT, "os_transaction_create");
    if (create_fn) {
        g_daemon_txn = create_fn("com.local.ue4loadmonitor");
    }
}

static void raise_jetsam_limit(void) {
    typedef int (*memo_ctrl_fn)(uint32_t, int32_t, uint32_t, void *, size_t);
    memo_ctrl_fn fn = (memo_ctrl_fn)dlsym(RTLD_DEFAULT, "memorystatus_control");
    if (fn) {
        /* MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK = 4, set to 128 MB */
        fn(4, getpid(), 128, NULL, 0);
    }
}

static void stop_handler(int signal_number) {
    (void)signal_number;
    gRunning = 0;
}

static pid_t find_target_process(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t length = 0;
    if (sysctl(mib, 4, NULL, &length, NULL, 0) != 0 || length == 0) {
        return 0;
    }

    struct kinfo_proc* processes =
        (struct kinfo_proc*)malloc(length + sizeof(struct kinfo_proc) * 16);
    if (processes == NULL) return 0;

    length += sizeof(struct kinfo_proc) * 16;
    if (sysctl(mib, 4, processes, &length, NULL, 0) != 0) {
        free(processes);
        return 0;
    }

    const size_t count = length / sizeof(struct kinfo_proc);
    pid_t result = 0;
    for (size_t index = 0; index < count; ++index) {
        if (strncmp(processes[index].kp_proc.p_comm,
                    kTargetExecutable, MAXCOMLEN) == 0) {
            result = processes[index].kp_proc.p_pid;
            break;
        }
    }
    free(processes);
    return result;
}

static int write_all(int fd, const char* data, size_t size) {
    size_t offset = 0;
    while (offset < size) {
        const ssize_t written = write(fd, data + offset, size - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return -1;
        offset += (size_t)written;
    }
    return 0;
}

static int write_marker(void) {
    if (mkdir(kDownloadsDirectory, 0755) != 0 && errno != EEXIST) return -1;

    const int fd = open(kMarkerPath,
                        O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                        0644);
    if (fd < 0) return -1;

    const int result = write_all(fd, kMarkerText, sizeof(kMarkerText) - 1);
    if (result == 0) fsync(fd);
    close(fd);
    if (result != 0) return -1;

    chown(kMarkerPath, 501, 501);
    return 0;
}

/* Run continuous radar reading loop at ~20Hz until process exits. */
static void run_radar_loop(pid_t target_pid) {
    mach_port_t task = rm_task_acquire(target_pid);
    if (task == MACH_PORT_NULL) return;

    aslr_result_t aslr = aslr_get_slide(task);
    if (!aslr.found) {
        rm_task_release(task);
        return;
    }

    if (radar_init(task, aslr.base, aslr.slide) != 0) {
        rm_task_release(task);
        return;
    }

    while (gRunning) {
        /* Check if target process is still alive */
        pid_t cur = find_target_process();
        if (cur != target_pid) break;

        radar_tick();
        usleep(50000);  /* 50ms = 20 Hz */
    }

    radar_destroy();
    rm_task_release(task);
}

int main(int argc, char **argv) {
    signal(SIGTERM, stop_handler);
    signal(SIGINT, stop_handler);

    hold_daemon_transaction();
    raise_jetsam_limit();

    if (argc == 3 && strcmp(argv[1], "--dump-once") == 0) {
        pid_t pid = (pid_t)atoi(argv[2]);
        return pid > 0 && ue4_sdk_generate(pid) == 0 ? 0 : 1;
    }

    if (argc > 1) {
        pid_t direct_pid = (pid_t)atoi(argv[1]);
        if (direct_pid > 0) {
            write_marker();
            /* Live mode uses the existing schema/offsets; never dumps. */
            run_radar_loop(direct_pid);
            return 0;
        }
    }

    pid_t last_reported_pid = 0;
    while (gRunning != 0) {
        const pid_t pid = find_target_process();
        if (pid != 0 && pid != last_reported_pid) {
            if (write_marker() == 0) {
                last_reported_pid = pid;
                /* Start radar loop — blocks until game exits */
                run_radar_loop(pid);
                last_reported_pid = 0;
            }
        } else if (pid == 0) {
            last_reported_pid = 0;
        }
        usleep(250000); /* Detect launch/recover task acquisition within 250ms. */
    }
    return 0;
}
