#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
extern char **environ;
struct aq_result { char *out, *err; size_t out_len, err_len; int status, exit_code; };
int64_t aq_now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (int64_t)t.tv_sec*1000+t.tv_nsec/1000000; }
static int collect(int fd,char **data,size_t *len,size_t limit) {
    char buf[8192];
    for (;;) {
        ssize_t n=read(fd,buf,sizeof buf);
        if(n==0) return 1;
        if(n<0) return (errno==EAGAIN || errno==EINTR)?0:-1;
        if((size_t)n>limit-*len) return -2;
        char *next=realloc(*data,*len+(size_t)n+1); if(!next) return -1;
        *data=next; memcpy(next+*len,buf,(size_t)n); *len+=(size_t)n; next[*len]=0;
    }
}
/* status: 0 complete, 1 spawn/I/O failure, 2 timeout, 3 output limit. */
void aq_run_limits(char *const argv[],const char *input,size_t input_len,int timeout_ms,size_t out_limit,size_t err_limit,struct aq_result *r) {
    memset(r,0,sizeof *r); r->exit_code=-1;
    int p[3][2]={{-1,-1},{-1,-1},{-1,-1}}; pid_t pid=-1; int child_status=0,waited=0;
    sigset_t blocked, previous; sigemptyset(&blocked); sigaddset(&blocked,SIGPIPE);
    pthread_sigmask(SIG_BLOCK,&blocked,&previous);
    for(int i=0;i<3;i++) if(pipe2(p[i],O_CLOEXEC)<0) { r->status=1; goto cleanup; }
    posix_spawn_file_actions_t fa; posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&fa); posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr,POSIX_SPAWN_SETPGROUP|POSIX_SPAWN_SETSIGMASK);
    posix_spawnattr_setpgroup(&attr,0); posix_spawnattr_setsigmask(&attr,&previous);
    for(int i=0;i<3;i++) {
        posix_spawn_file_actions_adddup2(&fa,p[i][i==0?0:1],i);
        posix_spawn_file_actions_addclose(&fa,p[i][0]); posix_spawn_file_actions_addclose(&fa,p[i][1]);
    }
    int rc=posix_spawnp(&pid,argv[0],&fa,&attr,argv,environ);
    posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr);
    if(rc) { r->status=1; goto cleanup; }
    close(p[0][0]);p[0][0]=-1;close(p[1][1]);p[1][1]=-1;close(p[2][1]);p[2][1]=-1;
    for(int i=0;i<3;i++) { int fd=p[i][i==0?1:0]; fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK); }
    int64_t deadline=aq_now_ms()+timeout_ms;size_t offset=0;
    while(!waited || p[1][0]>=0 || p[2][0]>=0) {
        if(aq_now_ms()>=deadline) {r->status=2;break;}
        if(offset==input_len && p[0][1]>=0) {close(p[0][1]);p[0][1]=-1;}
        struct pollfd fds[3]={{p[0][1],POLLOUT,0},{p[1][0],POLLIN,0},{p[2][0],POLLIN,0}};
        int polled=poll(fds,3,20);if(polled<0 && errno!=EINTR) {r->status=1;break;}
        if(fds[0].revents && p[0][1]>=0) {
            ssize_t n=write(p[0][1],input+offset,input_len-offset);
            if(n>0) offset+=(size_t)n;
            else if(n<0 && errno!=EAGAIN && errno!=EINTR) {close(p[0][1]);p[0][1]=-1;}
        }
        for(int i=1;i<3;i++) if(fds[i].revents && p[i][0]>=0) {
            int done=collect(p[i][0],i==1?&r->out:&r->err,i==1?&r->out_len:&r->err_len,i==1?out_limit:err_limit);
            if(done) {close(p[i][0]);p[i][0]=-1;}
            if(done<0) r->status=done==-2?3:1;
        }
        if(r->status) break;
        if(!waited) {pid_t w=waitpid(pid,&child_status,WNOHANG);if(w==pid) waited=1;else if(w<0 && errno!=EINTR){r->status=1;break;}}
    }
    if(r->status) kill(-pid,SIGKILL);
    if(!waited) while(waitpid(pid,&child_status,0)<0 && errno==EINTR) {}
    r->exit_code=WIFEXITED(child_status)?WEXITSTATUS(child_status):-1;
cleanup:
    for(int i=0;i<3;i++)for(int k=0;k<2;k++)if(p[i][k]>=0)close(p[i][k]);
    struct timespec zero={0,0};while(sigtimedwait(&blocked,NULL,&zero)>=0){}
    pthread_sigmask(SIG_SETMASK,&previous,NULL);
}
void aq_result_free(struct aq_result *r){free(r->out);free(r->err);memset(r,0,sizeof *r);}

#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <stdio.h>
static int instance_fd=-1,instance_lock=-1;
static char instance_path[108];
/* 0 owns instance, 1 forwarded launch, -1 unavailable. */
int aq_instance_start(const char *runtime,const char *display,unsigned page) {
    struct stat dir;
    if(stat(runtime,&dir)<0 || dir.st_uid!=getuid() || (dir.st_mode&0022)) return -1;
    uint64_t hash=1469598103934665603ULL;for(const unsigned char *p=(const unsigned char *)display;*p;p++){hash^=*p;hash*=1099511628211ULL;}
    if(snprintf(instance_path,sizeof instance_path,"%s/aqueous-settings-%016llx.sock",runtime,(unsigned long long)hash)>=(int)sizeof instance_path)return -1;
    char lockpath[128];snprintf(lockpath,sizeof lockpath,"%s.lock",instance_path);
    instance_lock=open(lockpath,O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0600);if(instance_lock<0)return -1;
    struct stat lockstat;if(fstat(instance_lock,&lockstat)<0 || lockstat.st_uid!=getuid() || !S_ISREG(lockstat.st_mode)){close(instance_lock);instance_lock=-1;return -1;}
    struct sockaddr_un addr={.sun_family=AF_UNIX};strcpy(addr.sun_path,instance_path);
    instance_fd=socket(AF_UNIX,SOCK_DGRAM|SOCK_CLOEXEC|SOCK_NONBLOCK,0);
    if(instance_fd<0){close(instance_lock);instance_lock=-1;return -1;}
    if(flock(instance_lock,LOCK_EX|LOCK_NB)<0) {
        int ok=-1;
        for(int i=0;i<50;i++) {
            if(sendto(instance_fd,&page,sizeof page,0,(struct sockaddr *)&addr,sizeof addr)==sizeof page){ok=1;break;}
            struct timespec delay={0,20000000};nanosleep(&delay,NULL);
        }
        close(instance_fd);close(instance_lock);instance_fd=instance_lock=-1;return ok;
    }
    unlink(instance_path);
    if(bind(instance_fd,(struct sockaddr *)&addr,sizeof addr)<0){close(instance_fd);close(instance_lock);instance_fd=instance_lock=-1;return -1;}
    chmod(instance_path,0600);return 0;
}
int aq_instance_poll(void) {
    unsigned page;ssize_t n=recv(instance_fd,&page,sizeof page,MSG_TRUNC);
    return n==sizeof page && page<8?(int)page:-1;
}
void aq_instance_close(void) {
    if(instance_fd>=0){close(instance_fd);unlink(instance_path);instance_fd=-1;}
    if(instance_lock>=0){close(instance_lock);instance_lock=-1;}
}

void aq_run(char *const argv[],const char *input,size_t len,int timeout,struct aq_result *r) { aq_run_limits(argv,input,len,timeout,16*1024*1024,64*1024,r); }
