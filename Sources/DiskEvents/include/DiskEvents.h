#ifndef RUFUS_DISK_EVENTS_H
#define RUFUS_DISK_EVENTS_H
/* Start/stop on the main thread. Callback is delivered on the main run loop. */
void *RufusDiskEventsStart(void (*callback)(void *), void *context);
void RufusDiskEventsStop(void *monitor);
#endif
