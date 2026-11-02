#include "AgentSandboxProbe.h"

// libsystem_sandbox's check, which Swift cannot call because it is variadic. Asking about another process needs no
// rights over it, and a process cannot change the answer: its sandbox is inherited and held by the kernel.
extern int sandbox_check(pid_t pid, const char *operation, int type, ...);

enum { filter_none = 0, filter_global_name = 2, no_report = 0x40000000 };

int sprava_sandbox_denies_name(pid_t pid, const char *name) {
    return sandbox_check(pid, "mach-lookup", filter_global_name | no_report, name);
}

int sprava_is_sandboxed(pid_t pid) {
    return sandbox_check(pid, NULL, filter_none);
}
