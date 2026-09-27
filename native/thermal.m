#import "thermal.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint32_t key;
    struct { uint8_t major, minor, build, reserved; uint16_t release; } version;
    struct { uint16_t version, length; uint32_t cpu, gpu, memory; } limits;
    struct { uint32_t size, type; uint8_t attributes; } info;
    uint8_t result, status, command;
    uint32_t index;
    uint8_t bytes[32];
} SmcMessage;
_Static_assert(sizeof(SmcMessage) == 80, "SMC ABI size");
_Static_assert(offsetof(SmcMessage, bytes) == 48, "SMC ABI payload");
_Static_assert(sizeof(BsTemperatures) == 40, "temperature ABI size");
struct BsMonitor {
    io_connect_t connection;
    uint32_t cpuKeys[32], gpuKeys[16], batteryKeys[4];
    size_t cpuCount, gpuCount, batteryCount;
};
static uint32_t keyCode(const char *s) {
    return (uint32_t)(uint8_t)s[0]<<24 | (uint32_t)(uint8_t)s[1]<<16 |
           (uint32_t)(uint8_t)s[2]<<8 | (uint8_t)s[3];
}
static double readKey(BsMonitor *m, uint32_t key) {
    SmcMessage in = {0}, out = {0};
    in.key = key;
    in.command = 9;
    size_t size = sizeof(out);
    if (IOConnectCallStructMethod(m->connection, 2, &in, sizeof(in), &out, &size) || out.result || size != sizeof(out)) return NAN;
    if (!out.info.size || out.info.size > 32) return NAN;
    uint32_t type = out.info.type;
    in.info = out.info;
    in.command = 5;
    size = sizeof(out);
    if (IOConnectCallStructMethod(m->connection, 2, &in, sizeof(in), &out, &size) || out.result || size != sizeof(out)) return NAN;
    double result = NAN;
    if (type == keyCode("flt ") && in.info.size == 4) {
        float f;
        memcpy(&f, out.bytes, sizeof(f));
        result = f;
    } else if (type == keyCode("sp78") && in.info.size == 2) {
        result = (int16_t)((out.bytes[0] << 8) | out.bytes[1]) / 256.0;
    }
    return isfinite(result) && result > 0 && result < 130 ? result : NAN;
}
static void discover(BsMonitor *m, const char **names, size_t count, uint32_t *keys, size_t *found) {
    for (size_t i = 0; i < count; i++) {
        uint32_t key = keyCode(names[i]);
        if (isfinite(readKey(m, key))) keys[(*found)++] = key;
    }
}
BsMonitor *bsMonitorCreate(void) {
    BsMonitor *m = calloc(1, sizeof(*m));
    if (!m) return NULL;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) { free(m); return NULL; }
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &m->connection);
    IOObjectRelease(service);
    if (result) { free(m); return NULL; }
    const char *cpu[] = {"Te05","Te0S","Te09","Te0H","Tp01","Tp05","Tp09","Tp0D","Tp0V","Tp0Y","Tp0b","Tp0e"};
    const char *gpu[] = {"Tg0G","Tg0H","Tg0K","Tg0L","Tg0d","Tg0e","Tg0j","Tg0k","Tg1U","Tg1k"};
    const char *battery[] = {"TB1T", "TB2T"};
    discover(m, cpu, sizeof(cpu)/sizeof(*cpu), m->cpuKeys, &m->cpuCount);
    discover(m, gpu, sizeof(gpu)/sizeof(*gpu), m->gpuKeys, &m->gpuCount);
    discover(m, battery, sizeof(battery)/sizeof(*battery), m->batteryKeys, &m->batteryCount);
    return m;
}
void bsMonitorDestroy(BsMonitor *m) {
    if (m) { IOServiceClose(m->connection); free(m); }
}
double bsMonotonicTime(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (double)value.tv_sec + value.tv_nsec * 1e-9;
}
static double maxKeys(BsMonitor *m, uint32_t *keys, size_t count) {
    if (!count) return NAN;
    double highest = 0;
    for (size_t i = 0; i < count; i++) {
        double value = readKey(m, keys[i]);
        if (!isfinite(value)) return NAN;
        highest = fmax(highest, value);
    }
    return highest;
}
BsTemperatures bsMonitorRead(BsMonitor *m) {
    BsTemperatures out = {NAN, NAN, NAN, bsMonotonicTime(), 0, 0};
    if (!m) return out;
    @autoreleasepool {
        out.batteryC = maxKeys(m, m->batteryKeys, m->batteryCount);
        out.cpuC = maxKeys(m, m->cpuKeys, m->cpuCount);
        out.gpuC = maxKeys(m, m->gpuKeys, m->gpuCount);
        out.thermalState = (uint32_t)NSProcessInfo.processInfo.thermalState;
        out.valid = isfinite(out.batteryC) && isfinite(out.cpuC) && isfinite(out.gpuC);
    }
    return out;
}
#ifdef BSIM_THERMAL_TOOL
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
    BsMonitor *m = bsMonitorCreate();
    do {
        BsTemperatures t = bsMonitorRead(m);
        if (!t.valid) { fprintf(stderr, "bSim: thermal sensors unavailable\n"); bsMonitorDestroy(m); return 2; }
        printf("{\"batteryC\":%.3f,\"cpuC\":%.3f,\"gpuC\":%.3f,\"thermalState\":%u,\"sampleTime\":%.6f}\n", t.batteryC,t.cpuC,t.gpuC,t.thermalState,t.sampleTime);
        fflush(stdout);
        if (argc < 2 || strcmp(argv[1], "--watch")) break;
        usleep(250000);
    } while (1);
    bsMonitorDestroy(m);
    return 0;
}
#endif
