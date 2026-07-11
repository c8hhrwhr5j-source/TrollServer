// fishhook.h — Facebook BSD 许可的运行时符号重绑定库（精简头文件）
#ifndef FISHHOOK_H
#define FISHHOOK_H

#include <stddef.h>
#include <stdint.h>

struct rebinding {
  const char *name;
  void *replacement;
  void **replaced;
};

// 重绑定当前进程内已加载镜像的符号（用于 Hook sysctlbyname/uname/sysctl 等 C 函数）
int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel);
int rebind_symbols_image(void *header, intptr_t slide,
                         struct rebinding rebindings[], size_t rebindings_nel);

#endif /* FISHHOOK_H */
