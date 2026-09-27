#ifndef BSIM_THERMAL_H
#define BSIM_THERMAL_H
#include <stdint.h>
typedef struct BsMonitor BsMonitor;
typedef struct {
    double batteryC;
    double cpuC;
    double gpuC;
    double sampleTime;
    uint32_t thermalState;
    uint32_t valid;
} BsTemperatures;
/* Own the returned monitor. Read-only SMC access. NULL means unavailable. */
BsMonitor *bsMonitorCreate(void);
void bsMonitorDestroy(BsMonitor *monitor);
/* Maximum of available M4 die sensors. Missing groups invalidate the sample. */
BsTemperatures bsMonitorRead(BsMonitor *monitor);
double bsMonotonicTime(void);
/* Install signal handlers that request Zig-owned cancellation at the next gate. */
void bsInstallSignals(void);
int bsIsCancelled(void);
#endif
