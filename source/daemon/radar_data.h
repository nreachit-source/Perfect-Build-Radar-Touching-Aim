/*
 * radar_data.h — Shared binary format between daemon and overlay.
 *
 * The daemon writes this structure to a memory-mapped file; the
 * overlay reads it for rendering.  Both sides include this header.
 */

#ifndef RADAR_DATA_H
#define RADAR_DATA_H

#include <stdint.h>

#define RADAR_FILE_PATH   "/var/mobile/Downloads/ue4_radar.bin"
#define RADAR_MAGIC       0x52444152  /* "RDAR" */
#define RADAR_VERSION     1
#define RADAR_MAX_PLAYERS 100
#define RADAR_NUM_BONES   20

typedef struct {
    float x, y, z;
} rvec3_t;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t tick;
    uint32_t player_count;
    rvec3_t  local_pos;
    rvec3_t  local_rot;   /* pitch, yaw, roll (degrees) */
    float    camera_fov;
    float    _pad[3];
} radar_header_t;

typedef struct {
    rvec3_t  pos;
    float    health;
    float    health_max;
    float    yaw;
    uint8_t  team_id;
    uint8_t  is_bot;
    uint8_t  is_visible;
    uint8_t  health_status;  /* 0=alive 1=knocked 2=dead */
    uint8_t  has_bones;
    uint8_t  _pad[3];
    rvec3_t  bones[RADAR_NUM_BONES];
} radar_player_t;

typedef struct {
    radar_header_t header;
    radar_player_t players[RADAR_MAX_PLAYERS];
} radar_shared_t;

#endif /* RADAR_DATA_H */
