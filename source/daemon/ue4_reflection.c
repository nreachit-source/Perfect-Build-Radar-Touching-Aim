/*
 * ue4_reflection.c — UE4 reflection system introspection (read-only)
 *
 * Walks the remote process's GUObjectArray and FNamePool to enumerate
 * UClass objects and extract their property/function metadata.
 * All memory access is read-only via Mach VM APIs (rm_read_*).
 *
 * Targets: ARM64 / iOS (jailbroken), UE 4.23–4.27
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <mach/mach.h>

#include "ue4_reflection.h"
#include "remote_memory.h"
#include "pattern_scan.h"
#include "ue4_offsets.h"

/* -----------------------------------------------------------------------
 * FNamePool layout constants (common for UE 4.25–4.27, may need tuning)
 * ----------------------------------------------------------------------- */
#define FNAMEPOOL_BLOCKS_OFFSET  0x40   /* Byte offset to the block pointer array inside FNamePool */
#define FNAME_ENTRY_STRIDE       2      /* Entries are 2-byte aligned; offset counts in stride-2 units */

/* Safety caps to prevent runaway iteration */
#define MAX_OBJECTS         500000
#define MAX_LIST_WALK       1000
#define MAX_PATH_DEPTH      10
#define MAX_INIT_SCAN_OBJS  512     /* How many objects to scan when looking for the "Class" UClass */

/* -----------------------------------------------------------------------
 * Context
 * ----------------------------------------------------------------------- */
struct ue4r_ctx {
    mach_port_t task;
    uint64_t    image_base;
    uint64_t    slide;
    uint64_t    guobjectarray;  /* Runtime address of GUObjectArray               */
    uint64_t    gnamepool;      /* Runtime address of FNamePool (GNames)          */
    uint64_t    uclass_class;   /* Address of the UClass whose name is "Class"    */
};

/* -----------------------------------------------------------------------
 * Forward declarations (private helpers)
 * ----------------------------------------------------------------------- */
static uint64_t try_find_guobjectarray(mach_port_t task, uint64_t image_base, uint64_t slide);
static uint64_t try_find_gnamepool   (mach_port_t task, uint64_t image_base, uint64_t slide);

static bool resolve_object_name(ue4r_ctx_t *ctx, uint64_t obj_addr,
                                char *buf, size_t max);
static void build_path_name    (ue4r_ctx_t *ctx, uint64_t obj_addr,
                                char *buf, size_t max, int depth);

static ue4_property_t *read_properties(ue4r_ctx_t *ctx, uint64_t class_addr);
static ue4_function_t *read_functions (ue4r_ctx_t *ctx, uint64_t class_addr);

/* =======================================================================
 * Auto-detection helpers (pattern scan stubs)
 * ======================================================================= */

/*
 * try_find_guobjectarray
 *
 * Attempt to locate GUObjectArray by scanning the __DATA segment for
 * ADRP+LDR instruction sequences that reference the global.
 * Returns the runtime address, or 0 on failure.
 */
static uint64_t try_find_guobjectarray(mach_port_t task,
                                       uint64_t image_base,
                                       uint64_t slide)
{
    /*
     * A proper implementation would use pat_scan_segment() on "__DATA"
     * with a byte pattern derived from the ADRP/ADD or ADRP/LDR pair
     * that references FUObjectArray::ObjObjects.
     *
     * For now this is a placeholder — callers should supply the offset
     * explicitly via guobj_off.
     */
    (void)task;
    (void)image_base;
    (void)slide;

    fprintf(stderr, "[ue4r] auto-detect GUObjectArray: not implemented, "
                    "please supply offset explicitly\n");
    return 0;
}

/*
 * try_find_gnamepool
 *
 * Attempt to locate FNamePool (GNames) via pattern scanning.
 * Returns the runtime address, or 0 on failure.
 */
static uint64_t try_find_gnamepool(mach_port_t task,
                                   uint64_t image_base,
                                   uint64_t slide)
{
    (void)task;
    (void)image_base;
    (void)slide;

    fprintf(stderr, "[ue4r] auto-detect FNamePool: not implemented, "
                    "please supply offset explicitly\n");
    return 0;
}

/* =======================================================================
 * FName resolution — FNamePool block-based system (UE 4.23+)
 * ======================================================================= */

bool ue4r_resolve_name(ue4r_ctx_t *ctx, uint64_t fname_addr,
                       char *buf, size_t max)
{
    if (!ctx || !buf || max == 0) return false;
    buf[0] = '\0';

    if (!rm_validate_ptr(fname_addr)) return false;

    /* 1. Read the 8-byte FName struct (ComparisonIndex + Number) */
    bool ok = false;
    int32_t comp_index = rm_read_i32(ctx->task,
                                     fname_addr + OFF_FNAME_INDEX, &ok);
    if (!ok) return false;

    int32_t number = rm_read_i32(ctx->task,
                                 fname_addr + OFF_FNAME_NUMBER, &ok);
    if (!ok) return false;

    /* 2. Decode block index and offset within the block */
    uint32_t block_index    = (uint32_t)comp_index >> FNAME_BLOCK_OFFSET_BITS;
    uint32_t offset_in_block = (uint32_t)comp_index &
                               ((1u << FNAME_BLOCK_OFFSET_BITS) - 1u);

    /* 3. Read the block pointer from the FNamePool block array */
    uint64_t block_array_addr = ctx->gnamepool + FNAMEPOOL_BLOCKS_OFFSET;
    uint64_t block_ptr = rm_read_ptr(ctx->task,
                                     block_array_addr + (uint64_t)block_index * 8);
    if (!rm_validate_ptr(block_ptr)) return false;

    /* 4. Compute the entry address (offset counts in stride-2 units) */
    uint64_t entry_addr = block_ptr +
                          (uint64_t)offset_in_block * FNAME_ENTRY_STRIDE;

    /* 5. Read the FNameEntry header (uint16) */
    uint16_t header = rm_read_u16(ctx->task, entry_addr, &ok);
    if (!ok) return false;

    /* 6. Decode wide flag and string length */
    bool is_wide = (header & FNAMEENTRY_HEADER_WIDE_MASK) != 0;
    uint16_t len = header >> FNAMEENTRY_HEADER_LEN_SHIFT;

    /* Sanity-check length */
    if (len == 0 || len > 1024) return false;

    uint64_t str_addr = entry_addr + FNAMEENTRY_HEADER_SIZE;

    /* 7. Temporary buffer for the raw name chars */
    size_t name_cap = (len < max - 1) ? len : (max - 1);
    char name_buf[1024];
    if (name_cap > sizeof(name_buf) - 1)
        name_cap = sizeof(name_buf) - 1;

    if (!is_wide) {
        /* ANSI path: read `len` bytes directly */
        if (!rm_read(ctx->task, str_addr, name_buf, name_cap))
            return false;
        name_buf[name_cap] = '\0';
    } else {
        /* Wide (UTF-16LE) path: read len * 2 bytes, take low byte of each */
        size_t wide_bytes = (size_t)len * 2;
        uint8_t wide_buf[2048];
        if (wide_bytes > sizeof(wide_buf))
            wide_bytes = sizeof(wide_buf);
        if (!rm_read(ctx->task, str_addr, wide_buf, wide_bytes))
            return false;

        size_t copy_len = (size_t)len;
        if (copy_len > name_cap) copy_len = name_cap;
        for (size_t i = 0; i < copy_len; i++)
            name_buf[i] = (char)wide_buf[i * 2]; /* low byte of each wchar */
        name_buf[copy_len] = '\0';
    }

    /* 8. Append "_N" suffix when Number > 0  (Number is stored as N+1) */
    if (number > 0) {
        char suffix[32];
        snprintf(suffix, sizeof(suffix), "_%d", number - 1);
        size_t nlen = strlen(name_buf);
        size_t slen = strlen(suffix);
        if (nlen + slen < sizeof(name_buf)) {
            memcpy(name_buf + nlen, suffix, slen + 1);
        }
    }

    /* 9. Copy to caller buffer */
    snprintf(buf, max, "%s", name_buf);
    return true;
}

/* =======================================================================
 * Object name helpers
 * ======================================================================= */

/*
 * resolve_object_name — read a UObject's FName and resolve it.
 */
static bool resolve_object_name(ue4r_ctx_t *ctx, uint64_t obj_addr,
                                char *buf, size_t max)
{
    if (!rm_validate_ptr(obj_addr)) {
        if (max > 0) buf[0] = '\0';
        return false;
    }
    return ue4r_resolve_name(ctx, obj_addr + OFF_UOBJECT_NAME, buf, max);
}

/*
 * build_path_name — recursively build a UE4-style path name by following
 * the OuterPrivate chain.
 *
 * Result format mirrors UObject::GetPathName():
 *   /PackageName.ObjectName        (for classes)
 *   /PackageName/SubPkg.Object     (nested)
 *
 * The separator between a package (outermost object with no outer) and its
 * children is "."; deeper nesting also uses ".".
 */
static void build_path_name(ue4r_ctx_t *ctx, uint64_t obj_addr,
                            char *buf, size_t max, int depth)
{
    if (!buf || max == 0) return;
    buf[0] = '\0';

    if (depth > MAX_PATH_DEPTH) {
        snprintf(buf, max, "...");
        return;
    }
    if (!rm_validate_ptr(obj_addr)) {
        snprintf(buf, max, "<null>");
        return;
    }

    /* Resolve this object's own name */
    char name[256];
    if (!resolve_object_name(ctx, obj_addr, name, sizeof(name)))
        snprintf(name, sizeof(name), "<unknown>");

    /* Read OuterPrivate */
    uint64_t outer = rm_read_ptr(ctx->task, obj_addr + OFF_UOBJECT_OUTER);

    if (rm_validate_ptr(outer)) {
        /* Build the outer's path first */
        char outer_path[512];
        build_path_name(ctx, outer, outer_path, sizeof(outer_path), depth + 1);

        /*
         * Determine separator:
         *   If outer has no outer itself (i.e. it is a top-level package),
         *   use "." between the package path and this object's name.
         *   Otherwise use "." as well (matches GetPathName behaviour for
         *   sub-objects).
         */
        snprintf(buf, max, "%s.%s", outer_path, name);
    } else {
        /* No outer — this is a top-level package */
        snprintf(buf, max, "/%s", name);
    }
}

/* =======================================================================
 * Property & Function list readers
 * ======================================================================= */

/*
 * read_properties — walk the FProperty linked list starting at
 * UStruct::ChildProperties.
 *
 * FProperty uses the FField layout (OFF_FFIELD_*) rather than UObject.
 */
static ue4_property_t *read_properties(ue4r_ctx_t *ctx, uint64_t class_addr)
{
    uint64_t prop_ptr = rm_read_ptr(ctx->task,
                                    class_addr + OFF_USTRUCT_CHILD_PROPS);

    ue4_property_t *head = NULL;
    ue4_property_t *tail = NULL;
    int count = 0;

    while (rm_validate_ptr(prop_ptr) && count < MAX_LIST_WALK) {
        ue4_property_t *p = calloc(1, sizeof(*p));
        if (!p) break;

        /* --- Name (FField::NamePrivate is an FName) --- */
        if (!ue4r_resolve_name(ctx, prop_ptr + OFF_FFIELD_NAME,
                               p->name, sizeof(p->name))) {
            snprintf(p->name, sizeof(p->name), "<unknown>");
        }

        /* --- Type name from FFieldClass --- */
        uint64_t fclass = rm_read_ptr(ctx->task,
                                      prop_ptr + OFF_FFIELD_CLASS);
        if (rm_validate_ptr(fclass)) {
            /*
             * FFieldClass stores an FName at offset 0 (OFF_FFIELDCLASS_NAME).
             * This gives us the property type name (e.g. "FloatProperty").
             */
            if (!ue4r_resolve_name(ctx, fclass + OFF_FFIELDCLASS_NAME,
                                   p->type, sizeof(p->type))) {
                snprintf(p->type, sizeof(p->type), "Unknown");
            }
        } else {
            snprintf(p->type, sizeof(p->type), "Unknown");
        }

        /* --- Numeric fields --- */
        bool ok;
        p->array_dim    = rm_read_i32(ctx->task,
                                      prop_ptr + OFF_FPROP_ARRAY_DIM, &ok);
        if (!ok) p->array_dim = 0;

        p->element_size = rm_read_i32(ctx->task,
                                      prop_ptr + OFF_FPROP_ELEMENT_SIZE, &ok);
        if (!ok) p->element_size = 0;

        p->offset       = rm_read_i32(ctx->task,
                                      prop_ptr + OFF_FPROP_OFFSET, &ok);
        if (!ok) p->offset = 0;

        /* Append to linked list */
        p->next = NULL;
        if (tail) { tail->next = p; tail = p; }
        else      { head = tail = p; }

        /* Advance to next FProperty in the linked list */
        prop_ptr = rm_read_ptr(ctx->task, prop_ptr + OFF_FFIELD_NEXT);
        count++;
    }

    return head;
}

/*
 * read_functions — walk the UField linked list starting at
 * UStruct::Children, filtering for UFunction objects.
 *
 * Children are UField subclasses linked via UField::Next (OFF_UFIELD_NEXT).
 * We identify UFunctions by checking whether the child's ClassPrivate has
 * the name "Function".
 */
static ue4_function_t *read_functions(ue4r_ctx_t *ctx, uint64_t class_addr)
{
    uint64_t child = rm_read_ptr(ctx->task,
                                 class_addr + OFF_USTRUCT_CHILDREN);

    ue4_function_t *head = NULL;
    ue4_function_t *tail = NULL;
    int count = 0;

    while (rm_validate_ptr(child) && count < MAX_LIST_WALK) {
        /* Read the child's ClassPrivate to determine its type */
        uint64_t child_class = rm_read_ptr(ctx->task,
                                           child + OFF_UOBJECT_CLASS);
        char class_name[256] = {0};

        if (rm_validate_ptr(child_class)) {
            resolve_object_name(ctx, child_class, class_name,
                                sizeof(class_name));
        }

        if (strcmp(class_name, "Function") == 0) {
            ue4_function_t *f = calloc(1, sizeof(*f));
            if (!f) break;

            /* Name */
            if (!resolve_object_name(ctx, child, f->name, sizeof(f->name)))
                snprintf(f->name, sizeof(f->name), "<unknown>");

            /* FunctionFlags (uint32) */
            bool ok;
            f->flags = (uint32_t)rm_read_i32(ctx->task,
                                             child + OFF_UFUNC_FLAGS, &ok);
            if (!ok) f->flags = 0;

            /* ParmsSize (uint16) */
            f->parms_size = rm_read_u16(ctx->task,
                                        child + OFF_UFUNC_PARMS_SIZE, &ok);
            if (!ok) f->parms_size = 0;

            /* Append */
            f->next = NULL;
            if (tail) { tail->next = f; tail = f; }
            else      { head = tail = f; }
        }

        /* Next child in the UField linked list */
        child = rm_read_ptr(ctx->task, child + OFF_UFIELD_NEXT);
        count++;
    }

    return head;
}

/* =======================================================================
 * GUObjectArray iteration helpers
 * ======================================================================= */

/*
 * read_object_from_array — read the UObject* at a given linear index in the
 * chunked FUObjectArray.
 *
 * The chunked array stores an array of chunk pointers at
 * guobjectarray + OFF_GUOBJ_CHUNKED + OFF_CHUNKED_OBJECTS.
 * Each chunk holds ELEMENTS_PER_CHUNK items of size FUOBJECTITEM_SIZE.
 */
static uint64_t read_object_from_array(ue4r_ctx_t *ctx,
                                       uint64_t   objects_ptr,
                                       int32_t    index)
{
    int32_t chunk_index  = index / ELEMENTS_PER_CHUNK;
    int32_t within_chunk = index % ELEMENTS_PER_CHUNK;

    /* Read the chunk pointer */
    uint64_t chunk_ptr = rm_read_ptr(ctx->task,
                                     objects_ptr + (uint64_t)chunk_index * 8);
    if (!rm_validate_ptr(chunk_ptr)) return 0;

    /* Read the UObject* from the FUObjectItem */
    uint64_t item_addr = chunk_ptr +
                         (uint64_t)within_chunk * FUOBJECTITEM_SIZE +
                         FUOBJECTITEM_OBJECT;
    uint64_t obj = rm_read_ptr(ctx->task, item_addr);
    return obj;
}

/* =======================================================================
 * Initialization
 * ======================================================================= */

/*
 * find_uclass_class — scan the first few hundred GUObjectArray entries to
 * locate the UClass object whose name is "Class" and whose ClassPrivate
 * points to itself (i.e. the meta-class).
 */
static uint64_t find_uclass_class(ue4r_ctx_t *ctx)
{
    /* Read the chunked array header */
    uint64_t chunked = ctx->guobjectarray + OFF_GUOBJ_CHUNKED;

    uint64_t objects_ptr = rm_read_ptr(ctx->task,
                                       chunked + OFF_CHUNKED_OBJECTS);
    if (!rm_validate_ptr(objects_ptr)) {
        fprintf(stderr, "[ue4r] failed to read GUObjectArray.Objects\n");
        return 0;
    }

    bool ok;
    int32_t num_elems = rm_read_i32(ctx->task,
                                    chunked + OFF_CHUNKED_NUM_ELEMS, &ok);
    if (!ok || num_elems <= 0) {
        fprintf(stderr, "[ue4r] failed to read GUObjectArray.NumElements\n");
        return 0;
    }

    int32_t scan_limit = (num_elems < MAX_INIT_SCAN_OBJS)
                         ? num_elems : MAX_INIT_SCAN_OBJS;

    for (int32_t i = 0; i < scan_limit; i++) {
        uint64_t obj = read_object_from_array(ctx, objects_ptr, i);
        if (!rm_validate_ptr(obj)) continue;

        /* Check if ClassPrivate == self (meta-class property) */
        uint64_t cls = rm_read_ptr(ctx->task, obj + OFF_UOBJECT_CLASS);
        if (cls != obj) continue;

        /* Resolve the object's name */
        char name[256] = {0};
        resolve_object_name(ctx, obj, name, sizeof(name));
        if (strcmp(name, "Class") == 0) {
            return obj;
        }
    }

    fprintf(stderr, "[ue4r] could not locate UClass(\"Class\") in first "
                    "%d objects\n", scan_limit);
    return 0;
}

ue4r_ctx_t *ue4r_init(mach_port_t task,
                      uint64_t    image_base,
                      uint64_t    slide,
                      uint64_t    guobj_off,
                      uint64_t    gnames_off)
{
    ue4r_ctx_t *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) {
        fprintf(stderr, "[ue4r] allocation failed\n");
        return NULL;
    }

    ctx->task       = task;
    ctx->image_base = image_base;
    ctx->slide      = slide;

    /* ----- Resolve GUObjectArray address ----- */
    if (guobj_off != 0) {
        ctx->guobjectarray = guobj_off + slide;
    } else {
        ctx->guobjectarray = try_find_guobjectarray(task, image_base, slide);
        if (ctx->guobjectarray == 0) {
            fprintf(stderr, "[ue4r] GUObjectArray auto-detect failed\n");
            free(ctx);
            return NULL;
        }
    }

    /* ----- Resolve FNamePool address ----- */
    if (gnames_off != 0) {
        ctx->gnamepool = gnames_off + slide;
    } else {
        ctx->gnamepool = try_find_gnamepool(task, image_base, slide);
        if (ctx->gnamepool == 0) {
            fprintf(stderr, "[ue4r] FNamePool auto-detect failed\n");
            free(ctx);
            return NULL;
        }
    }

    /* ----- Locate the UClass meta-class ("Class" whose class is itself) --- */
    ctx->uclass_class = find_uclass_class(ctx);
    if (ctx->uclass_class == 0) {
        fprintf(stderr, "[ue4r] failed to locate UClass(\"Class\")\n");
        free(ctx);
        return NULL;
    }

    fprintf(stderr, "[ue4r] init OK  guobj=0x%llx  gnames=0x%llx  "
                    "uclass=0x%llx\n",
            (unsigned long long)ctx->guobjectarray,
            (unsigned long long)ctx->gnamepool,
            (unsigned long long)ctx->uclass_class);

    return ctx;
}

/* =======================================================================
 * Class enumeration
 * ======================================================================= */

ue4_class_t *ue4r_walk_classes(ue4r_ctx_t *ctx)
{
    if (!ctx) return NULL;

    /* Read the chunked object array header */
    uint64_t chunked     = ctx->guobjectarray + OFF_GUOBJ_CHUNKED;
    uint64_t objects_ptr = rm_read_ptr(ctx->task,
                                       chunked + OFF_CHUNKED_OBJECTS);
    if (!rm_validate_ptr(objects_ptr)) {
        fprintf(stderr, "[ue4r] walk_classes: bad Objects pointer\n");
        return NULL;
    }

    bool ok;
    int32_t num_elems = rm_read_i32(ctx->task,
                                    chunked + OFF_CHUNKED_NUM_ELEMS, &ok);
    if (!ok || num_elems <= 0) {
        fprintf(stderr, "[ue4r] walk_classes: bad NumElements\n");
        return NULL;
    }
    if (num_elems > MAX_OBJECTS) num_elems = MAX_OBJECTS;

    ue4_class_t *head = NULL;
    ue4_class_t *tail = NULL;

    for (int32_t i = 0; i < num_elems; i++) {
        uint64_t obj = read_object_from_array(ctx, objects_ptr, i);
        if (!rm_validate_ptr(obj)) continue;

        /* Is this object a UClass?  (ClassPrivate == uclass_class) */
        uint64_t cls = rm_read_ptr(ctx->task, obj + OFF_UOBJECT_CLASS);
        if (cls != ctx->uclass_class) continue;

        /* ---- Build a ue4_class_t for this UClass ---- */
        ue4_class_t *c = calloc(1, sizeof(*c));
        if (!c) break;

        /* Full path name (e.g. "/Script/Engine.Actor") */
        build_path_name(ctx, obj, c->name, sizeof(c->name), 0);

        /* SuperStruct path name */
        uint64_t super_ptr = rm_read_ptr(ctx->task,
                                         obj + OFF_USTRUCT_SUPER);
        if (rm_validate_ptr(super_ptr)) {
            build_path_name(ctx, super_ptr, c->super_name,
                            sizeof(c->super_name), 0);
        } else {
            c->super_name[0] = '\0';
        }

        /* PropertiesSize (int32) */
        c->struct_size = rm_read_i32(ctx->task,
                                     obj + OFF_USTRUCT_PROPS_SIZE, &ok);
        if (!ok) c->struct_size = 0;

        /* Property list (FProperty chain via ChildProperties) */
        c->properties = read_properties(ctx, obj);

        /* Function list (UField chain via Children, filtered) */
        c->functions = read_functions(ctx, obj);

        /* Append to result list */
        c->next = NULL;
        if (tail) { tail->next = c; tail = c; }
        else      { head = tail = c; }
    }

    return head;
}

/* =======================================================================
 * Cleanup
 * ======================================================================= */

void ue4r_free_classes(ue4_class_t *list)
{
    while (list) {
        ue4_class_t *next_class = list->next;

        /* Free property chain */
        ue4_property_t *p = list->properties;
        while (p) {
            ue4_property_t *np = p->next;
            free(p);
            p = np;
        }

        /* Free function chain */
        ue4_function_t *f = list->functions;
        while (f) {
            ue4_function_t *nf = f->next;
            free(f);
            f = nf;
        }

        free(list);
        list = next_class;
    }
}

void ue4r_destroy(ue4r_ctx_t *ctx)
{
    if (ctx) free(ctx);
}
