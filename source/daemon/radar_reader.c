/*
 * radar_reader.c — Live read-only radar & ESP engine.
 *
 * Reads UE4 reflection structures and game state from the target game
 * process (ShadowTrackerExtra) and publishes live telemetry to a shared
 * mmap file for the SpringBoard overlay tweak.
 */

#include "radar_reader.h"
#include "radar_data.h"
#include "remote_memory.h"
#include "ue4_reflection.h"
#include "ue4_offsets.h"
#include "config_address.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

static mach_port_t task;
static uint64_t base, slide, world, local_player;
static ue4r_ctx_t *reflection;
static radar_shared_t *shared;
static radar_shared_t frame;
static int fd = -1;
static FILE *logfile;
static uint32_t tick, last_status = UINT32_MAX;
static double next_lookup;
static int32_t world_cursor;

/* Cached candidate actor pointers */
static uint64_t characters[512];
static unsigned character_count;
static uint64_t vehicles[64];
static unsigned vehicle_count;
static uint64_t items[256];
static unsigned item_count;

static int32_t char_cursor;
static int32_t veh_cursor;
static int32_t item_cursor;
static double next_scan_time;

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static uint64_t ptr(uint64_t object, uint64_t offset) {
    if (!rm_validate_ptr(object) || object > UINT64_MAX - offset) return 0;
    uint64_t value = rm_read_ptr(task, object + offset);
    return rm_validate_ptr(value) ? value : 0;
}

static bool array(uint64_t object, uint64_t offset, uint64_t *data, int32_t *count, int limit) {
    struct { uint64_t data; int32_t count, capacity; } a;
    if (!rm_validate_ptr(object) || !rm_read(task, object + offset, &a, sizeof(a))) return false;
    if (a.count < 0 || a.capacity < a.count || a.count > limit || a.capacity > 1000000) return false;
    if (a.count && !rm_validate_ptr(a.data)) return false;
    *data = a.data;
    *count = a.count;
    return true;
}

static bool vec(uint64_t object, uint64_t offset, rvec3_t *out) {
    rvec3_t v;
    if (!rm_validate_ptr(object) || !rm_read(task, object + offset, &v, sizeof(v))) return false;
    if (!isfinite(v.x) || !isfinite(v.y) || !isfinite(v.z)) return false;
    *out = v;
    return true;
}

static bool position(uint64_t actor, rvec3_t *out) {
    return vec(ptr(actor, 0x208), 0x1e4, out);
}

static bool read_fstring(mach_port_t t, uint64_t fstring_addr, char *buf, size_t max_len) {
    if (!rm_validate_ptr(fstring_addr) || max_len < 2) return false;
    struct {
        uint64_t data;
        int32_t count;
        int32_t max;
    } s;
    if (!rm_read(t, fstring_addr, &s, sizeof(s))) return false;
    if (s.count <= 1 || s.count > 128 || !rm_validate_ptr(s.data)) return false;
    uint16_t wbuf[128] = {0};
    size_t to_read = (size_t)s.count * sizeof(uint16_t);
    if (to_read > sizeof(wbuf)) to_read = sizeof(wbuf);
    if (!rm_read(t, s.data, wbuf, to_read)) return false;
    size_t out_idx = 0;
    for (int i = 0; i < s.count && out_idx + 1 < max_len; i++) {
        uint16_t c = wbuf[i];
        if (c == 0) break;
        if (c >= 32 && c <= 126) {
            buf[out_idx++] = (char)c;
        } else {
            buf[out_idx++] = '?';
        }
    }
    buf[out_idx] = '\0';
    return out_idx > 0;
}

static void resolve_item_info(int32_t item_id, char *name, size_t max_len, uint8_t *category) {
    *category = 5;
    switch (item_id) {
        /* Assault Rifles */
        case 101001: snprintf(name, max_len, "AKM"); *category = 1; return;
        case 101002: snprintf(name, max_len, "M16A4"); *category = 1; return;
        case 101003: snprintf(name, max_len, "SCAR-L"); *category = 1; return;
        case 101004: snprintf(name, max_len, "M416"); *category = 1; return;
        case 101005: snprintf(name, max_len, "Groza"); *category = 1; return;
        case 101006: snprintf(name, max_len, "AUG"); *category = 1; return;
        case 101007: snprintf(name, max_len, "QBZ"); *category = 1; return;
        case 101008: snprintf(name, max_len, "M762"); *category = 1; return;
        case 101009: snprintf(name, max_len, "Mk47"); *category = 1; return;
        case 101010: snprintf(name, max_len, "G36C"); *category = 1; return;
        /* Sniper & DMR */
        case 103001: snprintf(name, max_len, "Kar98k"); *category = 1; return;
        case 103002: snprintf(name, max_len, "M24"); *category = 1; return;
        case 103003: snprintf(name, max_len, "AWM"); *category = 1; return;
        case 103004: snprintf(name, max_len, "SKS"); *category = 1; return;
        case 103005: snprintf(name, max_len, "VSS"); *category = 1; return;
        case 103006: snprintf(name, max_len, "Mini14"); *category = 1; return;
        case 103007: snprintf(name, max_len, "Mk14"); *category = 1; return;
        case 103008: snprintf(name, max_len, "Win94"); *category = 1; return;
        case 103009: snprintf(name, max_len, "SLR"); *category = 1; return;
        case 103010: snprintf(name, max_len, "QBU"); *category = 1; return;
        /* Armor & Helmets & Backpacks */
        case 501001: snprintf(name, max_len, "Helmet L1"); *category = 2; return;
        case 501002: snprintf(name, max_len, "Helmet L2"); *category = 2; return;
        case 501003: case 501006: snprintf(name, max_len, "Helmet L3"); *category = 2; return;
        case 502001: snprintf(name, max_len, "Vest L1"); *category = 2; return;
        case 502002: snprintf(name, max_len, "Vest L2"); *category = 2; return;
        case 502003: snprintf(name, max_len, "Vest L3"); *category = 2; return;
        case 503001: snprintf(name, max_len, "Bag L1"); *category = 2; return;
        case 503002: snprintf(name, max_len, "Bag L2"); *category = 2; return;
        case 503003: snprintf(name, max_len, "Bag L3"); *category = 2; return;
        /* Meds */
        case 601001: snprintf(name, max_len, "Bandage"); *category = 3; return;
        case 601002: snprintf(name, max_len, "FirstAid"); *category = 3; return;
        case 601003: snprintf(name, max_len, "MedKit"); *category = 3; return;
        case 601004: snprintf(name, max_len, "Drink"); *category = 3; return;
        case 601005: snprintf(name, max_len, "Painkiller"); *category = 3; return;
        case 601006: snprintf(name, max_len, "Adrenaline"); *category = 3; return;
        /* Scopes & Ammo */
        case 203001: snprintf(name, max_len, "RedDot"); *category = 4; return;
        case 203002: snprintf(name, max_len, "Holo"); *category = 4; return;
        case 203003: snprintf(name, max_len, "2x Scope"); *category = 4; return;
        case 203004: snprintf(name, max_len, "4x Scope"); *category = 4; return;
        case 203014: snprintf(name, max_len, "6x Scope"); *category = 4; return;
        case 203015: snprintf(name, max_len, "8x Scope"); *category = 4; return;
        case 301001: snprintf(name, max_len, "5.56 Ammo"); *category = 4; return;
        case 302001: snprintf(name, max_len, "7.62 Ammo"); *category = 4; return;
        case 303001: snprintf(name, max_len, ".300 Mag"); *category = 4; return;
        case 304001: snprintf(name, max_len, "9mm Ammo"); *category = 4; return;
        case 305001: snprintf(name, max_len, ".45 Ammo"); *category = 4; return;
        default:
            if (item_id > 0) snprintf(name, max_len, "Item %d", item_id);
            else snprintf(name, max_len, "Loot");
            *category = 5;
            return;
    }
}

static void resolve_vehicle_name(const char *cls_name, char *name, size_t max_len) {
    if (!cls_name || !cls_name[0]) { snprintf(name, max_len, "Vehicle"); return; }
    if (strstr(cls_name, "Buggy")) snprintf(name, max_len, "Buggy");
    else if (strstr(cls_name, "Dacia")) snprintf(name, max_len, "Dacia");
    else if (strstr(cls_name, "UAZ") || strstr(cls_name, "Uaz")) snprintf(name, max_len, "UAZ");
    else if (strstr(cls_name, "Motorcycle") || strstr(cls_name, "Bike")) snprintf(name, max_len, "Motorcycle");
    else if (strstr(cls_name, "Scooter")) snprintf(name, max_len, "Scooter");
    else if (strstr(cls_name, "Tuk")) snprintf(name, max_len, "TukTuk");
    else if (strstr(cls_name, "Boat") || strstr(cls_name, "Aqua")) snprintf(name, max_len, "Boat");
    else if (strstr(cls_name, "PickUp")) snprintf(name, max_len, "PickUp");
    else if (strstr(cls_name, "Bus") || strstr(cls_name, "Van")) snprintf(name, max_len, "Minibus");
    else if (strstr(cls_name, "Mirado")) snprintf(name, max_len, "Mirado");
    else if (strstr(cls_name, "BRDM")) snprintf(name, max_len, "BRDM");
    else snprintf(name, max_len, "Vehicle");
}

static void publish(uint32_t status) {
    frame.header.magic = RADAR_MAGIC;
    frame.header.version = RADAR_VERSION;
    frame.header.tick = ++tick;
    frame.header.status = status;
    uint32_t sequence = __atomic_load_n(&shared->header.sequence, __ATOMIC_RELAXED);
    sequence = (sequence + 1u) | 1u;
    __atomic_store_n(&shared->header.sequence, sequence, __ATOMIC_SEQ_CST);

    size_t prefix = (size_t)((char *)&shared->header.sequence - (char *)shared);
    memcpy(shared, &frame, prefix);
    size_t suffix = prefix + sizeof(uint32_t);
    memcpy((char *)shared + suffix, (char *)&frame + suffix, sizeof(frame) - suffix);
    __atomic_store_n(&shared->header.sequence, sequence + 1u, __ATOMIC_RELEASE);

    if (logfile && (status != last_status || tick % 200 == 0)) {
        fprintf(logfile, "tick=%u status=%u players=%u vehicles=%u items=%u world=0x%llx local=(%.1f,%.1f,%.1f)\n",
            tick, status, frame.header.player_count, frame.header.vehicle_count, frame.header.item_count,
            world, frame.header.local_pos.x, frame.header.local_pos.y, frame.header.local_pos.z);
        fflush(logfile);
    }
    last_status = status;
}

static void read_config(uint64_t *objects, uint64_t *names) {
    *objects = 0;
    *names = 0;
    FILE *f = fopen("/var/mobile/Downloads/ue4_sdk_config.txt", "r");
    if (!f) return;
    char line[256], key[128];
    unsigned long long value;
    while (fgets(line, sizeof(line), f)) {
        if (sscanf(line, " %127[^=]=%llx", key, &value) != 2) continue;
        if (!strcmp(key, "guobjectarray")) *objects = value;
        if (!strcmp(key, "gnamepool")) *names = value;
    }
    fclose(f);
}

static uint64_t local_controller(uint64_t w) {
    if (local_player && ptr(ptr(local_player, 0x58), 0x78) == w) {
        uint64_t pc = ptr(local_player, 0x30);
        if (pc && ptr(pc, 0x518) == local_player) return pc;
    }
    uint64_t gi = ptr(w, 0x470), data;
    int32_t count;
    if (!array(gi, 0x48, &data, &count, 16) || !count) return 0;
    return ptr(ptr(data, 0), 0x30);
}

static uint64_t find_world(void) {
    if (local_player) {
        uint64_t current = ptr(ptr(local_player, 0x58), 0x78);
        if (current && local_controller(current)) {
            if (world && world != current) {
                character_count = 0;
                vehicle_count = 0;
                item_count = 0;
            }
            world = current;
            return world;
        }
        local_player = 0;
    }
    world = 0;
    double now = now_seconds();
    if (now < next_lookup) return 0;
    next_lookup = now + 0.05;
    if (!reflection) {
        uint64_t objects, names;
        read_config(&objects, &names);
        reflection = ue4r_init(task, base, slide, objects, names);
        if (!ue4r_ready(reflection)) {
            if (reflection) ue4r_destroy(reflection);
            reflection = NULL;
            return 0;
        }
    }
    if (world_cursor < 0) {
        world_cursor = 0;
        next_lookup = now + 0.5;
        return 0;
    }
    uint64_t candidate = ue4r_find_instance(reflection, "LocalPlayer", &world_cursor);
    if (candidate) {
        uint64_t viewport = ptr(candidate, 0x58), w = ptr(viewport, 0x78), pc = ptr(candidate, 0x30);
        if (logfile) {
            fprintf(logfile, "LocalPlayer=0x%llx viewport=0x%llx world=0x%llx pc=0x%llx backlink=0x%llx\n",
                candidate, viewport, w, pc, ptr(pc, 0x518));
            fflush(logfile);
        }
        if (w && pc && ptr(pc, 0x518) == candidate) {
            local_player = candidate;
            world = w;
        }
    }
    return world;
}

static void add_character(uint64_t actor) {
    if (!actor) return;
    for (unsigned i = 0; i < character_count; i++) {
        if (characters[i] == actor) return;
    }
    if (character_count < 512) {
        characters[character_count++] = actor;
    }
}

static void add_vehicle(uint64_t actor) {
    if (!actor) return;
    for (unsigned i = 0; i < vehicle_count; i++) {
        if (vehicles[i] == actor) return;
    }
    if (vehicle_count < 64) {
        vehicles[vehicle_count++] = actor;
    }
}

static void add_item(uint64_t actor) {
    if (!actor) return;
    for (unsigned i = 0; i < item_count; i++) {
        if (items[i] == actor) return;
    }
    if (item_count < 256) {
        items[item_count++] = actor;
    }
}

/* Fast scan of PersistentLevel Actors array */
static bool scan_persistent_level(uint64_t w) {
    uint64_t level = ptr(w, 0x30);
    if (!level) return false;

    /* Search common offsets in ULevel for TArray<AActor*> Actors */
    static const uint64_t offsets[] = { 0x98, 0xa0, 0xa8, 0xb0, 0x90, 0x70, 0x78, 0x80 };
    uint64_t data = 0;
    int32_t count = 0;
    bool found_arr = false;
    for (size_t o = 0; o < sizeof(offsets)/sizeof(offsets[0]); o++) {
        if (array(level, offsets[o], &data, &count, 8192) && count >= 10) {
            found_arr = true;
            break;
        }
    }
    if (!found_arr || !data || count < 10) return false;

    /* Classify actors */
    for (int i = 0; i < count; i++) {
        uint64_t actor = rm_read_ptr(task, data + (uint64_t)i * 8);
        if (!rm_validate_ptr(actor)) continue;
        uint64_t cls = ptr(actor, 0x10);
        if (!cls) continue;

        char cls_name[128] = {0};
        if (!ue4r_resolve_name(reflection, cls + OFF_UOBJECT_NAME, cls_name, sizeof(cls_name))) continue;

        if (strstr(cls_name, "Character") || strstr(cls_name, "Player")) {
            add_character(actor);
        } else if (strstr(cls_name, "Vehicle") || strstr(cls_name, "VH_")) {
            add_vehicle(actor);
        } else if (strstr(cls_name, "PickUp") || strstr(cls_name, "Wrapper")) {
            add_item(actor);
        }
    }
    return true;
}

/* Fallback: reflection instance discovery */
static void scan_reflection_instances(void) {
    if (!reflection || !ue4r_ready(reflection)) return;

    /* Scan characters */
    if (char_cursor >= 0) {
        for (int b = 0; b < 4; b++) {
            uint64_t found = ue4r_find_instance(reflection, "STExtraBaseCharacter", &char_cursor);
            if (found) add_character(found);
            if (char_cursor < 0) { char_cursor = 0; break; }
        }
    }

    /* Scan vehicles */
    if (veh_cursor >= 0) {
        for (int b = 0; b < 2; b++) {
            uint64_t found = ue4r_find_instance(reflection, "STExtraVehicleBase", &veh_cursor);
            if (found) add_vehicle(found);
            if (veh_cursor < 0) { veh_cursor = 0; break; }
        }
    }

    /* Scan loot items */
    if (item_cursor >= 0) {
        for (int b = 0; b < 4; b++) {
            uint64_t found = ue4r_find_instance(reflection, "PickUpWrapperActor", &item_cursor);
            if (found) add_item(found);
            if (item_cursor < 0) { item_cursor = 0; break; }
        }
    }
}

int radar_init(mach_port_t target, uint64_t image_base, uint64_t aslr_slide) {
    local_player = 0;
    task = target;
    base = image_base;
    slide = aslr_slide;
    world = 0;
    tick = 0;
    next_lookup = 0;
    last_status = UINT32_MAX;
    world_cursor = 0;
    char_cursor = 0;
    veh_cursor = 0;
    item_cursor = 0;
    character_count = 0;
    vehicle_count = 0;
    item_count = 0;
    next_scan_time = 0;

    logfile = fopen("/var/mobile/Downloads/ue4_radar.log", "a");
    fd = open(RADAR_FILE_PATH, O_RDWR | O_CREAT, 0644);
    if (fd < 0) goto fail;
    if (ftruncate(fd, sizeof(radar_shared_t))) goto fail;
    shared = mmap(NULL, sizeof(*shared), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (shared == MAP_FAILED) {
        shared = NULL;
        goto fail;
    }
    chown(RADAR_FILE_PATH, 501, 501);
    memset(&frame, 0, sizeof(frame));
    publish(1);
    return 0;

fail:
    radar_destroy();
    return -1;
}

int radar_tick(void) {
    if (!shared) return -1;
    memset(&frame, 0, sizeof(frame));
    frame.header.camera_fov = 90.0f;

    if (!find_world()) {
        publish(1);
        return 0;
    }

    uint64_t pc = local_controller(world);
    if (!pc) {
        publish(1);
        return 0;
    }

    uint64_t pawn = ptr(pc, 0x528);
    uint64_t camera = ptr(pc, 0x548);
    bool has_local = position(pawn, &frame.header.local_pos);

    rvec3_t camera_pos = {0};
    bool camera_ok = vec(camera, 0x530, &camera_pos);
    frame.header.camera_pos = camera_pos;
    if (!has_local) frame.header.local_pos = camera_pos;

    camera_ok = vec(camera, 0x548, &frame.header.local_rot) && camera_ok;
    float fov;
    if (camera && rm_read(task, camera + 0x554, &fov, 4) && isfinite(fov) && fov > 10 && fov < 180) {
        frame.header.camera_fov = fov;
        frame.header.camera_valid = camera_ok;
    }

    /* Read local player team */
    if (pawn) {
        uint64_t local_st = ptr(pawn, 0x2410);
        if (!local_st) local_st = ptr(pawn, 0x4d0);
        if (local_st) {
            uint32_t t = 0;
            if (rm_read(task, local_st + 0x700, &t, 4)) frame.header.local_team = t;
        }
    }

    /* Actor discovery cadence */
    double now = now_seconds();
    if (now >= next_scan_time) {
        next_scan_time = now + 0.15; /* 150ms scan interval */
        if (!scan_persistent_level(world)) {
            scan_reflection_instances();
        }
    }

    /* Process characters / players */
    for (unsigned i = 0; i < character_count && frame.header.player_count < RADAR_MAX_PLAYERS; i++) {
        uint64_t other = characters[i];
        if (!other || other == pawn) continue;

        radar_player_t p;
        memset(&p, 0, sizeof(p));
        if (!position(other, &p.pos)) {
            characters[i] = 0;
            continue;
        }

        uint64_t st = ptr(other, 0x2410);
        if (!st) st = ptr(other, 0x4d0);
        if (!st) continue;

        if (!rm_read(task, st + 0x142c, &p.health, 4) || !rm_read(task, st + 0x1430, &p.health_max, 4)) continue;
        if (!isfinite(p.health) || !isfinite(p.health_max) || p.health_max <= 0 || p.health_max > 100000) continue;

        rm_read(task, other + 0x2be8, &p.health_status, 1);
        if (p.health_status == 2) continue; /* Dead */

        rvec3_t rot;
        if (vec(ptr(other, 0x208), 0x1f0, &rot)) p.yaw = rot.y;

        /* Team and bot */
        rm_read(task, st + 0x700, &p.team_id, 4);
        rm_read(task, st + 0x4dc, &p.is_bot, 1);

        /* Player Name */
        if (!read_fstring(task, st + 0x4b8, p.name, sizeof(p.name))) {
            if (!read_fstring(task, st + 0x13e0, p.name, sizeof(p.name))) {
                if (p.is_bot) snprintf(p.name, sizeof(p.name), "Bot");
                else snprintf(p.name, sizeof(p.name), "Player");
            }
        }

        /* Distance */
        float dx = p.pos.x - camera_pos.x;
        float dy = p.pos.y - camera_pos.y;
        float dz = p.pos.z - camera_pos.z;
        p.distance = sqrtf(dx*dx + dy*dy + dz*dz) / 100.0f;

        /* Head and feet positions */
        p.head_pos = (rvec3_t){ p.pos.x, p.pos.y, p.pos.z + 75.0f };
        p.feet_pos = (rvec3_t){ p.pos.x, p.pos.y, p.pos.z - 85.0f };

        /* Generate humanoid skeleton bones */
        float yaw_rad = p.yaw * (float)M_PI / 180.0f;
        float right_x = -sinf(yaw_rad);
        float right_y = cosf(yaw_rad);

        p.bones[0]  = (rvec3_t){ p.pos.x, p.pos.y, p.pos.z + 75.0f }; /* Head */
        p.bones[1]  = (rvec3_t){ p.pos.x, p.pos.y, p.pos.z + 60.0f }; /* Neck */
        p.bones[2]  = (rvec3_t){ p.pos.x, p.pos.y, p.pos.z + 42.0f }; /* Chest */
        p.bones[3]  = (rvec3_t){ p.pos.x, p.pos.y, p.pos.z + 0.0f };  /* Pelvis */
        /* Left arm */
        p.bones[4]  = (rvec3_t){ p.pos.x - right_x * 18.0f, p.pos.y - right_y * 18.0f, p.pos.z + 56.0f }; /* L Shoulder */
        p.bones[5]  = (rvec3_t){ p.bones[4].x, p.bones[4].y, p.bones[4].z - 24.0f };                        /* L Elbow */
        p.bones[6]  = (rvec3_t){ p.bones[5].x, p.bones[5].y, p.bones[5].z - 22.0f };                        /* L Hand */
        /* Right arm */
        p.bones[7]  = (rvec3_t){ p.pos.x + right_x * 18.0f, p.pos.y + right_y * 18.0f, p.pos.z + 56.0f }; /* R Shoulder */
        p.bones[8]  = (rvec3_t){ p.bones[7].x, p.bones[7].y, p.bones[7].z - 24.0f };                        /* R Elbow */
        p.bones[9]  = (rvec3_t){ p.bones[8].x, p.bones[8].y, p.bones[8].z - 22.0f };                        /* R Hand */
        /* Left leg */
        p.bones[10] = (rvec3_t){ p.pos.x - right_x * 12.0f, p.pos.y - right_y * 12.0f, p.pos.z + 0.0f };  /* L Hip */
        p.bones[11] = (rvec3_t){ p.bones[10].x, p.bones[10].y, p.bones[10].z - 42.0f };                     /* L Knee */
        p.bones[12] = (rvec3_t){ p.bones[11].x, p.bones[11].y, p.bones[11].z - 40.0f };                     /* L Foot */
        /* Right leg */
        p.bones[13] = (rvec3_t){ p.pos.x + right_x * 12.0f, p.pos.y + right_y * 12.0f, p.pos.z + 0.0f };  /* R Hip */
        p.bones[14] = (rvec3_t){ p.bones[13].x, p.bones[13].y, p.bones[13].z - 42.0f };                     /* R Knee */
        p.bones[15] = (rvec3_t){ p.bones[14].x, p.bones[14].y, p.bones[14].z - 40.0f };                     /* R Foot */
        p.has_bones = 1;

        frame.players[frame.header.player_count++] = p;
    }

    /* Process vehicles */
    for (unsigned i = 0; i < vehicle_count && frame.header.vehicle_count < RADAR_MAX_VEHICLES; i++) {
        uint64_t vactor = vehicles[i];
        if (!vactor) continue;

        radar_vehicle_t v;
        memset(&v, 0, sizeof(v));
        if (!position(vactor, &v.pos)) {
            vehicles[i] = 0;
            continue;
        }

        float dx = v.pos.x - camera_pos.x;
        float dy = v.pos.y - camera_pos.y;
        float dz = v.pos.z - camera_pos.z;
        v.distance = sqrtf(dx*dx + dy*dy + dz*dz) / 100.0f;
        if (v.distance > 450.0f) continue; /* Skip vehicles beyond 450m */

        float fwd_speed = 0.0f;
        rm_read(task, vactor + 0xcd0, &fwd_speed, 4);
        v.speed = fabsf(fwd_speed) * 0.036f;

        rm_read(task, vactor + 0x18c9, &v.health_state, 1);
        rm_read(task, vactor + 0x1978, &v.can_boost, 1);
        rm_read(task, vactor + 0x1574, &v.team_id, 1);

        char cls_buf[128] = {0};
        uint64_t cls = ptr(vactor, 0x10);
        if (cls && reflection) {
            ue4r_resolve_name(reflection, cls + OFF_UOBJECT_NAME, cls_buf, sizeof(cls_buf));
        }
        resolve_vehicle_name(cls_buf, v.name, sizeof(v.name));

        frame.vehicles[frame.header.vehicle_count++] = v;
    }

    /* Process loot items */
    for (unsigned i = 0; i < item_count && frame.header.item_count < RADAR_MAX_ITEMS; i++) {
        uint64_t iactor = items[i];
        if (!iactor) continue;

        radar_item_t item;
        memset(&item, 0, sizeof(item));
        if (!position(iactor, &item.pos)) {
            items[i] = 0;
            continue;
        }

        float dx = item.pos.x - camera_pos.x;
        float dy = item.pos.y - camera_pos.y;
        float dz = item.pos.z - camera_pos.z;
        item.distance = sqrtf(dx*dx + dy*dy + dz*dz) / 100.0f;
        if (item.distance > 120.0f) continue; /* Skip distant loot */

        rm_read(task, iactor + 0x758, &item.item_id, 4);
        rm_read(task, iactor + 0x610, &item.count, 4);
        if (item.count <= 0) item.count = 1;

        resolve_item_info(item.item_id, item.name, sizeof(item.name), &item.category);

        frame.items[frame.header.item_count++] = item;
    }

    if (logfile && tick % 200 == 0) {
        fprintf(logfile, "radar_tick: players=%u vehicles=%u items=%u world=0x%llx\n",
            frame.header.player_count, frame.header.vehicle_count, frame.header.item_count, world);
        fflush(logfile);
    }

    publish((has_local || frame.header.camera_valid) ? 2 : 3);
    return 0;
}

void radar_destroy(void) {
    if (shared) {
        memset(&frame, 0, sizeof(frame));
        publish(0);
        munmap(shared, sizeof(*shared));
        shared = NULL;
    }
    if (fd >= 0) {
        close(fd);
        fd = -1;
    }
    if (reflection) {
        ue4r_destroy(reflection);
        reflection = NULL;
    }
    if (logfile) {
        fclose(logfile);
        logfile = NULL;
    }
    task = MACH_PORT_NULL;
    world = 0;
}
