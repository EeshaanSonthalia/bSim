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
    CFTypeRef pathInitialize,pathIntegrate,pathResolve,paths,mask,guide,learning;
    uint32_t capacity, active, current, group;
    bool volume;
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
        NSString *names[]={@"rayInit",@"rayStep",@"shadeMap",@"pathInit",@"pathStep",@"pathResolve"};
        CFTypeRef *slots[]={&gpu->initialize,&gpu->integrate,&gpu->shade,&gpu->pathInitialize,&gpu->pathIntegrate,&gpu->pathResolve};
        for(unsigned i=0;i<6;i++) {
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
    CFTypeRef refs[]={g->device,g->queue,g->initialize,g->integrate,g->shade,g->rays,g->indices[0],g->indices[1],g->counter,g->maps,g->colors,g->pathInitialize,g->pathIntegrate,g->pathResolve,g->paths,g->mask,g->guide,g->learning};
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
    save(&g->paths,[device newBufferWithLength:count*128ul options:MTLResourceStorageModeShared]);
    save(&g->mask,[device newBufferWithLength:count options:MTLResourceStorageModeShared]);
    if(!g->guide) {
        save(&g->guide,[device newBufferWithLength:128*4 options:MTLResourceStorageModeShared]);
        save(&g->learning,[device newBufferWithLength:128*4 options:MTLResourceStorageModeShared]);
    }
    if(!g->rays||!g->indices[0]||!g->indices[1]||!g->counter||!g->maps||!g->colors||!g->paths||!g->mask||!g->guide||!g->learning) return false;
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
        g->params=*params;g->active=params->work[1];g->current=0;g->seconds=0;g->volume=false;
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
        id<MTLComputePipelineState> pipeline=obj(g->volume?g->pathIntegrate:g->integrate);
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:obj(g->volume?g->paths:g->rays) offset:0 atIndex:0];
        [encoder setBuffer:obj(g->indices[g->current]) offset:0 atIndex:1];
        [encoder setBuffer:obj(g->indices[1-g->current]) offset:0 atIndex:2];
        [encoder setBuffer:counter offset:0 atIndex:3];
        if(g->volume) {
            [encoder setBytes:&g->params length:sizeof(g->params) atIndex:4];
            [encoder setBytes:&g->active length:sizeof(g->active) atIndex:5];
            [encoder setBuffer:obj(g->guide) offset:0 atIndex:6];
            [encoder setBuffer:obj(g->learning) offset:0 atIndex:7];
        } else {
            [encoder setBuffer:obj(g->maps) offset:0 atIndex:4];
            [encoder setBytes:&g->params length:sizeof(g->params) atIndex:5];
            [encoder setBytes:&g->active length:sizeof(g->active) atIndex:6];
        }
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
void *bsGpuBorrowDevice(BsGpu *g) {return (void*)g->device;}
void *bsGpuBorrowColorBuffer(BsGpu *g) {return (void*)g->colors;}
int bsGpuTransportStart(BsGpu *g,const BsParams *params,const uint8_t *mask) {
    @autoreleasepool {
        if(!reserve(g,params->work[1]*2))return -1;
        g->params=*params;g->active=params->work[1]*2;g->current=0;g->seconds=0;g->volume=true;
        memcpy([(id<MTLBuffer>)obj(g->mask) contents],mask,params->work[1]);
        if(params->work[0]==0 && params->work[2]==0) {
            float *guide=[(id<MTLBuffer>)obj(g->guide) contents];
            for(int i=0;i<128;i++)guide[i]=1;
            memset([(id<MTLBuffer>)obj(g->learning) contents],0,128*4);
        }
        id<MTLCommandBuffer> command=[obj(g->queue) commandBuffer];
        id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        id<MTLComputePipelineState> pipeline=obj(g->pathInitialize);
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:obj(g->paths) offset:0 atIndex:0];
        [encoder setBuffer:obj(g->indices[0]) offset:0 atIndex:1];
        [encoder setBytes:params length:sizeof(*params) atIndex:2];
        [encoder setBuffer:obj(g->mask) offset:0 atIndex:3];
        dispatch(g,encoder,pipeline,g->active);
        return finish(g,command)?0:-1;
    }
}
const float *bsGpuTransportResult(BsGpu *g) {
    @autoreleasepool {
        if(g->active)return NULL;
        id<MTLCommandBuffer> command=[obj(g->queue) commandBuffer];
        id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        id<MTLComputePipelineState> pipeline=obj(g->pathResolve);
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:obj(g->paths) offset:0 atIndex:0];
        [encoder setBuffer:obj(g->colors) offset:0 atIndex:1];
        [encoder setBytes:&g->params length:sizeof(g->params) atIndex:2];
        dispatch(g,encoder,pipeline,g->params.work[1]);
        if(!finish(g,command))return NULL;
        float *guide=[(id<MTLBuffer>)obj(g->guide) contents];
        const uint32_t *learning=[(id<MTLBuffer>)obj(g->learning) contents];
        for(int i=0;i<128;i++)guide[i]=1+(float)learning[i]/4096;
        return [(id<MTLBuffer>)obj(g->colors) contents];
    }
}
