#import "renderer.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdlib.h>
#include <string.h>
_Static_assert(sizeof(BsParams)==144,"parameter ABI");
_Static_assert(sizeof(BsMap)==96,"map ABI");
struct BsGpu {
    CFTypeRef device, queue, initialize, integrate, shade;
    CFTypeRef rays, indices[2], counter, maps, colors;
    uint32_t capacity, active, current, group;
    BsParams params;
    double seconds;
    char name[256];
};
static id obj(CFTypeRef ref) { return (__bridge id)ref; }
static void save(CFTypeRef *slot,id value) { if(*slot) CFRelease(*slot); *slot=value?CFBridgingRetain(value):NULL; }
static void errorText(char *text,size_t capacity,NSString *message) {
    if(capacity) snprintf(text,capacity,"%s",message.UTF8String ?: "Metal error");
}
BsGpu *bsGpuCreate(const char *source,size_t length,char *error,size_t capacity) {
    @autoreleasepool {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        if(!device) {errorText(error,capacity,@"Metal unavailable");return NULL;}
        MTLCompileOptions *options=[MTLCompileOptions new];
        options.mathMode=MTLMathModeSafe;
        NSError *failure=nil;
        NSString *code=[[NSString alloc] initWithBytes:source length:length encoding:NSUTF8StringEncoding];
        id<MTLLibrary> library=[device newLibraryWithSource:code options:options error:&failure];
        if(!library) {errorText(error,capacity,failure.localizedDescription);return NULL;}
        BsGpu *gpu=calloc(1,sizeof(*gpu));
        if(!gpu) {errorText(error,capacity,@"Out of memory");return NULL;}
        save(&gpu->device,device); save(&gpu->queue,[device newCommandQueue]);
        NSString *names[]={@"rayInit",@"rayStep",@"shadeMap"};
        CFTypeRef *slots[]={&gpu->initialize,&gpu->integrate,&gpu->shade};
        for(unsigned i=0;i<3;i++) {
            id<MTLFunction> function=[library newFunctionWithName:names[i]];
            id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:function error:&failure];
            if(!pipeline) {errorText(error,capacity,failure.localizedDescription);bsGpuDestroy(gpu);return NULL;}
            save(slots[i],pipeline);
        }
        gpu->group=64; snprintf(gpu->name,sizeof(gpu->name),"%s",device.name.UTF8String);
        return gpu;
    }
}
void bsGpuDestroy(BsGpu *g) {
    if(!g) return;
    CFTypeRef refs[]={g->device,g->queue,g->initialize,g->integrate,g->shade,g->rays,g->indices[0],g->indices[1],g->counter,g->maps,g->colors};
    for(unsigned i=0;i<sizeof(refs)/sizeof(*refs);i++) if(refs[i]) CFRelease(refs[i]);
    free(g);
}
static bool reserve(BsGpu *g,uint32_t count) {
    if(count<=g->capacity) return true;
    if(count>3840u*2160u) return false;
    id<MTLDevice> device=obj(g->device);
    save(&g->rays,[device newBufferWithLength:count*64ul options:MTLResourceStorageModeShared]);
    for(int i=0;i<2;i++) save(&g->indices[i],[device newBufferWithLength:count*4ul options:MTLResourceStorageModeShared]);
    save(&g->counter,[device newBufferWithLength:4 options:MTLResourceStorageModeShared]);
    save(&g->maps,[device newBufferWithLength:count*sizeof(BsMap) options:MTLResourceStorageModeShared]);
    save(&g->colors,[device newBufferWithLength:count*16ul options:MTLResourceStorageModeShared]);
    if(!g->rays||!g->indices[0]||!g->indices[1]||!g->counter||!g->maps||!g->colors) return false;
    g->capacity=count; return true;
}
static bool finish(BsGpu *g,id<MTLCommandBuffer> command) {
    [command commit]; [command waitUntilCompleted];
    g->seconds+=command.GPUEndTime-command.GPUStartTime;
    return command.status==MTLCommandBufferStatusCompleted;
}
static void dispatch(BsGpu *g,id<MTLComputeCommandEncoder> encoder,id<MTLComputePipelineState> pipeline,uint32_t count) {
    NSUInteger group=MIN(g->group,pipeline.maxTotalThreadsPerThreadgroup);
    [encoder dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(group,1,1)];
    [encoder endEncoding];
}
const char *bsGpuName(BsGpu *g) {return g->name;}
int bsGpuStart(BsGpu *g,const BsParams *params) {
    @autoreleasepool {
        if(!reserve(g,params->work[1])) return -1;
        g->params=*params;g->active=params->work[1];g->current=0;g->seconds=0;
        id<MTLCommandBuffer> command=[obj(g->queue) commandBuffer];
        id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        id<MTLComputePipelineState> pipeline=obj(g->initialize);
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:obj(g->rays) offset:0 atIndex:0];
        [encoder setBuffer:obj(g->indices[0]) offset:0 atIndex:1];
        [encoder setBuffer:obj(g->maps) offset:0 atIndex:2];
        [encoder setBytes:params length:sizeof(*params) atIndex:3];
        dispatch(g,encoder,pipeline,g->active);
        return finish(g,command)?0:-1;
    }
}
int bsGpuStep(BsGpu *g) {
    @autoreleasepool {
        if(!g->active) return 0;
        id<MTLBuffer> counter=obj(g->counter); *(uint32_t*)counter.contents=0;
        id<MTLCommandBuffer> command=[obj(g->queue) commandBuffer];
        id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        id<MTLComputePipelineState> pipeline=obj(g->integrate);
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:obj(g->rays) offset:0 atIndex:0];
        [encoder setBuffer:obj(g->indices[g->current]) offset:0 atIndex:1];
        [encoder setBuffer:obj(g->indices[1-g->current]) offset:0 atIndex:2];
        [encoder setBuffer:counter offset:0 atIndex:3];
        [encoder setBuffer:obj(g->maps) offset:0 atIndex:4];
        [encoder setBytes:&g->params length:sizeof(g->params) atIndex:5];
        [encoder setBytes:&g->active length:sizeof(g->active) atIndex:6];
        dispatch(g,encoder,pipeline,g->active);
        if(!finish(g,command)) return -1;
        g->active=*(uint32_t*)counter.contents;g->current=1-g->current;
        return (int)g->active;
    }
}
const BsMap *bsGpuMap(BsGpu *g) {return [(id<MTLBuffer>)obj(g->maps) contents];}
double bsGpuSeconds(BsGpu *g) {return g->seconds;}
const float *bsGpuShade(BsGpu *g,const BsParams *params,const BsMap *map,uint32_t count) {
    @autoreleasepool {
        if(!reserve(g,count)) return NULL;
        id<MTLBuffer> maps=obj(g->maps);
        if(map!=maps.contents) memcpy(maps.contents,map,count*sizeof(BsMap));
        id<MTLCommandBuffer> command=[obj(g->queue) commandBuffer];
        id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        id<MTLComputePipelineState> pipeline=obj(g->shade);
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:maps offset:0 atIndex:0];
        [encoder setBuffer:obj(g->colors) offset:0 atIndex:1];
        [encoder setBytes:params length:sizeof(*params) atIndex:2];
        dispatch(g,encoder,pipeline,count);
        return finish(g,command)?[(id<MTLBuffer>)obj(g->colors) contents]:NULL;
    }
}
uint32_t bsGpuThreadWidth(BsGpu *g) {return (uint32_t)[obj(g->integrate) threadExecutionWidth];}
void bsGpuSetGroup(BsGpu *g,uint32_t size) {if(size>=32 && size<=256)g->group=size;}
