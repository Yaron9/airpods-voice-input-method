#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDShared.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#include <CoreGraphics/CGEventSource.h>
#include <mach/mach.h>
#include <string.h>

static io_connect_t connection = IO_OBJECT_NULL;

uint64_t fn_injector_merge_flags(uint64_t current_flags, int down) {
    if (down) return current_flags | NX_SECONDARYFNMASK;
    return current_flags & ~((uint64_t)NX_SECONDARYFNMASK);
}

int fn_injector_open(void) {
    if (connection != IO_OBJECT_NULL) return KERN_SUCCESS;
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass));
    if (service == IO_OBJECT_NULL) return KERN_FAILURE;
    kern_return_t result = IOServiceOpen(
        service, mach_task_self(), kIOHIDParamConnectType, &connection);
    IOObjectRelease(service);
    return result;
}

int fn_injector_post(int down) {
    if (connection == IO_OBJECT_NULL) {
        kern_return_t result = fn_injector_open();
        if (result != KERN_SUCCESS) return result;
    }
    NXEventData event;
    memset(&event, 0, sizeof(event));
    event.key.keyCode = 63;
    CGEventFlags current_flags = CGEventSourceFlagsState(
        kCGEventSourceStateHIDSystemState);
    IOOptionBits merged_flags = (IOOptionBits)fn_injector_merge_flags(
        current_flags, down);
    return IOHIDPostEvent(
        connection, NX_FLAGSCHANGED, (IOGPoint){0, 0}, &event,
        kNXEventDataVersion, merged_flags,
        kIOHIDSetGlobalEventFlags | kIOHIDPostHIDManagerEvent);
}

void fn_injector_close(void) {
    if (connection == IO_OBJECT_NULL) return;
    IOServiceClose(connection);
    connection = IO_OBJECT_NULL;
}
