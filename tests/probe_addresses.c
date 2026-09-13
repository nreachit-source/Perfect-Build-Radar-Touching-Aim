/* Read-only diagnostic; build separately from the daemon. */
#include "remote_memory.h"
#include "aslr_slide.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    mach_port_t task = rm_task_acquire((pid_t)atoi(argv[1]));
    if (!task) return 3;
    aslr_result_t a = aslr_get_slide(task);
    if (!a.found) { rm_task_release(task); return 4; }
    printf("base=%llx slide=%llx\n", a.base, a.slide);
    uint64_t candidates[] = {0x10aad3898ULL, 0x10aad3898ULL+a.slide,
        a.base+0x5da3898ULL, 0x10a898170ULL+a.slide};
    for (unsigned i=0; i<sizeof(candidates)/sizeof(candidates[0]); ++i) {
        uint32_t words[16] = {0};
        bool ok = rm_read(task,candidates[i],words,sizeof(words));
        printf("address=%llx readable=%d",candidates[i],ok);
        for (unsigned j=0;j<16;++j) printf(" %08x",words[j]);
        puts("");
    }
    rm_task_release(task);
    return 0;
}
