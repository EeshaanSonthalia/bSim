#import "export.h"
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <OpenEXR/openexr.h>

int bsWritePng(const char *path,uint32_t width,uint32_t height,const uint16_t *rgba) {
    @autoreleasepool {
        CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGDataProviderRef provider=CGDataProviderCreateWithData(NULL,rgba,(size_t)width*height*8,NULL);
        CGImageRef image=CGImageCreate(width,height,16,64,width*8,space,kCGBitmapByteOrder16Little|kCGImageAlphaLast,provider,NULL,false,kCGRenderingIntentDefault);
        CGColorSpaceRelease(space);CGDataProviderRelease(provider);
        if(!image) return -1;
        NSURL *url=[NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        CGImageDestinationRef output=CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,NULL);
        if(!output) {CGImageRelease(image);return -1;}
        NSDictionary *properties=@{(__bridge NSString*)kCGImagePropertyPNGDictionary:@{(__bridge NSString*)kCGImagePropertyPNGsRGBIntent:@0}};
        CGImageDestinationAddImage(output,image,(__bridge CFDictionaryRef)properties);
        bool ok=CGImageDestinationFinalize(output);
        CFRelease(output);CGImageRelease(image);
        return ok?0:-1;
    }
}
int bsWriteExr(const char *path,uint32_t width,uint32_t height,const float *rgba) {
    exr_context_t context=NULL;
    exr_result_t result=exr_start_write(&context,path,EXR_WRITE_FILE_DIRECTLY,NULL);
    if(result!=EXR_ERR_SUCCESS) return (int)result;
    int part=0;
    result=exr_add_part(context,NULL,EXR_STORAGE_SCANLINE,&part);
    if(result==EXR_ERR_SUCCESS) result=exr_initialize_required_attr_simple(context,part,(int32_t)width,(int32_t)height,EXR_COMPRESSION_ZIP);
    const char *names[]={"R","G","B"};
    for(int c=0;c<3 && result==EXR_ERR_SUCCESS;c++) result=exr_add_channel(context,part,names[c],EXR_PIXEL_HALF,EXR_PERCEPTUALLY_LOGARITHMIC,1,1);
    exr_attr_chromaticities_t primaries={0.64f,0.33f,0.30f,0.60f,0.15f,0.06f,0.3127f,0.3290f};
    if(result==EXR_ERR_SUCCESS) result=exr_attr_set_chromaticities(context,part,"chromaticities",&primaries);
    if(result==EXR_ERR_SUCCESS) result=exr_attr_set_string(context,part,"software","bSim 0.1.0 scene-linear Rec.709");
    if(result==EXR_ERR_SUCCESS) result=exr_write_header(context);
    exr_encode_pipeline_t pipeline={.pipe_size=sizeof(exr_encode_pipeline_t)};
    bool initialized=false;
    for(uint32_t y=0;y<height && result==EXR_ERR_SUCCESS;) {
        exr_chunk_info_t chunk;
        result=exr_write_scanline_chunk_info(context,part,(int)y,&chunk);
        if(result!=EXR_ERR_SUCCESS) break;
        if(!initialized) {result=exr_encoding_initialize(context,part,&chunk,&pipeline);initialized=result==EXR_ERR_SUCCESS;}
        else result=exr_encoding_update(context,part,&chunk,&pipeline);
        if(result!=EXR_ERR_SUCCESS) break;
        for(int c=0;c<pipeline.channel_count;c++) {
            exr_coding_channel_info_t *channel=&pipeline.channels[c];
            int index=channel->channel_name[0]=='R'?0:channel->channel_name[0]=='G'?1:2;
            channel->user_data_type=EXR_PIXEL_FLOAT;
            channel->user_bytes_per_element=4;
            channel->user_pixel_stride=16;
            channel->user_line_stride=(int32_t)width*16;
            channel->encode_from_ptr=(const uint8_t*)(rgba+((size_t)y*width*4)+index);
        }
        if(result==EXR_ERR_SUCCESS) result=exr_encoding_choose_default_routines(context,part,&pipeline);
        if(result==EXR_ERR_SUCCESS) result=exr_encoding_run(context,part,&pipeline);
        y+=(uint32_t)chunk.height;
    }
    if(initialized) {exr_result_t cleanup=exr_encoding_destroy(context,&pipeline);if(result==EXR_ERR_SUCCESS)result=cleanup;}
    exr_result_t finish=exr_finish(&context);
    return (int)(result==EXR_ERR_SUCCESS?finish:result);
}
