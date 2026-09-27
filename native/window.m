#import "window.h"
#import <AppKit/AppKit.h>
#import <MetalKit/MetalKit.h>
#import <MetalFX/MetalFX.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#include <stdatomic.h>
extern void *bsGpuBorrowDevice(BsGpu *gpu);
extern void *bsGpuBorrowColorBuffer(BsGpu *gpu);
@interface BsWindowState : NSObject <NSWindowDelegate>
@property uint32_t flags;
@property double seekTime;
@end
@implementation BsWindowState
- (BOOL)windowShouldClose:(NSWindow *)sender {(void)sender;self.flags|=1;return NO;}
- (void)seek:(NSSlider *)slider {self.seekTime=slider.doubleValue;self.flags|=32;}
@end
@interface BsPresentationStats : NSObject {
@public atomic_uint_fast64_t frames,lastTime,intervalSum,histogram[20000];
}
@end
@implementation BsPresentationStats
@end
struct BsWindow {
    CFTypeRef window,view,state,slider,device,queue,upload,display,linear,blurred,displayColor,scaler,blur,statistics;
    uint32_t width,height,outputWidth,outputHeight;
    float sigma;
    double gpuSeconds;
};
static id obj(CFTypeRef value) {return (__bridge id)value;}
static void save(CFTypeRef *target,id value) {if(*target)CFRelease(*target);*target=value?CFBridgingRetain(value):NULL;}
static NSString *displaySource=@"#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void upload(device const float4 *pixels [[buffer(0)]],texture2d<half,access::write> image [[texture(0)]],uint2 p [[thread_position_in_grid]]){if(p.x<image.get_width()&&p.y<image.get_height())image.write(half4(pixels[p.y*image.get_width()+p.x]),p);}\n"
"float3 hable(float3 x){return ((x*(.15f*x+.05f)+.004f)/(x*(.15f*x+.5f)+.06f))-.02f/.3f;}\n"
"kernel void display(texture2d<half,access::read> direct [[texture(0)]],texture2d<half,access::read> blur [[texture(1)]],texture2d<float,access::write> output [[texture(2)]],constant float2 &optics [[buffer(0)]],uint2 p [[thread_position_in_grid]]){if(p.x>=output.get_width()||p.y>=output.get_height())return;float3 c=mix(float3(direct.read(p).rgb),float3(blur.read(p).rgb),optics.y)*optics.x;float3 v=clamp(hable(max(c,0.0f))/hable(float3(11.2f)),0.0f,1.0f);float3 s=select(1.055f*pow(v,float3(1.0f/2.4f))-.055f,12.92f*v,v<=.0031308f);output.write(float4(s,1),p);}\n";
BsWindow *bsWindowCreate(BsGpu *gpu,double duration) {
    @autoreleasepool {
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        id<MTLDevice> device=(__bridge id<MTLDevice>)bsGpuBorrowDevice(gpu);
        if(![MTLFXSpatialScalerDescriptor supportsDevice:device])return NULL;
        BsWindow *w=calloc(1,sizeof(*w));if(!w)return NULL;
        save(&w->device,device);save(&w->queue,[device newCommandQueue]);
        NSError *error=nil;MTLCompileOptions *options=[MTLCompileOptions new];options.mathMode=MTLMathModeSafe;
        id<MTLLibrary> library=[device newLibraryWithSource:displaySource options:options error:&error];
        if(!library){fprintf(stderr,"display shader: %s\n",error.localizedDescription.UTF8String);bsWindowDestroy(w);return NULL;}
        save(&w->upload,[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"upload"] error:&error]);
        save(&w->display,[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"display"] error:&error]);
        if(!w->upload||!w->display){bsWindowDestroy(w);return NULL;}
        NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1280,746) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
        window.title=@"bSim — Space: pause  R: restart  Arrows: scrub  F: fullscreen  L: reload";
        window.releasedWhenClosed=NO;window.contentMinSize=NSMakeSize(480,296);
        BsWindowState *state=[BsWindowState new];window.delegate=state;
        NSView *container=[[NSView alloc] initWithFrame:NSMakeRect(0,0,1280,746)];container.wantsLayer=YES;container.layer.backgroundColor=NSColor.blackColor.CGColor;
        MTKView *view=[[MTKView alloc] initWithFrame:NSMakeRect(0,26,1280,720) device:device];
        view.colorPixelFormat=MTLPixelFormatBGRA8Unorm;view.framebufferOnly=NO;view.paused=YES;view.enableSetNeedsDisplay=NO;
        CGColorSpaceRef colorSpace=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);view.colorspace=colorSpace;CGColorSpaceRelease(colorSpace);
        NSSlider *slider=[NSSlider sliderWithValue:0 minValue:0 maxValue:duration target:state action:@selector(seek:)];slider.frame=NSMakeRect(12,3,1256,20);
        [container addSubview:view];[container addSubview:slider];window.contentView=container;
        save(&w->window,window);save(&w->view,view);save(&w->state,state);save(&w->slider,slider);save(&w->statistics,[BsPresentationStats new]);
        [window center];[window makeKeyAndOrderFront:nil];[NSApp activate];
        return w;
    }
}
void bsWindowDestroy(BsWindow *w) {
    if(!w)return;
    [(NSWindow*)obj(w->window) close];
    CFTypeRef refs[]={w->window,w->view,w->state,w->slider,w->device,w->queue,w->upload,w->display,w->linear,w->blurred,w->displayColor,w->scaler,w->blur,w->statistics};
    for(unsigned i=0;i<sizeof(refs)/sizeof(*refs);i++)if(refs[i])CFRelease(refs[i]);free(w);
}
BsWindowEvent bsWindowPoll(BsWindow *w,double time) {
    @autoreleasepool {
        BsWindowState *state=obj(w->state);NSWindow *window=obj(w->window);
        NSEvent *event;
        while((event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:YES])) {
            if(event.type==NSEventTypeKeyDown) {
                switch(event.keyCode) {
                    case 49:state.flags|=2;break;case 15:state.flags|=4;break;case 37:state.flags|=8;break;
                    case 123:state.seekTime=fmax(0,time-0.5);state.flags|=32;break;
                    case 124:state.seekTime=time+0.5;state.flags|=32;break;
                    case 3:[window toggleFullScreen:nil];break;case 53:state.flags|=1;break;
                    default:[NSApp sendEvent:event];break;
                }
            } else [NSApp sendEvent:event];
        }
        NSSize size=window.contentView.bounds.size;double width=fmin(size.width,(size.height-26)*16/9),height=width*9/16;
        MTKView *view=obj(w->view);view.frame=NSMakeRect((size.width-width)/2,26+(size.height-26-height)/2,width,height);
        NSSlider *slider=obj(w->slider);slider.frame=NSMakeRect(12,3,size.width-24,20);
        if(!(state.flags&32))slider.doubleValue=time;
        [NSApp updateWindows];
        BsWindowEvent out={state.flags,(uint32_t)view.drawableSize.width,(uint32_t)view.drawableSize.height,0,state.seekTime};state.flags=0;return out;
    }
}
static id<MTLTexture> texture(id<MTLDevice> device,MTLPixelFormat format,uint32_t width,uint32_t height) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
    d.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite|MTLTextureUsageRenderTarget;d.storageMode=MTLStorageModePrivate;
    return [device newTextureWithDescriptor:d];
}
int bsWindowPresent(BsWindow *w,BsGpu *gpu,const BsParams *p) {
    @autoreleasepool {
        MTKView *view=obj(w->view);id<CAMetalDrawable> drawable=view.currentDrawable;if(!drawable)return 1;
        uint32_t ow=(uint32_t)drawable.texture.width,oh=(uint32_t)drawable.texture.height,iw=p->image[0],ih=p->image[1];
        id<MTLDevice> device=obj(w->device);
        if(w->width!=iw||w->height!=ih||w->outputWidth!=ow||w->outputHeight!=oh) {
            save(&w->linear,texture(device,MTLPixelFormatRGBA16Float,iw,ih));save(&w->blurred,texture(device,MTLPixelFormatRGBA16Float,iw,ih));save(&w->displayColor,texture(device,MTLPixelFormatBGRA8Unorm,iw,ih));
            MTLFXSpatialScalerDescriptor *d=[MTLFXSpatialScalerDescriptor new];d.inputWidth=iw;d.inputHeight=ih;d.outputWidth=ow;d.outputHeight=oh;
            d.colorTextureFormat=MTLPixelFormatBGRA8Unorm;d.outputTextureFormat=MTLPixelFormatBGRA8Unorm;d.colorProcessingMode=MTLFXSpatialScalerColorProcessingModePerceptual;
            save(&w->scaler,[d newSpatialScalerWithDevice:device]);w->width=iw;w->height=ih;w->outputWidth=ow;w->outputHeight=oh;
        }
        if(!w->linear||!w->blurred||!w->displayColor||!w->scaler)return -1;
        float sigma=fmaxf(1,p->optics[2]*ih);
        if(!w->blur||fabsf(w->sigma-sigma)>0.001f){MPSImageGaussianBlur *blur=[[MPSImageGaussianBlur alloc] initWithDevice:device sigma:sigma];blur.edgeMode=MPSImageEdgeModeClamp;save(&w->blur,blur);w->sigma=sigma;}
        id<MTLCommandBuffer> command=[obj(w->queue) commandBuffer];
        id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:obj(w->upload)];[encoder setBuffer:(__bridge id<MTLBuffer>)bsGpuBorrowColorBuffer(gpu) offset:0 atIndex:0];[encoder setTexture:obj(w->linear) atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(iw,ih,1) threadsPerThreadgroup:MTLSizeMake(16,8,1)];[encoder endEncoding];
        [(MPSImageGaussianBlur*)obj(w->blur) encodeToCommandBuffer:command sourceTexture:obj(w->linear) destinationTexture:obj(w->blurred)];
        encoder=[command computeCommandEncoder];[encoder setComputePipelineState:obj(w->display)];
        [encoder setTexture:obj(w->linear) atIndex:0];[encoder setTexture:obj(w->blurred) atIndex:1];[encoder setTexture:obj(w->displayColor) atIndex:2];[encoder setBytes:p->optics length:8 atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(iw,ih,1) threadsPerThreadgroup:MTLSizeMake(16,8,1)];[encoder endEncoding];
        id<MTLFXSpatialScaler> scaler=obj(w->scaler);scaler.colorTexture=obj(w->displayColor);scaler.outputTexture=drawable.texture;[scaler encodeToCommandBuffer:command];
        BsPresentationStats *statistics=obj(w->statistics);
        [drawable addPresentedHandler:^(id<MTLDrawable> frame){
            if(frame.presentedTime<=0)return;
            uint64_t now=(uint64_t)(frame.presentedTime*1e9),last=atomic_exchange(&statistics->lastTime,now);
            atomic_fetch_add(&statistics->frames,1);
            if(last && now>last){uint64_t interval=now-last;atomic_fetch_add(&statistics->intervalSum,interval);atomic_fetch_add(&statistics->histogram[MIN(interval/100000,19999)],1);}
        }];
        [command presentDrawable:drawable];[command commit];[command waitUntilCompleted];
        w->gpuSeconds+=command.GPUEndTime-command.GPUStartTime;
        return command.status==MTLCommandBufferStatusCompleted?0:-1;
    }
}
void bsWindowResetStats(BsWindow *w) {save(&w->statistics,[BsPresentationStats new]);w->gpuSeconds=0;}
BsPresentation bsWindowStats(BsWindow *w) {
    BsPresentationStats *s=obj(w->statistics);uint64_t frames=atomic_load(&s->frames),sum=atomic_load(&s->intervalSum),rank=frames>1?(uint64_t)ceil((frames-1)*0.99):0,count=0;double p99=0;
    for(int i=0;i<20000;i++){count+=atomic_load(&s->histogram[i]);if(rank && count>=rank){p99=(i+1)*0.1;break;}}
    BsPresentation result={frames,sum?(frames-1)*1e9/sum:0,p99,w->gpuSeconds};return result;
}
void bsWindowSetCooling(BsWindow *w,int cooling) {[(NSWindow*)obj(w->window) setTitle:cooling?@"bSim — Cooling":@"bSim — Space: pause  R: restart  Arrows: scrub  F: fullscreen  L: reload"];}
