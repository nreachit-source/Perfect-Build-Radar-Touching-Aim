/*
 * radar_reader.c — High-performance live read-only radar & ESP telemetry engine.
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
static double started_at;
static bool first_live;
static uint32_t tick, last_status = UINT32_MAX;
static double next_lookup;
static int32_t world_cursor;

/* Fast Class Cache: resolves each UClass* at most once */
#define CLASS_CACHE_SIZE 4096
typedef enum {
    CLS_UNKNOWN = 0,
    CLS_IGNORE,
    CLS_PLAYER,
    CLS_VEHICLE,
    CLS_ITEM
} cls_type_t;

typedef struct {
    uint64_t   class_ptr;
    cls_type_t type;
    char       name[32];
} class_cache_entry_t;

static class_cache_entry_t g_classes[CLASS_CACHE_SIZE];
static uint32_t           g_class_count = 0;

/* Cached candidate actor pointers */
static uint64_t characters[512];
static unsigned character_count;
static uint64_t vehicles[64];
static unsigned vehicle_count;
static uint64_t items[256];
static unsigned item_count;
static double   next_scan_time;
static uint32_t s_cached_local_team = 0;

/* High-efficiency metadata cache to eliminate redundant Mach IPC kernel traps */
typedef struct {
    uint64_t actor;
    uint32_t team_id;
    uint8_t  is_bot;
    char     name[32];
    bool     valid;
} player_meta_cache_t;

#define PLAYER_META_CACHE_SIZE 512
static player_meta_cache_t g_player_meta[PLAYER_META_CACHE_SIZE];
static unsigned            g_player_meta_count = 0;

static const player_meta_cache_t *find_player_meta(uint64_t actor) {
    for (unsigned i = 0; i < g_player_meta_count; i++) {
        if (g_player_meta[i].valid && g_player_meta[i].actor == actor) {
            return &g_player_meta[i];
        }
    }
    return NULL;
}

static void store_player_meta(uint64_t actor, uint32_t team_id, uint8_t is_bot, const char *name) {
    for (unsigned i = 0; i < g_player_meta_count; i++) {
        if (g_player_meta[i].actor == actor) {
            g_player_meta[i].team_id = team_id;
            g_player_meta[i].is_bot = is_bot;
            strncpy(g_player_meta[i].name, name, sizeof(g_player_meta[i].name) - 1);
            g_player_meta[i].name[sizeof(g_player_meta[i].name) - 1] = '\0';
            g_player_meta[i].valid = true;
            return;
        }
    }
    if (g_player_meta_count < PLAYER_META_CACHE_SIZE) {
        unsigned idx = g_player_meta_count++;
        g_player_meta[idx].actor = actor;
        g_player_meta[idx].team_id = team_id;
        g_player_meta[idx].is_bot = is_bot;
        strncpy(g_player_meta[idx].name, name, sizeof(g_player_meta[idx].name) - 1);
        g_player_meta[idx].name[sizeof(g_player_meta[idx].name) - 1] = '\0';
        g_player_meta[idx].valid = true;
    }
}

typedef struct {
    uint64_t actor;
    int32_t  item_id;
    uint8_t  category;
    char     name[32];
    bool     valid;
} item_meta_cache_t;

#define ITEM_META_CACHE_SIZE 256
static item_meta_cache_t g_item_meta[ITEM_META_CACHE_SIZE];
static unsigned          g_item_meta_count = 0;

static const item_meta_cache_t *find_item_meta(uint64_t actor) {
    for (unsigned i = 0; i < g_item_meta_count; i++) {
        if (g_item_meta[i].valid && g_item_meta[i].actor == actor) {
            return &g_item_meta[i];
        }
    }
    return NULL;
}

static void store_item_meta(uint64_t actor, int32_t item_id, uint8_t category, const char *name) {
    for (unsigned i = 0; i < g_item_meta_count; i++) {
        if (g_item_meta[i].actor == actor) {
            g_item_meta[i].item_id = item_id;
            g_item_meta[i].category = category;
            strncpy(g_item_meta[i].name, name, sizeof(g_item_meta[i].name) - 1);
            g_item_meta[i].name[sizeof(g_item_meta[i].name) - 1] = '\0';
            g_item_meta[i].valid = true;
            return;
        }
    }
    if (g_item_meta_count < ITEM_META_CACHE_SIZE) {
        unsigned idx = g_item_meta_count++;
        g_item_meta[idx].actor = actor;
        g_item_meta[idx].item_id = item_id;
        g_item_meta[idx].category = category;
        strncpy(g_item_meta[idx].name, name, sizeof(g_item_meta[idx].name) - 1);
        g_item_meta[idx].name[sizeof(g_item_meta[idx].name) - 1] = '\0';
        g_item_meta[idx].valid = true;
    }
}

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
        int32_t  count;
        int32_t  max;
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
        case 101011: snprintf(name, max_len, "FAMAS"); *category = 1; return;
        case 101012: snprintf(name, max_len, "ACE32"); *category = 1; return;
        case 101013: snprintf(name, max_len, "HoneyBadger"); *category = 1; return;

        /* SMGs */
        case 102001: snprintf(name, max_len, "UMP45"); *category = 1; return;
        case 102002: snprintf(name, max_len, "Micro Uzi"); *category = 1; return;
        case 102003: snprintf(name, max_len, "Vector"); *category = 1; return;
        case 102004: snprintf(name, max_len, "Tommy Gun"); *category = 1; return;
        case 102005: snprintf(name, max_len, "PP-19 Bizon"); *category = 1; return;
        case 102007: snprintf(name, max_len, "P90"); *category = 1; return;

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
        case 103011: snprintf(name, max_len, "Mosin"); *category = 1; return;
        case 103012: snprintf(name, max_len, "AMR"); *category = 1; return;
        case 103013: snprintf(name, max_len, "Mk12"); *category = 1; return;

        /* Shotguns & LMGs */
        case 104001: snprintf(name, max_len, "S686"); *category = 1; return;
        case 104002: snprintf(name, max_len, "S1897"); *category = 1; return;
        case 104003: snprintf(name, max_len, "S12K"); *category = 1; return;
        case 104004: snprintf(name, max_len, "DBS"); *category = 1; return;
        case 105001: snprintf(name, max_len, "M249"); *category = 1; return;
        case 105002: snprintf(name, max_len, "DP-28"); *category = 1; return;
        case 105010: snprintf(name, max_len, "MG3"); *category = 1; return;

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
        case 601004: snprintf(name, max_len, "EnergyDrink"); *category = 3; return;
        case 601005: snprintf(name, max_len, "Painkiller"); *category = 3; return;
        case 601006: snprintf(name, max_len, "Adrenaline"); *category = 3; return;

        /* Throwables / Grenades / Special */
        case 602001: snprintf(name, max_len, "Frag Grenade"); *category = 5; return;
        case 602002: snprintf(name, max_len, "Smoke"); *category = 5; return;
        case 602003: snprintf(name, max_len, "Molotov"); *category = 5; return;
        case 602004: snprintf(name, max_len, "Stun Grenade"); *category = 5; return;
        case 603001: snprintf(name, max_len, "Flare Gun"); *category = 5; return;
        case 504001: snprintf(name, max_len, "Air Drop"); *category = 5; return;
        case 504002: snprintf(name, max_len, "Player Crate"); *category = 5; return;

        /* Scopes & Ammo & Attachments */
        case 203001: snprintf(name, max_len, "RedDot"); *category = 4; return;
        case 203002: snprintf(name, max_len, "Holo"); *category = 4; return;
        case 203003: snprintf(name, max_len, "2x Scope"); *category = 4; return;
        case 203004: snprintf(name, max_len, "4x Scope"); *category = 4; return;
        case 203005: snprintf(name, max_len, "3x Scope"); *category = 4; return;
        case 203014: snprintf(name, max_len, "6x Scope"); *category = 4; return;
        case 203015: snprintf(name, max_len, "8x Scope"); *category = 4; return;
        case 301001: snprintf(name, max_len, "5.56 Ammo"); *category = 4; return;
        case 302001: snprintf(name, max_len, "7.62 Ammo"); *category = 4; return;
        case 303001: snprintf(name, max_len, ".300 Mag"); *category = 4; return;
        case 304001: snprintf(name, max_len, "9mm Ammo"); *category = 4; return;
        case 305001: snprintf(name, max_len, ".45 Ammo"); *category = 4; return;
        case 201009: snprintf(name, max_len, "AR Suppressor"); *category = 4; return;
        case 201010: snprintf(name, max_len, "SR Suppressor"); *category = 4; return;
        case 201011: snprintf(name, max_len, "AR Compensator"); *category = 4; return;
        case 201012: snprintf(name, max_len, "SR Compensator"); *category = 4; return;
        case 204009: snprintf(name, max_len, "AR Ext.QuickMag"); *category = 4; return;
        case 204010: snprintf(name, max_len, "SR Ext.QuickMag"); *category = 4; return;

        default: {
            int prefix = item_id / 1000;
            switch (prefix) {
                case 101: snprintf(name, max_len, "Assault Rifle"); *category = 1; return;
                case 102: snprintf(name, max_len, "SMG");           *category = 1; return;
                case 103: snprintf(name, max_len, "Sniper");        *category = 1; return;
                case 104: snprintf(name, max_len, "Shotgun");       *category = 1; return;
                case 105: snprintf(name, max_len, "LMG");           *category = 1; return;
                case 106: snprintf(name, max_len, "Pistol");        *category = 1; return;
                case 107: case 108: snprintf(name, max_len, "Special Weapon"); *category = 1; return;
                case 201: snprintf(name, max_len, "Muzzle");        *category = 4; return;
                case 202: snprintf(name, max_len, "Grip");          *category = 4; return;
                case 203: snprintf(name, max_len, "Scope");         *category = 4; return;
                case 204: snprintf(name, max_len, "Magazine");      *category = 4; return;
                case 205: snprintf(name, max_len, "Stock");         *category = 4; return;
                case 301: snprintf(name, max_len, "5.56 Ammo");     *category = 4; return;
                case 302: snprintf(name, max_len, "7.62 Ammo");     *category = 4; return;
                case 303: snprintf(name, max_len, ".300 Mag");      *category = 4; return;
                case 304: snprintf(name, max_len, "9mm Ammo");      *category = 4; return;
                case 305: snprintf(name, max_len, ".45 Ammo");      *category = 4; return;
                case 306: snprintf(name, max_len, "12 Gauge");      *category = 4; return;
                case 307: snprintf(name, max_len, "Bolt / Arrow");  *category = 4; return;
                case 501: snprintf(name, max_len, "Helmet");        *category = 2; return;
                case 502: snprintf(name, max_len, "Armor Vest");    *category = 2; return;
                case 503: snprintf(name, max_len, "Backpack");      *category = 2; return;
                case 504: snprintf(name, max_len, "Player Crate");  *category = 5; return;
                case 601: snprintf(name, max_len, "Medicine");      *category = 3; return;
                case 602: snprintf(name, max_len, "Throwable");     *category = 5; return;
                case 603: snprintf(name, max_len, "Flare Gun");     *category = 5; return;
                case 605: snprintf(name, max_len, "Shop Token");    *category = 5; return;
                default:
                    snprintf(name, max_len, "Loot Crate");
                    *category = 5;
                    return;
            }
        }
    }
}

static void resolve_item_from_actor_name(const char *aname, char *name, size_t max_len, uint8_t *category) {
    if (!aname || !aname[0]) return;
    if (strstr(aname, "Smoke")) { snprintf(name, max_len, "Smoke"); *category = 5; return; }
    if (strstr(aname, "Grenade") || strstr(aname, "Frag")) { snprintf(name, max_len, "Frag Grenade"); *category = 5; return; }
    if (strstr(aname, "Burn") || strstr(aname, "Molotov")) { snprintf(name, max_len, "Molotov"); *category = 5; return; }
    if (strstr(aname, "Flash") || strstr(aname, "Stun")) { snprintf(name, max_len, "Stun Grenade"); *category = 5; return; }
    if (strstr(aname, "Flare")) { snprintf(name, max_len, "Flare Gun"); *category = 5; return; }
    if (strstr(aname, "M416")) { snprintf(name, max_len, "M416"); *category = 1; return; }
    if (strstr(aname, "AKM")) { snprintf(name, max_len, "AKM"); *category = 1; return; }
    if (strstr(aname, "AWM")) { snprintf(name, max_len, "AWM"); *category = 1; return; }
    if (strstr(aname, "M24")) { snprintf(name, max_len, "M24"); *category = 1; return; }
    if (strstr(aname, "Kar98")) { snprintf(name, max_len, "Kar98k"); *category = 1; return; }
    if (strstr(aname, "Groza")) { snprintf(name, max_len, "Groza"); *category = 1; return; }
    if (strstr(aname, "AUG")) { snprintf(name, max_len, "AUG"); *category = 1; return; }
    if (strstr(aname, "SCAR")) { snprintf(name, max_len, "SCAR-L"); *category = 1; return; }
    if (strstr(aname, "M762")) { snprintf(name, max_len, "M762"); *category = 1; return; }
    if (strstr(aname, "Mk14")) { snprintf(name, max_len, "Mk14"); *category = 1; return; }
    if (strstr(aname, "Mini14")) { snprintf(name, max_len, "Mini14"); *category = 1; return; }
    if (strstr(aname, "SKS")) { snprintf(name, max_len, "SKS"); *category = 1; return; }
    if (strstr(aname, "SLR")) { snprintf(name, max_len, "SLR"); *category = 1; return; }
    if (strstr(aname, "VSS")) { snprintf(name, max_len, "VSS"); *category = 1; return; }
    if (strstr(aname, "UMP")) { snprintf(name, max_len, "UMP45"); *category = 1; return; }
    if (strstr(aname, "Vector")) { snprintf(name, max_len, "Vector"); *category = 1; return; }
    if (strstr(aname, "Uzi")) { snprintf(name, max_len, "Micro Uzi"); *category = 1; return; }
    if (strstr(aname, "Tommy")) { snprintf(name, max_len, "Tommy Gun"); *category = 1; return; }
    if (strstr(aname, "Bizon")) { snprintf(name, max_len, "PP-19 Bizon"); *category = 1; return; }
    if (strstr(aname, "P90")) { snprintf(name, max_len, "P90"); *category = 1; return; }
    if (strstr(aname, "DBS")) { snprintf(name, max_len, "DBS"); *category = 1; return; }
    if (strstr(aname, "S12K")) { snprintf(name, max_len, "S12K"); *category = 1; return; }
    if (strstr(aname, "S686")) { snprintf(name, max_len, "S686"); *category = 1; return; }
    if (strstr(aname, "S1897")) { snprintf(name, max_len, "S1897"); *category = 1; return; }
    if (strstr(aname, "DP28") || strstr(aname, "DP-28")) { snprintf(name, max_len, "DP-28"); *category = 1; return; }
    if (strstr(aname, "M249")) { snprintf(name, max_len, "M249"); *category = 1; return; }
    if (strstr(aname, "MG3")) { snprintf(name, max_len, "MG3"); *category = 1; return; }
    if (strstr(aname, "Helmet_3") || strstr(aname, "Helmet_Lv3")) { snprintf(name, max_len, "Helmet L3"); *category = 2; return; }
    if (strstr(aname, "Helmet_2") || strstr(aname, "Helmet_Lv2")) { snprintf(name, max_len, "Helmet L2"); *category = 2; return; }
    if (strstr(aname, "Helmet_1") || strstr(aname, "Helmet_Lv1")) { snprintf(name, max_len, "Helmet L1"); *category = 2; return; }
    if (strstr(aname, "Armor_3") || strstr(aname, "Vest_3")) { snprintf(name, max_len, "Vest L3"); *category = 2; return; }
    if (strstr(aname, "Armor_2") || strstr(aname, "Vest_2")) { snprintf(name, max_len, "Vest L2"); *category = 2; return; }
    if (strstr(aname, "Armor_1") || strstr(aname, "Vest_1")) { snprintf(name, max_len, "Vest L1"); *category = 2; return; }
    if (strstr(aname, "Bag_3") || strstr(aname, "Backpack_3")) { snprintf(name, max_len, "Bag L3"); *category = 2; return; }
    if (strstr(aname, "Bag_2") || strstr(aname, "Backpack_2")) { snprintf(name, max_len, "Bag L2"); *category = 2; return; }
    if (strstr(aname, "Bag_1") || strstr(aname, "Backpack_1")) { snprintf(name, max_len, "Bag L1"); *category = 2; return; }
    if (strstr(aname, "FirstAid")) { snprintf(name, max_len, "FirstAid"); *category = 3; return; }
    if (strstr(aname, "MedKit")) { snprintf(name, max_len, "MedKit"); *category = 3; return; }
    if (strstr(aname, "Drink")) { snprintf(name, max_len, "EnergyDrink"); *category = 3; return; }
    if (strstr(aname, "Pain")) { snprintf(name, max_len, "Painkiller"); *category = 3; return; }
    if (strstr(aname, "Adrenaline")) { snprintf(name, max_len, "Adrenaline"); *category = 3; return; }
    if (strstr(aname, "Bandage")) { snprintf(name, max_len, "Bandage"); *category = 3; return; }
    if (strstr(aname, "8x") || strstr(aname, "Scope8x")) { snprintf(name, max_len, "8x Scope"); *category = 4; return; }
    if (strstr(aname, "6x") || strstr(aname, "Scope6x")) { snprintf(name, max_len, "6x Scope"); *category = 4; return; }
    if (strstr(aname, "4x") || strstr(aname, "Scope4x")) { snprintf(name, max_len, "4x Scope"); *category = 4; return; }
    if (strstr(aname, "3x") || strstr(aname, "Scope3x")) { snprintf(name, max_len, "3x Scope"); *category = 4; return; }
    if (strstr(aname, "2x") || strstr(aname, "Scope2x")) { snprintf(name, max_len, "2x Scope"); *category = 4; return; }
    if (strstr(aname, "RedDot")) { snprintf(name, max_len, "RedDot"); *category = 4; return; }
    if (strstr(aname, "Holo")) { snprintf(name, max_len, "Holo"); *category = 4; return; }
    if (strstr(aname, "556") || strstr(aname, "5.56")) { snprintf(name, max_len, "5.56 Ammo"); *category = 4; return; }
    if (strstr(aname, "762") || strstr(aname, "7.62")) { snprintf(name, max_len, "7.62 Ammo"); *category = 4; return; }
    if (strstr(aname, "300") || strstr(aname, "Magnum")) { snprintf(name, max_len, ".300 Mag"); *category = 4; return; }
    if (strstr(aname, "9mm")) { snprintf(name, max_len, "9mm Ammo"); *category = 4; return; }
    if (strstr(aname, "45")) { snprintf(name, max_len, ".45 Ammo"); *category = 4; return; }
    if (strstr(aname, "AirDrop") || strstr(aname, "DropBox")) { snprintf(name, max_len, "Air Drop"); *category = 5; return; }
    if (strstr(aname, "DeadBox") || strstr(aname, "PlayerDeadBox") || strstr(aname, "PickUpListWrapperActor")) {
        snprintf(name, max_len, "Player Crate"); *category = 5; return;
    }
}

static void resolve_vehicle_name(const char *cls_name, char *name, size_t max_len) {
    if (!cls_name || !cls_name[0]) { snprintf(name, max_len, "Vehicle"); return; }
    if (strstr(cls_name, "Airplane") || strstr(cls_name, "AirDropPlane") || strstr(cls_name, "C130") || strstr(cls_name, "Plane")) {
        snprintf(name, max_len, "Airplane");
    } else if (strstr(cls_name, "Glider") || strstr(cls_name, "MotorGlider")) {
        snprintf(name, max_len, "Glider");
    } else if (strstr(cls_name, "Helicopter") || strstr(cls_name, "Heli")) {
        snprintf(name, max_len, "Helicopter");
    } else if (strstr(cls_name, "Buggy")) snprintf(name, max_len, "Buggy");
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

static cls_type_t classify_class(uint64_t cls, uint64_t actor_sample) {
    if (!cls) return CLS_IGNORE;
    for (uint32_t i = 0; i < g_class_count; i++) {
        if (g_classes[i].class_ptr == cls) return g_classes[i].type;
    }

    char name[128] = {0};
    if (reflection && !ue4r_resolve_name(reflection, cls + OFF_UOBJECT_NAME, name, sizeof(name))) {
        if (actor_sample) ue4r_resolve_name(reflection, actor_sample + OFF_UOBJECT_NAME, name, sizeof(name));
    }

    cls_type_t type = CLS_IGNORE;
    if ((strstr(name, "Character") || strstr(name, "PlayerPawn")) &&
        !strstr(name, "Controller") && !strstr(name, "Start") &&
        !strstr(name, "State") && !strstr(name, "Camera") &&
        !strstr(name, "AISpawner") && !strstr(name, "Movement") &&
        !strstr(name, "AnimInstance")) {
        type = CLS_PLAYER;
    } else if (strstr(name, "Vehicle") || strstr(name, "VH_") || strstr(name, "Buggy") ||
               strstr(name, "Dacia") || strstr(name, "UAZ") || strstr(name, "Motorcycle") ||
               strstr(name, "Bike") || strstr(name, "Boat") || strstr(name, "PickUp_") ||
               strstr(name, "Airplane") || strstr(name, "Plane") || strstr(name, "Glider") ||
               strstr(name, "Helicopter") || strstr(name, "C130")) {
        if (!strstr(name, "Wheel") && !strstr(name, "Movement") && !strstr(name, "Anim") && !strstr(name, "Spawner") && !strstr(name, "Manager")) {
            type = CLS_VEHICLE;
        }
    } else if (strstr(name, "PickUp") || strstr(name, "Wrapper")) {
        if (!strstr(name, "Destructible") && !strstr(name, "Component")) {
            type = CLS_ITEM;
        }
    } else {
        /* Check super class at 0x30 */
        uint64_t super_cls = ptr(cls, 0x30);
        char sname[128] = {0};
        if (super_cls && reflection && ue4r_resolve_name(reflection, super_cls + OFF_UOBJECT_NAME, sname, sizeof(sname))) {
            if ((strstr(sname, "Character") || strstr(sname, "PlayerPawn")) &&
                !strstr(sname, "Controller") && !strstr(sname, "Start") &&
                !strstr(sname, "State") && !strstr(sname, "Camera")) {
                type = CLS_PLAYER;
            } else if (strstr(sname, "Vehicle") || strstr(sname, "VH_") ||
                       strstr(sname, "Airplane") || strstr(sname, "Plane") || strstr(sname, "Glider")) {
                if (!strstr(sname, "Wheel") && !strstr(sname, "Movement") && !strstr(sname, "Anim")) {
                    type = CLS_VEHICLE;
                }
            } else if (strstr(sname, "PickUp") || strstr(sname, "Wrapper")) {
                type = CLS_ITEM;
            }
        }
    }

    if (g_class_count < CLASS_CACHE_SIZE) {
        uint32_t slot = g_class_count++;
        g_classes[slot].class_ptr = cls;
        g_classes[slot].type = type;
        snprintf(g_classes[slot].name, sizeof(g_classes[slot].name), "%s", name);
    }
    return type;
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
    if (logfile && status == 2 && !first_live) {
        first_live = true;
        fprintf(logfile, "STARTUP first_live_ms=%.1f tick=%u players=%u camera=%u\n", (now_seconds()-started_at)*1000, tick, frame.header.player_count, frame.header.camera_valid);
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
                g_class_count = 0;
                g_player_meta_count = 0;
                g_item_meta_count = 0;
            }
            world = current;
            return world;
        }
        local_player = 0;
    }
    world = 0;
    double now = now_seconds();
    if (now < next_lookup) return 0;
    next_lookup = now + 0.50;
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
        next_lookup = now + 0.50;
        return 0;
    }

    /* Fast batched search for LocalPlayer */
    for (int b = 0; b < 16 && world_cursor >= 0; b++) {
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
                break;
            }
        }
    }
    return world;
}

/* Fast scan of PersistentLevel Actors array with batched pointer read */
static bool scan_persistent_level(uint64_t w) {
    uint64_t level = ptr(w, 0x30);
    if (!level) return false;

    static const uint64_t offsets[] = { 0xa0, 0xb0, 0x98, 0xa8, 0x90, 0x70 };
    uint64_t data = 0;
    int32_t count = 0;
    bool found_arr = false;
    for (size_t o = 0; o < sizeof(offsets)/sizeof(offsets[0]); o++) {
        if (array(level, offsets[o], &data, &count, 8192) && count >= 5) {
            found_arr = true;
            break;
        }
    }
    if (!found_arr || !data || count < 5) return false;

    uint64_t new_chars[512];
    unsigned new_char_cnt = 0;
    uint64_t new_vehs[64];
    unsigned new_veh_cnt = 0;
    uint64_t new_items[256];
    unsigned new_item_cnt = 0;

    /* Batch read actor pointers in chunks of 512 */
    uint64_t actor_chunk[512];
    for (int start = 0; start < count; start += 512) {
        int chunk_size = count - start;
        if (chunk_size > 512) chunk_size = 512;
        if (!rm_read(task, data + (uint64_t)start * 8, actor_chunk, chunk_size * sizeof(uint64_t))) {
            continue;
        }
        for (int i = 0; i < chunk_size; i++) {
            uint64_t actor = actor_chunk[i];
            if (!rm_validate_ptr(actor)) continue;
            uint64_t cls = ptr(actor, 0x10);
            if (!cls) continue;

            cls_type_t t = classify_class(cls, actor);
            if (t == CLS_PLAYER && new_char_cnt < 512) {
                new_chars[new_char_cnt++] = actor;
            } else if (t == CLS_VEHICLE && new_veh_cnt < 64) {
                new_vehs[new_veh_cnt++] = actor;
            } else if (t == CLS_ITEM && new_item_cnt < 256) {
                new_items[new_item_cnt++] = actor;
            }
        }
    }

    memcpy(characters, new_chars, new_char_cnt * sizeof(uint64_t));
    character_count = new_char_cnt;
    memcpy(vehicles, new_vehs, new_veh_cnt * sizeof(uint64_t));
    vehicle_count = new_veh_cnt;
    memcpy(items, new_items, new_item_cnt * sizeof(uint64_t));
    item_count = new_item_cnt;
    return true;
}

int radar_init(mach_port_t target, uint64_t image_base, uint64_t aslr_slide) {
    local_player = 0;
    started_at = now_seconds();
    first_live = false;
    task = target;
    base = image_base;
    slide = aslr_slide;
    world = 0;
    tick = 0;
    next_lookup = 0;
    last_status = UINT32_MAX;
    world_cursor = 0;
    character_count = 0;
    vehicle_count = 0;
    item_count = 0;
    next_scan_time = 0;
    g_class_count = 0;
    g_player_meta_count = 0;
    g_item_meta_count = 0;
    s_cached_local_team = 0;

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
    if (pawn || pc) {
        uint64_t local_st = 0;
        if (pawn) {
            local_st = ptr(pawn, 0x2410);
            if (!local_st) local_st = ptr(pawn, 0x4d0);
        }
        if (!local_st && pc) {
            local_st = ptr(pc, 0x488);
            if (!local_st) local_st = ptr(pc, 0x4f0);
            if (!local_st) local_st = ptr(pc, 0x500);
            if (!local_st) local_st = ptr(pc, 0x508);
        }
        if (local_st) {
            uint32_t t = 0;
            if (rm_read(task, local_st + 0x700, &t, 4) && t > 0) {
                frame.header.local_team = t;
                s_cached_local_team = t;
            }
        }
    }
    if (frame.header.local_team == 0 && s_cached_local_team > 0) {
        frame.header.local_team = s_cached_local_team;
    }

    /* Actor discovery cadence */
    double now = now_seconds();
    if (now >= next_scan_time) {
        next_scan_time = now + 1.25; /* 1.25s discovery cadence — eliminates CPU hogging and thermal panics */
        scan_persistent_level(world);
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

        /* Filter out unspawned or dummy actors at world origin (0,0,0) */
        if (fabsf(p.pos.x) < 1.0f && fabsf(p.pos.y) < 1.0f && fabsf(p.pos.z) < 1.0f) continue;

        /* Check dead flag on character (STExtraCharacter + 0xe7c) */
        uint8_t b_dead = 0;
        rm_read(task, other + 0xe7c, &b_dead, 1);
        if (b_dead) continue;

        uint64_t st = ptr(other, 0x2410);
        if (!st) st = ptr(other, 0x4d0);

        /* Dual-source health: STExtraCharacter + 0xe60 / 0xe64, fallback to STExtraPlayerState + 0x142c / 0x1430 */
        float hp = 0.0f, hp_max = 0.0f;
        rm_read(task, other + 0xe60, &hp, 4);
        rm_read(task, other + 0xe64, &hp_max, 4);
        if (!isfinite(hp) || hp <= 0.0f || !isfinite(hp_max) || hp_max <= 0.0f) {
            if (st) {
                float st_hp = 0.0f, st_hp_max = 0.0f;
                rm_read(task, st + 0x142c, &st_hp, 4);
                rm_read(task, st + 0x1430, &st_hp_max, 4);
                if (isfinite(st_hp) && st_hp > 0.0f) hp = st_hp;
                if (isfinite(st_hp_max) && st_hp_max > 0.0f) hp_max = st_hp_max;
            }
        }

        if (!isfinite(hp) || hp < 0.0f) hp = 0.0f;
        if (!isfinite(hp_max) || hp_max <= 0.0f || hp_max > 10000.0f) hp_max = 100.0f;
        if (hp > hp_max) hp_max = hp;
        p.health = hp;
        p.health_max = hp_max;

        rm_read(task, other + 0x2be8, &p.health_status, 1);
        if (p.health_status == 2) continue; /* Dead */

        rvec3_t rot;
        if (vec(ptr(other, 0x208), 0x1f0, &rot)) p.yaw = rot.y;

        /* Cached player metadata (team, bot, name) to eliminate redundant IPC reads */
        const player_meta_cache_t *pmeta = find_player_meta(other);
        if (pmeta) {
            p.team_id = pmeta->team_id;
            p.is_bot = pmeta->is_bot;
            memcpy(p.name, pmeta->name, sizeof(p.name));
        } else {
            /* Team and bot */
            if (st) {
                rm_read(task, st + 0x700, &p.team_id, 4);
                uint8_t raw_bot = 0;
                rm_read(task, st + 0x4dc, &raw_bot, 1);
                /* In UE4 PlayerState at offset 1244 (0x4dc), bit 2 (0x04) is bIsABot.
                 * Bit 3 (0x08) is bIsInactive, bit 4 (0x10) is bFromPreviousLevel.
                 * Only bit 2 indicates an AI bot. */
                p.is_bot = (raw_bot & 0x04) ? 1 : 0;

                /* Critical Invariant: Teammates on our team can NEVER be classified as bots */
                if (frame.header.local_team != 0 && p.team_id == frame.header.local_team) {
                    p.is_bot = 0;
                }

                /* Player Name */
                if (!read_fstring(task, st + 0x4b8, p.name, sizeof(p.name))) {
                    if (!read_fstring(task, st + 0x13e0, p.name, sizeof(p.name))) {
                        if (p.is_bot) snprintf(p.name, sizeof(p.name), "Bot");
                        else snprintf(p.name, sizeof(p.name), "Player");
                    }
                }
            } else {
                snprintf(p.name, sizeof(p.name), "Player");
            }
            /* Critical Invariant: Teammates on our team can NEVER be classified as bots */
            if (frame.header.local_team != 0 && p.team_id == frame.header.local_team) {
                p.is_bot = 0;
            }
            store_player_meta(other, p.team_id, p.is_bot, p.name);
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
        p.bones[12] = (rvec3_t){ p.bones[11].x, p.bones[11].y, p.bones[11].z - 43.0f };                     /* L Ankle */
        /* Right leg */
        p.bones[13] = (rvec3_t){ p.pos.x + right_x * 12.0f, p.pos.y + right_y * 12.0f, p.pos.z + 0.0f };  /* R Hip */
        p.bones[14] = (rvec3_t){ p.bones[13].x, p.bones[13].y, p.bones[13].z - 42.0f };                     /* R Knee */
        p.bones[15] = (rvec3_t){ p.bones[14].x, p.bones[14].y, p.bones[14].z - 43.0f };                     /* R Ankle */
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
        if (v.distance > 800.0f) continue; /* Skip vehicles beyond 800m */

        float fwd_speed = 0.0f;
        rm_read(task, vactor + 0xcd0, &fwd_speed, 4);
        v.speed = fabsf(fwd_speed) * 0.036f;

        rm_read(task, vactor + 0x18c9, &v.health_state, 1);
        rm_read(task, vactor + 0x1978, &v.can_boost, 1);
        rm_read(task, vactor + 0x1574, &v.team_id, 1);

        char cls_buf[128] = {0};
        uint64_t cls = ptr(vactor, 0x10);
        for (uint32_t c = 0; c < g_class_count; c++) {
            if (g_classes[c].class_ptr == cls) {
                snprintf(cls_buf, sizeof(cls_buf), "%s", g_classes[c].name);
                break;
            }
        }
        if (!cls_buf[0] && cls && reflection) {
            ue4r_resolve_name(reflection, cls + OFF_UOBJECT_NAME, cls_buf, sizeof(cls_buf));
        }
        resolve_vehicle_name(cls_buf, v.name, sizeof(v.name));

        /* Mark air vehicles with can_boost = 1 so overlay can filter them */
        if (strstr(v.name, "Airplane") || strstr(v.name, "Glider") || strstr(v.name, "Helicopter")) {
            v.can_boost = 1;
        }

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

        /* Fast cached item resolution to avoid per-frame GNamePool reflection lookups */
        const item_meta_cache_t *imeta = find_item_meta(iactor);
        if (imeta) {
            item.item_id = imeta->item_id;
            item.category = imeta->category;
            memcpy(item.name, imeta->name, sizeof(item.name));
            rm_read(task, iactor + 0x610, &item.count, 4);
            if (item.count <= 0) item.count = 1;
        } else {
            /* Enhanced multi-offset ItemId resolution for PickUpWrapperActor & PickUpListWrapperActor */
            rm_read(task, iactor + 0x758, &item.item_id, 4);  /* Primary ItemId (1880) */
            if (item.item_id <= 0) {
                rm_read(task, iactor + 1528, &item.item_id, 4); /* DefineID struct TypeSpecificID (1528 / 0x5F8) */
            }
            if (item.item_id <= 0) {
                /* PickUpListWrapperActor: read PickUpDataList TArray at offset 2408 (0x968) */
                uint64_t list_data = ptr(iactor, 2408);
                if (list_data) {
                    rm_read(task, list_data, &item.item_id, 4);
                }
            }
            rm_read(task, iactor + 0x610, &item.count, 4);
            if (item.count <= 0) item.count = 1;

            item.name[0] = '\0';
            if (item.item_id > 0) {
                resolve_item_info(item.item_id, item.name, sizeof(item.name), &item.category);
            }

            /* If item name is unresolved or generic, resolve via actor name, class name, and PickupMesh */
            if (item.name[0] == '\0' || strncmp(item.name, "Item", 4) == 0 || strcmp(item.name, "Loot Crate") == 0) {
                char aname[128] = {0};
                if (reflection && ue4r_resolve_name(reflection, iactor + OFF_UOBJECT_NAME, aname, sizeof(aname))) {
                    resolve_item_from_actor_name(aname, item.name, sizeof(item.name), &item.category);
                }
                if (item.name[0] == '\0' || strncmp(item.name, "Item", 4) == 0 || strcmp(item.name, "Loot Crate") == 0) {
                    uint64_t acls = ptr(iactor, 0x10);
                    if (acls && reflection && ue4r_resolve_name(reflection, acls + OFF_UOBJECT_NAME, aname, sizeof(aname))) {
                        resolve_item_from_actor_name(aname, item.name, sizeof(item.name), &item.category);
                    }
                }
                if (item.name[0] == '\0' || strncmp(item.name, "Item", 4) == 0 || strcmp(item.name, "Loot Crate") == 0) {
                    uint64_t pmesh = ptr(iactor, 1816); /* PickupMesh (0x718) */
                    if (pmesh && reflection && ue4r_resolve_name(reflection, pmesh + OFF_UOBJECT_NAME, aname, sizeof(aname))) {
                        resolve_item_from_actor_name(aname, item.name, sizeof(item.name), &item.category);
                    }
                }
            }
            if (item.name[0] == '\0') {
                snprintf(item.name, sizeof(item.name), "Supply");
                item.category = 5;
            }
            store_item_meta(iactor, item.item_id, item.category, item.name);
        }

        frame.items[frame.header.item_count++] = item;
    }

    if (logfile && tick % 200 == 0) {
        fprintf(logfile, "radar_tick: players=%u vehicles=%u items=%u world=0x%llx cached_classes=%u\n",
            frame.header.player_count, frame.header.vehicle_count, frame.header.item_count, world, g_class_count);
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
    s_cached_local_team = 0;
}
