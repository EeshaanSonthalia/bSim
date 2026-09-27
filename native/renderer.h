#ifndef BSIM_RENDERER_H
#define BSIM_RENDERER_H
#include <stdint.h>
#include <stddef.h>
typedef struct BsGpu BsGpu;
typedef struct {
    float camera[4];
    float composition[4];
    float disk[4];
    float material[4];
    float color[4];
    float optics[4];
    float timing[4];
    uint32_t image[4];
    uint32_t work[4];
} BsParams;
typedef struct {
    float hits[4][4];
    float sky[4];
    float info[4];
} BsMap;
/* The caller owns the context. Error text is always terminated when capacity > 0. */
BsGpu *bsGpuCreate(const char *source, size_t length, char *error, size_t capacity);
void bsGpuDestroy(BsGpu *gpu);
const char *bsGpuName(BsGpu *gpu);
/* Bounded tiles. Start and step are synchronous; Zig owns the scheduling gate. */
int bsGpuStart(BsGpu *gpu, const BsParams *params);
int bsGpuStep(BsGpu *gpu);
const BsMap *bsGpuMap(BsGpu *gpu);
double bsGpuSeconds(BsGpu *gpu);
/* Shade a prepared map to shared scene-linear RGBA output. */
const float *bsGpuShade(BsGpu *gpu, const BsParams *params, const BsMap *map, uint32_t count);
uint32_t bsGpuThreadWidth(BsGpu *gpu);
void bsGpuSetGroup(BsGpu *gpu, uint32_t size);
/* Full volume transport. The mask has one byte per pixel; zero skips a sample. */
int bsGpuTransportStart(BsGpu *gpu,const BsParams *params,const uint8_t *mask);
const float *bsGpuTransportResult(BsGpu *gpu);
#endif
