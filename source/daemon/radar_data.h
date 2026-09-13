/*
 * radar_data.h — Shared binary format between daemon and overlay.
 *
 * The daemon writes this structure to a memory-mapped file; the
 * overlay reads it for rendering.  Both sides include this header.
 */

#ifndef RADAR_DATA_H
#define RADAR_DATA_H

#include <stdint.h>

#define RADAR_FILE_PATH     "/var/mobile/Downloads/ue4_radar.bin"
#define RADAR_MAGIC         0x52444152  /* "RDAR" */
#define RADAR_VERSION       4
#define RADAR_MAX_PLAYERS   100
#define RADAR_MAX_VEHICLES  30
#define RADAR_MAX_ITEMS     60
#define RADAR_NUM_BONES     16

typedef struct {
    float x, y, z;
} rvec3_t;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t tick;
    uint32_t player_count;
    uint32_t vehicle_count;
    uint32_t item_count;
    rvec3_t  local_pos;
    rvec3_t  local_rot;   /* pitch, yaw, roll (degrees) */
    float    camera_fov;
    uint32_t sequence;    /* odd while writer is publishing */
    uint32_t status;      /* 0 offline, 1 initializing, 2 ready, 3 no local pawn */
    rvec3_t  camera_pos;
    uint32_t camera_valid;
    uint32_t local_team;  /* 0 means unknown */
    float    screen_width;
    float    screen_height;
} radar_header_t;

typedef struct {
    rvec3_t  pos;
    float    health;
    float    health_max;
    float    yaw;
    uint32_t team_id;
    uint8_t  is_bot;
    uint8_t  is_visible;
    uint8_t  health_status;  /* 0=alive 1=knocked 2=dead */
    uint8_t  has_bones;
    char     name[32];
    float    distance;
    rvec3_t  head_pos;
    rvec3_t  feet_pos;
    rvec3_t  bones[RADAR_NUM_BONES];
} radar_player_t;

typedef struct {
    rvec3_t  pos;
    float    distance;
    float    speed;
    uint8_t  health_state;
    uint8_t  can_boost;
    uint8_t  team_id;
    uint8_t  _pad;
    char     name[32];
} radar_vehicle_t;

typedef struct {
    rvec3_t  pos;
    float    distance;
    int32_t  item_id;
    int32_t  count;
    uint8_t  category; /* 1=Weapon, 2=Armor, 3=Med, 4=Ammo, 5=Crate/Other */
    uint8_t  _pad[3];
    char     name[32];
} radar_item_t;

typedef struct {
    radar_header_t  header;
    radar_player_t  players[RADAR_MAX_PLAYERS];
    radar_vehicle_t vehicles[RADAR_MAX_VEHICLES];
    radar_item_t    items[RADAR_MAX_ITEMS];
} radar_shared_t;

_Static_assert(sizeof(radar_header_t) == 88, "radar_header_t ABI");
_Static_assert(sizeof(radar_player_t) == 284, "radar_player_t ABI");
_Static_assert(sizeof(radar_vehicle_t) == 56, "radar_vehicle_t ABI");
_Static_assert(sizeof(radar_item_t) == 60, "radar_item_t ABI");
_Static_assert(sizeof(radar_shared_t) == 33768, "radar_shared_t ABI");

#endif /* RADAR_DATA_H */
