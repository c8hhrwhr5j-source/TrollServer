/*
 * libPureC.m — 纯 C 探针，不依赖任何框架
 * 连 Foundation/ObjC runtime 都不用，终极最小化测试
 */
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

__attribute__((constructor))
static void purec_init(void) {
    const char *msg = "[PureC] dylib constructor 已执行 - 纯C加载成功!\n";
    // 尝试两个路径
    int fd = open("/tmp/libPureC.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (fd < 0) {
        fd = open("/var/mobile/Documents/libPureC.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
    }
    if (fd >= 0) {
        write(fd, msg, strlen(msg));
        close(fd);
    }
}
