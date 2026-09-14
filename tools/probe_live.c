#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include "../source/daemon/remote_memory.h"
#include "../source/daemon/aslr_slide.h"
#include "../source/daemon/ue4_reflection.h"
#include "../source/daemon/ue4_offsets.h"
#include "../source/daemon/config_address.h"
#include "../source/daemon/radar_data.h"

static pid_t find_game(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return 0;
    struct kinfo_proc *procs = malloc(len + sizeof(struct kinfo_proc) * 16);
    if (!procs) return 0;
    len += sizeof(struct kinfo_proc) * 16;
    if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) { free(procs); return 0; }
    size_t count = len / sizeof(struct kinfo_proc);
    pid_t pid = 0;
    for (size_t i = 0; i < count; i++) {
        if (!strncmp(procs[i].kp_proc.p_comm, "ShadowTrackerExt", 15)) {
            pid = procs[i].kp_proc.p_pid;
            break;
        }
    }
    free(procs);
    return pid;
}

static uint64_t ptr(mach_port_t t, uint64_t obj, uint64_t off) {
    if (!rm_validate_ptr(obj)) return 0;
    return rm_read_ptr(t, obj + off);
}

int main(void) {
    pid_t pid = find_game();
    printf("Game PID: %d\n", pid);
    if (pid <= 0) return 1;

    mach_port_t task = rm_task_acquire(pid);
    if (task == MACH_PORT_NULL) { printf("Failed to acquire task\n"); return 1; }

    aslr_result_t aslr = aslr_get_slide(task);
    printf("ASLR: base=0x%llx slide=0x%llx found=%d\n", aslr.base, aslr.slide, aslr.found);

    FILE *f = fopen("/var/mobile/Downloads/ue4_sdk_config.txt", "r");
    uint64_t guobj = 0, gnames = 0;
    if (f) {
        char line[256], key[128];
        unsigned long long val;
        while (fgets(line, sizeof(line), f)) {
            if (sscanf(line, " %127[^=]=%llx", key, &val) == 2) {
                if (!strcmp(key, "guobjectarray")) guobj = val;
                if (!strcmp(key, "gnamepool")) gnames = val;
            }
        }
        fclose(f);
    }
    printf("Config: guobj=0x%llx gnames=0x%llx\n", guobj, gnames);

    ue4r_ctx_t *ref = ue4r_init(task, aslr.base, aslr.slide, guobj, gnames);
    if (!ref || !ue4r_ready(ref)) { printf("Reflection not ready\n"); return 1; }

    int32_t cursor = 0;
    uint64_t lp = 0;
    while (lp == 0 && cursor >= 0) {
        lp = ue4r_find_instance(ref, "LocalPlayer", &cursor);
    }
    printf("LocalPlayer: 0x%llx (cursor=%d)\n", lp, cursor);
    if (!lp) return 1;

    uint64_t pc = ptr(task, lp, 0x30);
    printf("PlayerController: 0x%llx\n", pc);
    if (pc) {
        uint64_t pawn = ptr(task, pc, 0x528);
        uint64_t camera = ptr(task, pc, 0x548);
        printf("  Pawn: 0x%llx  CameraManager: 0x%llx\n", pawn, camera);
        if (camera) {
            uint64_t cam_cls = ptr(task, camera, 0x10);
            char cam_cls_name[128] = {0};
            if (cam_cls) ue4r_resolve_name(ref, cam_cls + OFF_UOBJECT_NAME, cam_cls_name, sizeof(cam_cls_name));
            printf("  CameraManager cls: '%s'\n", cam_cls_name);

            rvec3_t cpos = {0}, crot = {0};
            rm_read(task, camera + 0x530, &cpos, sizeof(cpos));
            rm_read(task, camera + 0x548, &crot, sizeof(crot));
            float fov = 0;
            rm_read(task, camera + 0x554, &fov, 4);
            printf("  Camera: pos=(%.1f, %.1f, %.1f) rot=(pitch=%.1f, yaw=%.1f, roll=%.1f) fov=%.1f\n",
                   cpos.x, cpos.y, cpos.z, crot.x, crot.y, crot.z, fov);
        }
    }

    uint64_t vp = ptr(task, lp, 0x58);
    uint64_t world = ptr(task, vp, 0x78);
    printf("Viewport: 0x%llx World: 0x%llx\n", vp, world);
    if (!world) return 1;

    uint64_t level = ptr(task, world, 0x30);
    printf("PersistentLevel: 0x%llx\n", level);
    if (level) {
        /* Probe Level memory for TArrays */
        for (uint64_t off = 0x20; off < 0x200; off += 8) {
            struct { uint64_t data; int32_t count, max; } arr;
            if (rm_read(task, level + off, &arr, sizeof(arr))) {
                if (arr.count > 0 && arr.count <= 20000 && arr.max >= arr.count && rm_validate_ptr(arr.data)) {
                    printf("Level+0x%llx: TArray data=0x%llx count=%d max=%d\n", off, arr.data, arr.count, arr.max);
    for (int e = 0; e < arr.count && e < 15; e++) {
        uint64_t elem = rm_read_ptr(task, arr.data + e * 8);
        if (!elem) continue;
        uint64_t cls = ptr(task, elem, 0x10);
        char cls_name[128] = {0};
        if (cls) ue4r_resolve_name(ref, cls + OFF_UOBJECT_NAME, cls_name, sizeof(cls_name));
        printf("  elem[%d]=0x%llx cls='%s'\n", e, elem, cls_name);
    }
                }
            }
        }
    }

    ue4r_destroy(ref);
    rm_task_release(task);
    return 0;
}
