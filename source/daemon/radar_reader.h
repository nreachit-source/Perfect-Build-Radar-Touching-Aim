/*
 * radar_reader.h — Live player data reader for the radar.
 */

#ifndef RADAR_READER_H
#define RADAR_READER_H

#include <mach/mach.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

/* Initialise the radar reader.  Call once after SDK generation.
 * Returns 0 on success, -1 on failure. */
int radar_init(mach_port_t task, uint64_t image_base, uint64_t slide);

/* Perform one tick: read all player data from the game process
 * and update the shared memory file.  Call at ~20 Hz. */
int radar_tick(void);

/* Clean up resources. */
void radar_destroy(void);

#endif /* RADAR_READER_H */
