#ifndef BSIM_EXPORT_H
#define BSIM_EXPORT_H
#include <stdint.h>
/* Encode caller-owned pixels. Zig owns atomic rename and cancellation. */
int bsWritePng(const char *path,uint32_t width,uint32_t height,const uint16_t *rgba);
int bsWriteExr(const char *path,uint32_t width,uint32_t height,const float *rgba);
#endif
