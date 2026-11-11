/*
 * machprobe.c  -  sandbox-profile mach-lookup REACHABILITY auditor (blue-team).
 *
 * Purpose: verify that a given sandbox-exec profile DENIES the bootstrap handshake
 * to privilege-granting mach services, and KEEPS the few a network CLI needs.
 *
 * It only performs a reachability handshake: bootstrap_look_up() returns whether the
 * name resolves and the sandbox permits the lookup. It NEVER sends a message on the
 * returned port, so it opens no app, posts no event, reads no clipboard/keychain,
 * triggers no TCC/GUI prompt. Any returned send right is immediately deallocated.
 *
 * Usage: machprobe <service-name> [<service-name> ...]
 * Output: one line per name:  REACHABLE rc=0   |   denied rc=<n>   <name>
 */
#include <stdio.h>
#include <mach/mach.h>
#include <bootstrap.h>

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        mach_port_t sp = MACH_PORT_NULL;
        kern_return_t kr = bootstrap_look_up(bootstrap_port, argv[i], &sp);
        if (kr == KERN_SUCCESS) {
            printf("REACHABLE rc=0   %s\n", argv[i]);
            if (sp != MACH_PORT_NULL)
                mach_port_deallocate(mach_task_self(), sp); /* drop the right; never message it */
        } else {
            printf("denied    rc=%d %s\n", (int)kr, argv[i]);
        }
    }
    return 0;
}
