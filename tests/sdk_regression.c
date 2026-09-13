/* Exercises the real SDK orchestrator + JSON writer with controlled
 * reflection results. Does not acquire a game task port. */
#include "ue4_sdk.h"
#include "ue4_reflection.h"
#include "remote_memory.h"
#include "aslr_slide.h"
#include "config_address.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* Zig release builds define NDEBUG. Checks must still execute. */
#define CHECK(expr) do { if (!(expr)) { \
    fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#expr); exit(1); \
} } while (0)

static int outcome;
mach_port_t rm_task_acquire(pid_t pid) { (void)pid; return 1; }
void rm_task_release(mach_port_t task) { (void)task; }
aslr_result_t aslr_get_slide(mach_port_t task) {
    (void)task; return (aslr_result_t){true,0x102104000,0x2104000};
}
ue4r_ctx_t *ue4r_init(mach_port_t t,uint64_t b,uint64_t s,uint64_t o,uint64_t n) {
    (void)t;(void)b;(void)s;(void)o;(void)n;
    return (ue4r_ctx_t *)&outcome;
}
void ue4r_destroy(ue4r_ctx_t *ctx) { (void)ctx; }
int ue4r_iterate_classes(ue4r_ctx_t *ctx,ue4r_class_callback_t cb,void *user) {
    (void)ctx;
    if (outcome == 0) return 0;
    ue4_class_t cls = {0};
    strcpy(cls.name, outcome < 0 ? "/Test.Partial" : "/Test.Complete");
    cb(user,&cls);
    return outcome;
}
static void read_output(char *out) {
    FILE *f=fopen(UE4_SDK_OUTPUT_PATH,"r"); CHECK(f);
    size_t n=fread(out,1,4095,f);out[n]=0;fclose(f);
}
int main(void) {
    CHECK(config_runtime_address(0,0x100000000,1)==0);
    CHECK(config_runtime_address(0xaad3898,0x102104000,0x2104000)==0x10cbd7898);
    CHECK(config_runtime_address(0x10aad3898,0x102104000,0x2104000)==0x10cbd7898);
    CHECK(config_runtime_address(UINT64_MAX,1,1)==0);
    char before[4096],after[4096];
    outcome=1; CHECK(ue4_sdk_generate(1)==0);read_output(before);
    CHECK(strstr(before,"/Test.Complete"));
    outcome=-1;CHECK(ue4_sdk_generate(1)==-1);read_output(after);
    CHECK(strcmp(before,after)==0);
    CHECK(access(UE4_SDK_OUTPUT_PATH ".tmp",F_OK)!=0);
    outcome=0;CHECK(ue4_sdk_generate(1)==-1);read_output(after);
    CHECK(strcmp(before,after)==0);
    CHECK(access(UE4_SDK_OUTPUT_PATH ".tmp",F_OK)!=0);
    puts("PASS: address conversion, overflow, successful publication, partial failure preservation, empty dump preservation, temporary cleanup");
    return 0;
}
