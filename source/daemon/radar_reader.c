/* Live read-only radar. Uses existing offsets; no schema generation. */
#include "radar_reader.h"
#include "radar_data.h"
#include "remote_memory.h"
#include "ue4_reflection.h"
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
static int32_t world_cursor, character_cursor;
static uint64_t characters[512];
static unsigned character_count;
static double next_character_scan;

static double now_seconds(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}
static uint64_t ptr(uint64_t object, uint64_t offset) {
    if (!rm_validate_ptr(object) || object > UINT64_MAX-offset) return 0;
    uint64_t value = rm_read_ptr(task, object+offset);
    return rm_validate_ptr(value) ? value : 0;
}
static bool array(uint64_t object, uint64_t offset, uint64_t *data, int32_t *count, int limit) {
    struct {uint64_t data; int32_t count, capacity;} a;
    if (!rm_validate_ptr(object) || !rm_read(task, object+offset, &a, sizeof(a))) return false;
    if (a.count<0 || a.capacity<a.count || a.count>limit || a.capacity>1000000) return false;
    if (a.count && !rm_validate_ptr(a.data)) return false;
    *data=a.data; *count=a.count; return true;
}
static bool vec(uint64_t object, uint64_t offset, rvec3_t *out) {
    rvec3_t v;
    if (!rm_validate_ptr(object) || !rm_read(task,object+offset,&v,sizeof(v))) return false;
    if (!isfinite(v.x)||!isfinite(v.y)||!isfinite(v.z)) return false;
    *out=v;return true;
}
static bool position(uint64_t actor,rvec3_t *out) {return vec(ptr(actor,0x208),0x1e4,out);}
static void publish(uint32_t status) {
    frame.header.magic=RADAR_MAGIC;frame.header.version=RADAR_VERSION;
    frame.header.tick=++tick;frame.header.status=status;
    uint32_t sequence=__atomic_load_n(&shared->header.sequence,__ATOMIC_RELAXED);
    sequence=(sequence+1u)|1u;
    __atomic_store_n(&shared->header.sequence,sequence,__ATOMIC_SEQ_CST);
    /* Copy on either side of the sequence word, keeping it odd throughout. */
    size_t prefix=(size_t)((char *)&shared->header.sequence-(char *)shared);
    memcpy(shared,&frame,prefix);
    size_t suffix=prefix+sizeof(uint32_t);
    memcpy((char *)shared+suffix,(char *)&frame+suffix,sizeof(frame)-suffix);
    __atomic_store_n(&shared->header.sequence,sequence+1u,__ATOMIC_RELEASE);
    if (logfile && (status!=last_status || tick%200==0)) {
        fprintf(logfile,"tick=%u status=%u players=%u world=0x%llx local=(%.1f,%.1f,%.1f)\n",
            tick,status,frame.header.player_count,world,frame.header.local_pos.x,
            frame.header.local_pos.y,frame.header.local_pos.z);fflush(logfile);
    }
    last_status=status;
}
static void read_config(uint64_t *objects,uint64_t *names) {
    *objects=0;*names=0;
    FILE *f=fopen("/var/mobile/Downloads/ue4_sdk_config.txt","r");
    if (!f)return;
    char line[256],key[128];unsigned long long value;
    while(fgets(line,sizeof(line),f)) {
        if(sscanf(line," %127[^=]=%llx",key,&value)!=2)continue;
        if(!strcmp(key,"guobjectarray"))*objects=value;
        if(!strcmp(key,"gnamepool"))*names=value;
    }
    fclose(f);
}
static uint64_t local_controller(uint64_t w) {
    if(local_player && ptr(ptr(local_player,0x58),0x78)==w) {
        uint64_t pc=ptr(local_player,0x30);
        if(pc && ptr(pc,0x518)==local_player)return pc;
    }
    uint64_t gi=ptr(w,0x470),data;int32_t count;
    if(!array(gi,0x48,&data,&count,16)||!count)return 0;
    return ptr(ptr(data,0),0x30);
}
static uint64_t find_world(void) {
    if(local_player) {
        uint64_t current=ptr(ptr(local_player,0x58),0x78);
        if(current && local_controller(current)){if(world && world!=current){character_count=0;character_cursor=0;}world=current;return world;}
        local_player=0;
    }
    world=0;
    double now=now_seconds();
    if(now<next_lookup)return 0;
    next_lookup=now+0.05;
    if(!reflection) {
        uint64_t objects,names;read_config(&objects,&names);
        reflection=ue4r_init(task,base,slide,objects,names);
        if(!ue4r_ready(reflection)) {
            if(reflection)ue4r_destroy(reflection);
            reflection=NULL;return 0;
        }
    }
    if(world_cursor<0){world_cursor=0;next_lookup=now+0.25;return 0;}
    uint64_t candidate=ue4r_find_instance(reflection,"LocalPlayer",&world_cursor);
    if(candidate) {
        uint64_t viewport=ptr(candidate,0x58),w=ptr(viewport,0x78),pc=ptr(candidate,0x30);
        if(logfile){fprintf(logfile,"LocalPlayer=0x%llx viewport=0x%llx world=0x%llx pc=0x%llx backlink=0x%llx\n",candidate,viewport,w,pc,ptr(pc,0x518));fflush(logfile);}
        if(w && pc && ptr(pc,0x518)==candidate){local_player=candidate;world=w;}
    }
    return world;
}
int radar_init(mach_port_t target,uint64_t image_base,uint64_t aslr_slide) {
    local_player=0;task=target;base=image_base;slide=aslr_slide;world=0;tick=0;next_lookup=0;
    last_status=UINT32_MAX;world_cursor=0;character_cursor=0;character_count=0;next_character_scan=0;
    logfile=fopen("/var/mobile/Downloads/ue4_radar.log","a");
    fd=open(RADAR_FILE_PATH,O_RDWR|O_CREAT,0644);
    if(fd<0)goto fail;
    if(ftruncate(fd,sizeof(radar_shared_t)))goto fail;
    shared=mmap(NULL,sizeof(*shared),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if(shared==MAP_FAILED){shared=NULL;goto fail;}
    chown(RADAR_FILE_PATH,501,501);
    memset(&frame,0,sizeof(frame));publish(1);return 0;
fail:
    radar_destroy();return -1;
}
int radar_tick(void) {
    if(!shared)return -1;
    memset(&frame,0,sizeof(frame));frame.header.camera_fov=90;
    if(!find_world()){publish(1);return 0;}
    uint64_t pc=local_controller(world);
    if(!pc){world=0;publish(1);return 0;}
    uint64_t pawn=ptr(pc,0x528),camera=ptr(pc,0x548);
    bool has_local=position(pawn,&frame.header.local_pos);
    rvec3_t camera_pos={0};
    bool camera_ok=vec(camera,0x530,&camera_pos);
    frame.header.camera_pos=camera_pos;
    if(!has_local)frame.header.local_pos=camera_pos;
    camera_ok=vec(camera,0x548,&frame.header.local_rot) && camera_ok;
    float fov;
    if(camera && rm_read(task,camera+0x554,&fov,4) && isfinite(fov) && fov>10 && fov<180)
        {frame.header.camera_fov=fov;frame.header.camera_valid=camera_ok;}
    double now=now_seconds();
    if(now>=next_character_scan) {
        if(character_cursor<0){character_cursor=0;next_character_scan=now+0.25;}
        else {
            uint64_t found=ue4r_find_instance(reflection,"STExtraBaseCharacter",&character_cursor);
            if(found) {
                if(character_count==512) {
                    unsigned live=0;
                    for(unsigned i=0;i<character_count;i++)if(characters[i])characters[live++]=characters[i];
                    character_count=live;
                }
                bool exists=false;
                for(unsigned i=0;i<character_count;i++)if(characters[i]==found)exists=true;
                if(!exists && character_count<512)characters[character_count++]=found;
            }
        }
    }
    unsigned rejected=0;
    for(unsigned i=0;i<character_count && frame.header.player_count<RADAR_MAX_PLAYERS;i++) {
        uint64_t other=characters[i];
        if(!other || other==pawn)continue;
        radar_player_t p={0};
        if(!position(other,&p.pos)){characters[i]=0;rejected++;continue;}
        uint64_t st=ptr(other,0x2410);
        if(!st)st=ptr(other,0x4d0);
        if(!st){rejected++;continue;}
        if(!rm_read(task,st+0x142c,&p.health,4)||!rm_read(task,st+0x1430,&p.health_max,4))continue;
        if(!isfinite(p.health)||!isfinite(p.health_max)||p.health_max<=0||p.health_max>100000)continue;
        rm_read(task,other+0x2be8,&p.health_status,1);
        if(p.health_status==2)continue;
        rvec3_t rot;
        if(vec(ptr(other,0x208),0x1f0,&rot))p.yaw=rot.y;
        frame.players[frame.header.player_count++]=p;
    }
    if(logfile && tick%200==0){fprintf(logfile,"character_scan cursor=%d cached=%u rejected=%u players=%u\n",character_cursor,character_count,rejected,frame.header.player_count);fflush(logfile);}
    publish((has_local||frame.header.camera_valid)?2:3);return 0;
}
void radar_destroy(void) {
    if(shared) {
        memset(&frame,0,sizeof(frame));publish(0);
        munmap(shared,sizeof(*shared));shared=NULL;
    }
    if(fd>=0){close(fd);fd=-1;}
    if(reflection){ue4r_destroy(reflection);reflection=NULL;}
    if(logfile){fclose(logfile);logfile=NULL;}
    task=MACH_PORT_NULL;world=0;
}
