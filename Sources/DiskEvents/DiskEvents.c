#include "DiskEvents.h"
#include <DiskArbitration/DiskArbitration.h>
#include <stdlib.h>

typedef struct {
    DASessionRef session;
    void (*callback)(void *);
    void *context;
} Monitor;
static void changed(DADiskRef disk, void *context) {
    Monitor *m = context;
    m->callback(m->context);
}
static void descriptionChanged(DADiskRef disk, CFArrayRef keys, void *context) {
    changed(disk, context);
}
void *RufusDiskEventsStart(void (*callback)(void *), void *context) {
    Monitor *m = calloc(1, sizeof(Monitor));
    if (!m) return NULL;
    m->session = DASessionCreate(kCFAllocatorDefault);
    if (!m->session) { free(m); return NULL; }
    m->callback = callback;
    m->context = context;
    DARegisterDiskAppearedCallback(m->session, NULL, changed, m);
    DARegisterDiskDisappearedCallback(m->session, NULL, changed, m);
    DARegisterDiskDescriptionChangedCallback(m->session, NULL, NULL, descriptionChanged, m);
    DASessionScheduleWithRunLoop(m->session, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    return m;
}
void RufusDiskEventsStop(void *monitor) {
    if (!monitor) return;
    Monitor *m = monitor;
    DASessionUnscheduleFromRunLoop(m->session, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    DAUnregisterCallback(m->session, changed, m);
    DAUnregisterCallback(m->session, descriptionChanged, m);
    CFRelease(m->session);
    free(m);
}
