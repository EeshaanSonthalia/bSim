#ifndef BSIM_WINDOW_H
#define BSIM_WINDOW_H
#include "renderer.h"
typedef struct BsWindow BsWindow;
typedef struct {uint32_t flags,width,height,reserved;double seekTime;} BsWindowEvent;
typedef struct {uint64_t frames;double fps,p99Milliseconds,gpuSeconds;} BsPresentation;
/* Own the returned window. Calls must run on the main application thread. */
BsWindow *bsWindowCreate(BsGpu *gpu,double duration);
void bsWindowDestroy(BsWindow *window);
BsWindowEvent bsWindowPoll(BsWindow *window,double time);
int bsWindowPresent(BsWindow *window,BsGpu *gpu,const BsParams *params);
void bsWindowResetStats(BsWindow *window);
BsPresentation bsWindowStats(BsWindow *window);
void bsWindowSetCooling(BsWindow *window,int cooling);
#endif
