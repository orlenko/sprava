#ifndef AGENT_SANDBOX_PROBE_H
#define AGENT_SANDBOX_PROBE_H
#include <sys/types.h>

/// 1 when the kernel says this process's sandbox denies looking up `name`, 0 when it allows it, negative on error.
int sprava_sandbox_denies_name(pid_t pid, const char *name);
/// 1 when the process runs in any sandbox.
int sprava_is_sandboxed(pid_t pid);
#endif
