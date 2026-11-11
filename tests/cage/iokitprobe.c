/* iokitprobe.c: whether this process may open an IOKit user client (iokit-open). It opens one on IOPMrootDomain (the
 * power-management root any user process may open, as pmset and caffeinate do), calls nothing on it and closes it.
 * Output: OPEN, or DENIED kr=<n>. */
#include <stdio.h>
#include <IOKit/IOKitLib.h>

int main(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!svc) { printf("NOSERVICE\n"); return 2; }
    io_connect_t conn = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    if (kr == KERN_SUCCESS) { IOServiceClose(conn); printf("OPEN\n"); return 0; }
    printf("DENIED kr=0x%x\n", kr);
    return 1;
}
