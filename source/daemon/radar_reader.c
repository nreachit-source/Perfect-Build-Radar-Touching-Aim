/*
 * radar_reader.c — Reads live player data from the game process.
 *
 * Traverses: GWorld -> GameInstance -> LocalPlayers[0] -> PlayerController
 *            GWorld -> GameState -> PlayerArray -> each player
 *
 * Writes results to a memory-mapped shared file for the overlay.
 * All reads are strictly read-only via mach_vm_read_overwrite.
 */

#include "radar_reader.h"
#include "radar_data.h"
#include "remote_memory.h"
#include "ue4_offsets.h"

#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <mach/mach.h>

/* ------------------------------------------------------------------ */
/*  Game-specific offsets  (from validated ue4_schema.json)            */
/* ------------------------------------------------------------------ */

/* UWorld */
#define GW_PERSISTENT_LEVEL   0x0030
#define GW_GAME_STATE         0x0428
#define GW_OWNING_GI          0x0470

/* UGameInstance */
#define GI_LOCAL_PLAYERS      0x0048   /* TArray<ULocalPlayer*> */

/* ULocalPlayer / UPlayer */
#define LP_PLAYER_CONTROLLER  0x0030

/* APlayerController */
#define PC_CONTROL_ROTATION   0x0428   /* FRotator (inherited from AController) */
#define PC_PLAYER             0x0518
#define PC_ACK_PAWN           0x0528
#define PC_CAMERA_MANAGER     0x0548

/* APlayerCameraManager */
#define CM_CAMERA_CACHE       0x0520
/* Inside CameraCache (FMinimalViewInfo): */
#define CC_LOCATION           0x0010   /* FVector  */
#define CC_ROTATION           0x001C   /* FRotator */
#define CC_FOV                0x0028   /* float    */

/* AGameStateBase */
#define GS_PLAYER_ARRAY       0x04C8   /* TArray<APlayerState*> */

/* AActor */
#define ACT_ROOT_COMPONENT    0x0208

/* USceneComponent */
#define SC_RELATIVE_LOC       0x01E4   /* FVector (12 bytes) */
#define SC_RELATIVE_ROT       0x01F0   /* FRotator (12 bytes) */

/* APawn */
#define PAWN_PLAYER_STATE     0x04D0
#define PAWN_CONTROLLER       0x04E8

/* ACharacter */
#define CHAR_MESH             0x0510   /* USkeletalMeshComponent* */

/* USkeletalMeshComponent */
#define SKM_CACHED_CS_XFORMS  0x0CE0   /* TArray<FTransform> */

/* STExtraBaseCharacter */
#define STBC_PLAYER_STATE     0x2410
#define STBC_HEALTH_PREDICT   0x2BC4   /* float */
#define STBC_HEALTH_STATUS    0x2BE8   /* uint8 */

/* STExtraPlayerState */
#define STPS_HEALTH           0x142C   /* float */
#define STPS_HEALTH_MAX       0x1430   /* float */
#define STPS_IN_TEAM_INDEX    0x15C0   /* uint8 */

/* TArray layout */
#define TARRAY_DATA           0x00
#define TARRAY_NUM            0x08

/* FTransform on ARM64: 48 bytes (Quat:16 + Trans:16 + Scale:16) */
#define FTRANSFORM_SIZE       48
#define FTRANSFORM_TRANS_OFF  16   /* Translation vec4 starts at +16 */

/* ------------------------------------------------------------------ */
/*  Logging                                                           */
/* ------------------------------------------------------------------ */

#define RADAR_LOG_PATH "/var/mobile/Downloads/ue4_radar.log"

static FILE *g_rlog = NULL;

static void rlog(const char *fmt, ...) {
    if (!g_rlog) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_rlog, fmt, ap);
    va_end(ap);
    fprintf(g_rlog, "\n");
    fflush(g_rlog);
}

/* ------------------------------------------------------------------ */
/*  Reader state                                                      */
/* ------------------------------------------------------------------ */

static mach_port_t  g_task       = MACH_PORT_NULL;
static uint64_t     g_image_base = 0;
static uint64_t     g_slide      = 0;

/* Shared memory */
static int            g_shm_fd   = -1;
static radar_shared_t *g_shared  = NULL;
static uint32_t       g_tick     = 0;

/* Cached pointers (re-resolved each tick in case of level transitions) */

/* ------------------------------------------------------------------ */
/*  Helpers                                                           */
/* ------------------------------------------------------------------ */

/* Read an FVector (3 floats, 12 bytes) from remote memory. */
static bool read_fvec(uint64_t addr, rvec3_t *out) {
    float v[3];
    if (!rm_read(g_task, addr, v, 12)) return false;
    out->x = v[0];
    out->y = v[1];
    out->z = v[2];
    return true;
}

/* Read an FRotator (3 floats = pitch, yaw, roll). */
static bool read_frot(uint64_t addr, rvec3_t *out) {
    return read_fvec(addr, out);  /* Same layout */
}

/* Read a TArray: returns Data pointer and element count. */
static bool read_tarray(uint64_t addr, uint64_t *data_out, int32_t *num_out) {
    uint64_t d = rm_read_ptr(g_task, addr + TARRAY_DATA);
    bool ok;
    int32_t n = rm_read_i32(g_task, addr + TARRAY_NUM, &ok);
    if (!ok || !rm_validate_ptr(d) || n < 0 || n > 10000) return false;
    *data_out = d;
    *num_out  = n;
    return true;
}

/* ------------------------------------------------------------------ */
/*  Find UWorld by scanning GUObjectArray                             */
/* ------------------------------------------------------------------ */

static uint64_t find_active_world(void) {
    /* Read config for manual GWorld address first */
    FILE *cfg = fopen("/var/mobile/Downloads/ue4_sdk_config.txt", "r");
    if (cfg) {
        char line[256];
        while (fgets(line, sizeof(line), cfg)) {
            uint64_t val = 0;
            if (sscanf(line, "gworld=0x%llx", &val) == 1 ||
                sscanf(line, "gworld=%llx", &val) == 1) {
                fclose(cfg);
                /* val is a file offset; add slide to get runtime address */
                uint64_t gworld_ptr_addr = val;
                uint64_t world = rm_read_ptr(g_task, gworld_ptr_addr);
                if (rm_validate_ptr(world)) {
                    rlog("GWorld from config: ptr at 0x%llx -> UWorld at 0x%llx",
                         (unsigned long long)gworld_ptr_addr,
                         (unsigned long long)world);
                    return world;
                }
            }
        }
        fclose(cfg);
    }

    /* Fallback: scan GUObjectArray for objects whose class name is "World" */
    /* Read GUObjectArray address from config */
    uint64_t guobj_addr = 0;
    cfg = fopen("/var/mobile/Downloads/ue4_sdk_config.txt", "r");
    if (cfg) {
        char line[256];
        while (fgets(line, sizeof(line), cfg)) {
            uint64_t val = 0;
            if (sscanf(line, "guobjectarray=0x%llx", &val) == 1 ||
                sscanf(line, "guobjectarray=%llx", &val) == 1) {
                guobj_addr = val;
                break;
            }
        }
        fclose(cfg);
    }

    if (!guobj_addr) return 0;

    /* Read chunked array */
    uint64_t chunked = guobj_addr + OFF_GUOBJ_CHUNKED;
    uint64_t objects_ptr = rm_read_ptr(g_task, chunked + OFF_CHUNKED_OBJECTS);
    bool ok;
    int32_t num_elems = rm_read_i32(g_task, chunked + OFF_CHUNKED_NUM_ELEMS, &ok);
    if (!ok || !rm_validate_ptr(objects_ptr) || num_elems <= 0) return 0;
    if (num_elems > 500000) num_elems = 500000;

    /* Scan for UWorld objects: check ClassPrivate name */
    for (int32_t i = 0; i < num_elems; i++) {
        int32_t chunk_idx = i / ELEMENTS_PER_CHUNK;
        int32_t within    = i % ELEMENTS_PER_CHUNK;

        uint64_t chunk_ptr = rm_read_ptr(g_task, objects_ptr + chunk_idx * 8);
        if (!rm_validate_ptr(chunk_ptr)) continue;

        uint64_t item_addr = chunk_ptr + within * FUOBJECTITEM_SIZE;
        uint64_t obj = rm_read_ptr(g_task, item_addr + FUOBJECTITEM_OBJECT);
        if (!rm_validate_ptr(obj)) continue;

        /* Check if this object's class name is "World" */
        uint64_t cls = rm_read_ptr(g_task, obj + OFF_UOBJECT_CLASS);
        if (!rm_validate_ptr(cls)) continue;

        /* Quick check: read class's FName, compare ComparisonIndex */
        /* For speed, check if OwningGameInstance is valid as a UWorld heuristic */
        uint64_t gi = rm_read_ptr(g_task, obj + GW_OWNING_GI);
        if (!rm_validate_ptr(gi)) continue;

        /* Verify it looks like a GameInstance by checking LocalPlayers TArray */
        uint64_t lp_data;
        int32_t lp_num;
        lp_data = rm_read_ptr(g_task, gi + GI_LOCAL_PLAYERS + TARRAY_DATA);
        lp_num  = rm_read_i32(g_task, gi + GI_LOCAL_PLAYERS + TARRAY_NUM, &ok);
        if (ok && rm_validate_ptr(lp_data) && lp_num > 0 && lp_num < 16) {
            rlog("Found active UWorld at 0x%llx (index %d)",
                 (unsigned long long)obj, i);
            return obj;
        }
    }

    return 0;
}

/* ------------------------------------------------------------------ */
/*  Read player position from RootComponent                           */
/* ------------------------------------------------------------------ */

static bool read_actor_position(uint64_t actor, rvec3_t *pos) {
    uint64_t root = rm_read_ptr(g_task, actor + ACT_ROOT_COMPONENT);
    if (!rm_validate_ptr(root)) return false;
    return read_fvec(root + SC_RELATIVE_LOC, pos);
}

static bool read_actor_rotation(uint64_t actor, float *yaw) {
    uint64_t root = rm_read_ptr(g_task, actor + ACT_ROOT_COMPONENT);
    if (!rm_validate_ptr(root)) return false;
    rvec3_t rot;
    if (!read_frot(root + SC_RELATIVE_ROT, &rot)) return false;
    *yaw = rot.y;
    return true;
}

/* ------------------------------------------------------------------ */
/*  Read skeleton bones from USkeletalMeshComponent                   */
/* ------------------------------------------------------------------ */

/* Key bone indices for a standard UE4 humanoid skeleton.
 * These map to CachedComponentSpaceTransforms[index].
 * Actual indices depend on the skeleton asset; we use common defaults.
 * Bones: Head(6), Neck(5), Spine03(4), Spine01(2), Spine02(3),
 *   L/R Clavicle(11,35), L/R UpperArm(12,36), L/R ForeArm(13,37),
 *   L/R Hand(14,38), L/R Thigh(52,56), L/R Calf(53,57),
 *   L/R Foot(54,58), Pelvis(1), Root(0)
 */
static const int kBoneMap[RADAR_NUM_BONES] = {
    6,    /* 0: Head */
    5,    /* 1: Neck */
    4,    /* 2: Spine_03 (chest) */
    2,    /* 3: Spine_01 (lower) */
    11,   /* 4: L Clavicle */
    35,   /* 5: R Clavicle */
    12,   /* 6: L UpperArm */
    36,   /* 7: R UpperArm */
    13,   /* 8: L ForeArm */
    37,   /* 9: R ForeArm */
    14,   /* 10: L Hand */
    38,   /* 11: R Hand */
    52,   /* 12: L Thigh */
    56,   /* 13: R Thigh */
    53,   /* 14: L Calf */
    57,   /* 15: R Calf */
    54,   /* 16: L Foot */
    58,   /* 17: R Foot */
    3,    /* 18: Spine_02 */
    1,    /* 19: Pelvis */
};

static bool read_skeleton(uint64_t character, rvec3_t *out_bones) {
    uint64_t mesh = rm_read_ptr(g_task, character + CHAR_MESH);
    if (!rm_validate_ptr(mesh)) return false;

    /* Read CachedComponentSpaceTransforms TArray */
    uint64_t arr_data;
    int32_t  arr_num;
    if (!read_tarray(mesh + SKM_CACHED_CS_XFORMS, &arr_data, &arr_num))
        return false;
    if (arr_num < 10) return false;  /* Not enough bones */

    /* Read mesh component's world location for offset */
    /* Bones from CachedComponentSpaceTransforms are in component space.
     * For the radar we only need approximate world positions, so the
     * caller adds the actor's root position externally. */

    for (int i = 0; i < RADAR_NUM_BONES; i++) {
        int bone_idx = kBoneMap[i];
        if (bone_idx >= arr_num) {
            out_bones[i] = (rvec3_t){0, 0, 0};
            continue;
        }
        /* FTransform at arr_data + bone_idx * 48, translation at +16 */
        uint64_t ft_addr = arr_data + (uint64_t)bone_idx * FTRANSFORM_SIZE
                         + FTRANSFORM_TRANS_OFF;
        float v[3];
        if (rm_read(g_task, ft_addr, v, 12)) {
            out_bones[i].x = v[0];
            out_bones[i].y = v[1];
            out_bones[i].z = v[2];
        } else {
            out_bones[i] = (rvec3_t){0, 0, 0};
        }
    }
    return true;
}

/* ------------------------------------------------------------------ */
/*  Public API                                                        */
/* ------------------------------------------------------------------ */

int radar_init(mach_port_t task, uint64_t image_base, uint64_t slide) {
    g_task       = task;
    g_image_base = image_base;
    g_slide      = slide;
    g_tick       = 0;

    g_rlog = fopen(RADAR_LOG_PATH, "a");
    rlog("=== radar_init (base=0x%llx slide=0x%llx) ===",
         (unsigned long long)image_base, (unsigned long long)slide);

    /* Create / open shared memory file */
    g_shm_fd = open(RADAR_FILE_PATH, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (g_shm_fd < 0) {
        rlog("ERROR: cannot open shared file");
        return -1;
    }
    chown(RADAR_FILE_PATH, 501, 501);

    /* Size the file */
    size_t total = sizeof(radar_shared_t);
    if (ftruncate(g_shm_fd, (off_t)total) != 0) {
        rlog("ERROR: ftruncate failed");
        close(g_shm_fd);
        g_shm_fd = -1;
        return -1;
    }

    g_shared = (radar_shared_t *)mmap(NULL, total,
                                       PROT_READ | PROT_WRITE,
                                       MAP_SHARED, g_shm_fd, 0);
    if (g_shared == MAP_FAILED) {
        rlog("ERROR: mmap failed");
        g_shared = NULL;
        close(g_shm_fd);
        g_shm_fd = -1;
        return -1;
    }

    memset(g_shared, 0, total);
    g_shared->header.magic   = RADAR_MAGIC;
    g_shared->header.version = RADAR_VERSION;

    rlog("radar_init OK, shared=%zu bytes", total);
    return 0;
}

int radar_tick(void) {
    if (!g_shared || g_task == MACH_PORT_NULL) return -1;

    /* 1. Find active UWorld */
    uint64_t world = find_active_world();
    if (!world) return -1;

    /* 2. Get local player info */
    uint64_t gi = rm_read_ptr(g_task, world + GW_OWNING_GI);
    if (!rm_validate_ptr(gi)) return -1;

    uint64_t lp_data;
    int32_t  lp_num;
    if (!read_tarray(gi + GI_LOCAL_PLAYERS, &lp_data, &lp_num)) return -1;
    if (lp_num < 1) return -1;

    uint64_t local_player = rm_read_ptr(g_task, lp_data);
    if (!rm_validate_ptr(local_player)) return -1;

    uint64_t pc = rm_read_ptr(g_task, local_player + LP_PLAYER_CONTROLLER);
    if (!rm_validate_ptr(pc)) return -1;

    uint64_t local_pawn = rm_read_ptr(g_task, pc + PC_ACK_PAWN);
    /* local_pawn may be null (spectating, dead, etc.) */

    /* 3. Camera info */
    uint64_t cam_mgr = rm_read_ptr(g_task, pc + PC_CAMERA_MANAGER);
    rvec3_t cam_loc = {0, 0, 0};
    rvec3_t cam_rot = {0, 0, 0};
    float   cam_fov = 90.0f;

    if (rm_validate_ptr(cam_mgr)) {
        uint64_t cache_base = cam_mgr + CM_CAMERA_CACHE;
        read_fvec(cache_base + CC_LOCATION, &cam_loc);
        read_frot(cache_base + CC_ROTATION, &cam_rot);
        float fov_val;
        if (rm_read(g_task, cache_base + CC_FOV, &fov_val, 4)) {
            if (fov_val > 10.0f && fov_val < 180.0f) cam_fov = fov_val;
        }
    }

    /* Local player position */
    rvec3_t local_pos = {0, 0, 0};
    if (rm_validate_ptr(local_pawn)) {
        read_actor_position(local_pawn, &local_pos);
    } else {
        local_pos = cam_loc;  /* Use camera pos if no pawn */
    }

    /* 4. Iterate PlayerArray from GameState */
    uint64_t game_state = rm_read_ptr(g_task, world + GW_GAME_STATE);
    if (!rm_validate_ptr(game_state)) {
        /* Write empty header */
        g_shared->header.tick = ++g_tick;
        g_shared->header.player_count = 0;
        g_shared->header.local_pos = local_pos;
        g_shared->header.local_rot = cam_rot;
        g_shared->header.camera_fov = cam_fov;
        msync(g_shared, sizeof(radar_header_t), MS_ASYNC);
        return 0;
    }

    uint64_t pa_data;
    int32_t  pa_num;
    if (!read_tarray(game_state + GS_PLAYER_ARRAY, &pa_data, &pa_num)) {
        pa_num = 0;
    }

    int count = 0;
    for (int32_t i = 0; i < pa_num && count < RADAR_MAX_PLAYERS; i++) {
        uint64_t ps = rm_read_ptr(g_task, pa_data + i * 8);
        if (!rm_validate_ptr(ps)) continue;

        /* PlayerState -> get pawn.
         * APlayerState inherits AInfo -> AActor -> UObject.
         * The Pawn reference: check for a property.  In PUBG Mobile,
         * APlayerState stores it internally.  We can also get it from
         * the Pawn's PlayerState backlink.
         *
         * Alternative approach: read the pawn from PlayerState.
         * UE4 stores it at a version-specific offset.  For PUBG this
         * is typically right after the replicated fields.
         *
         * Simpler: iterate Level actors and match by PlayerState.
         * But for speed, let's try the common APlayerState::PawnPrivate
         * offset.  On UE 4.25 ARM64, this is often at +0x0480. */
        #define PS_PAWN_PRIVATE  0x0480

        uint64_t pawn = rm_read_ptr(g_task, ps + PS_PAWN_PRIVATE);
        if (!rm_validate_ptr(pawn)) continue;

        /* Skip the local player's own pawn */
        if (pawn == local_pawn) continue;

        radar_player_t *p = &g_shared->players[count];
        memset(p, 0, sizeof(*p));

        /* Position */
        if (!read_actor_position(pawn, &p->pos)) continue;

        /* Rotation (yaw) */
        read_actor_rotation(pawn, &p->yaw);

        /* Health — try STExtraPlayerState first */
        uint64_t st_ps = rm_read_ptr(g_task, pawn + STBC_PLAYER_STATE);
        if (rm_validate_ptr(st_ps)) {
            float h  = 0, hm = 100;
            if (rm_read(g_task, st_ps + STPS_HEALTH, &h, 4)) p->health = h;
            if (rm_read(g_task, st_ps + STPS_HEALTH_MAX, &hm, 4)) p->health_max = hm;

            uint8_t ti = 0;
            rm_read(g_task, st_ps + STPS_IN_TEAM_INDEX, &ti, 1);
            p->team_id = ti;
        } else {
            p->health     = 100.0f;
            p->health_max = 100.0f;
        }

        /* Health status from character */
        uint8_t hs = 0;
        rm_read(g_task, pawn + STBC_HEALTH_STATUS, &hs, 1);
        p->health_status = hs;

        /* Skeleton bones */
        p->has_bones = read_skeleton(pawn, p->bones) ? 1 : 0;

        count++;
    }

    /* 5. Write header */
    g_shared->header.magic        = RADAR_MAGIC;
    g_shared->header.version      = RADAR_VERSION;
    g_shared->header.tick         = ++g_tick;
    g_shared->header.player_count = (uint32_t)count;
    g_shared->header.local_pos    = local_pos;
    g_shared->header.local_rot    = cam_rot;
    g_shared->header.camera_fov   = cam_fov;

    msync(g_shared, sizeof(radar_header_t) +
          count * sizeof(radar_player_t), MS_ASYNC);

    if (g_tick % 200 == 1) {
        rlog("tick=%u players=%d local=(%.0f,%.0f,%.0f) cam_yaw=%.1f",
             g_tick, count, local_pos.x, local_pos.y, local_pos.z,
             cam_rot.y);
    }

    return 0;
}

void radar_destroy(void) {
    if (g_shared) {
        munmap(g_shared, sizeof(radar_shared_t));
        g_shared = NULL;
    }
    if (g_shm_fd >= 0) {
        close(g_shm_fd);
        g_shm_fd = -1;
    }
    if (g_rlog) {
        rlog("=== radar_destroy ===");
        fclose(g_rlog);
        g_rlog = NULL;
    }
}
