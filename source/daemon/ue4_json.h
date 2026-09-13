/*
 * ue4_json.h — Minimal JSON serializer for the UE4 schema output.
 *
 * Produces the same schema format as the internal UE4SchemaExporter:
 * {
 *   "format": "ue4-reflection-schema-v1",
 *   "scope": "type metadata only; no object values",
 *   "classes": [ ... ]
 * }
 */

#ifndef UE4_JSON_H
#define UE4_JSON_H

#include "ue4_reflection.h"

/* Serialize the class list to JSON and write it to `path`.
 * Returns 0 on success, -1 on failure. */
int ue4j_write(const char *path, const ue4_class_t *classes);

#endif /* UE4_JSON_H */
