#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include "macos_utils.h"
#include <mach/mach.h>
#include <mach/vm_statistics.h>
#include <mach/mach_host.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <libgen.h>
#include <sys/mman.h>
#include <errno.h>
#include <signal.h>
/* Leak killer additions: pwd.h -> getpwuid_r (owner username),
   time.h -> time()/time_t (wall-clock age), stdio.h -> snprintf/fprintf
   (was previously resolved only transitively — made explicit here). */
#include <pwd.h>
#include <time.h>
#include <stdio.h>

uint64_t get_page_size_c(void) {
    vm_size_t page_size;
    if (host_page_size(mach_host_self(), &page_size) == KERN_SUCCESS) {
        return page_size;
    }
    return 4096; // Fallback
}

uid_t get_console_uid_c(void) {
    struct stat sb;
    if (stat("/dev/console", &sb) == 0) {
        return sb.st_uid;
    }
    return 0;
}

int get_memory_pressure_level_c(void) {
    int pressure = 1;
    size_t size = sizeof(pressure);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, NULL, 0) == 0) {
        return pressure;
    }
    return 1;
}

double get_free_mb_c(uint64_t page_size) {
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_statistics64_data_t vm_stat;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm_stat, &count) == KERN_SUCCESS) {
        return (vm_stat.free_count * page_size) / (1024.0 * 1024.0);
    }
    return 0.0;
}

double get_wired_mb_c(uint64_t page_size) {
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_statistics64_data_t vm_stat;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm_stat, &count) == KERN_SUCCESS) {
        return (vm_stat.wire_count * page_size) / (1024.0 * 1024.0);
    }
    return 0.0;
}

/*
 * get_compressor_mb_c — size of the VM compressor's occupied pages, in MB.
 *
 * AXIOMS:
 *   A1: host_statistics64(HOST_VM_INFO64) is the same source Activity
 *       Monitor uses for its Memory pane (XNU kern/kern_mach.c).
 *   A2: On failure the function returns 0.0 (caller logs MB=0 and treats it
 *       as "unknown", never as "compressor empty") — verbose error reporting:
 *       the Ada layer prints the value unconditionally so a sustained 0.0
 *       series is visible in the log.
 *
 * CITATIONS:
 *   [1] XNU source, osfmk/mach/host_info.h — HOST_VM_INFO64 / compressor_page_count
 *       https://github.com/apple-oss-distributions/xnu
 *   [2] Activity Monitor "Memory" tab uses the same vm_statistics64 fields.
 *
 * TIMING: O(1) — single sysctl-class Mach trap. WCET < 50us.
 */
double get_compressor_mb_c(uint64_t page_size) {
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_statistics64_data_t vm_stat;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm_stat, &count) == KERN_SUCCESS) {
        return ((uint64_t)vm_stat.compressor_page_count * page_size) / (1024.0 * 1024.0);
    }
    return 0.0;
}

/*
 * get_swap_usage_c — swap partition usage (the "Swap Used" line of Activity
 * Monitor / vm.swapusage), in MB.
 *
 * AXIOMS:
 *   A1: sysctlbyname("vm.swapusage") returns struct xsw_usage whose fields
 *       (xsu_total/xsu_avail/xsu_used) are in BYTES [1, Apple sysctl(3)].
 *   A2: On failure both outputs are set to 0.0 so Ada sees a defined value
 *       (never uninitialized stack memory) — Murphy's Law: sysctl CAN fail
 *       (e.g. swap not yet configured on early boot).
 *
 * CITATIONS:
 *   [1] Apple man sysctl(3) — vm.swapusage, struct xsw_usage
 *       https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/sysctl.3.html
 *   [2] XNU osfmk/vm/vm_swapout.c — swap accounting
 *
 * TIMING: O(1) — single sysctlbyname. WCET < 50us.
 */
void get_swap_usage_c(double *out_total_mb, double *out_used_mb) {
    struct xsw_usage swap;
    size_t size = sizeof(swap);
    if (out_total_mb == NULL || out_used_mb == NULL) {
        fprintf(stderr, "[MACOS_UTILS ERROR] get_swap_usage_c: NULL output pointer\n");
        return;
    }
    if (sysctlbyname("vm.swapusage", &swap, &size, NULL, 0) == 0) {
        *out_total_mb = (double)swap.xsu_total / (1024.0 * 1024.0);
        *out_used_mb  = (double)swap.xsu_used  / (1024.0 * 1024.0);
    } else {
        fprintf(stderr, "[MACOS_UTILS ERROR] sysctlbyname(vm.swapusage) failed: %s\n",
                strerror(errno));
        *out_total_mb = 0.0;
        *out_used_mb  = 0.0;
    }
}

uint64_t get_process_memory_c(int pid) {
    struct proc_taskinfo pti;
    if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &pti, sizeof(pti)) == sizeof(pti)) {
        return pti.pti_resident_size;
    }
    return 0;
}

int get_frontmost_pid_c(void) {
    int result_pid = 0;
    @autoreleasepool {
        CFArrayRef windowList = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
        if (windowList) {
            for (CFIndex i = 0; i < CFArrayGetCount(windowList); i++) {
                CFDictionaryRef windowInfo = (CFDictionaryRef)CFArrayGetValueAtIndex(windowList, i);
                int layer = -1;
                CFNumberRef layerNumber = (CFNumberRef)CFDictionaryGetValue(windowInfo, kCGWindowLayer);
                if (layerNumber) {
                    CFNumberGetValue(layerNumber, kCFNumberIntType, &layer);
                }
                if (layer == 0) {
                    CFNumberRef pidNumber = (CFNumberRef)CFDictionaryGetValue(windowInfo, kCGWindowOwnerPID);
                    if (pidNumber) {
                        int pid = 0;
                        CFNumberGetValue(pidNumber, kCFNumberIntType, &pid);
                        if (pid > 0 && pid != getpid()) {
                            result_pid = pid;
                            break;
                        }
                    }
                }
            }
            CFRelease(windowList);
        }
    }
    return result_pid;
}

void get_process_name_c(int pid, char *out_name, int max_len) {
    char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, pathbuf, sizeof(pathbuf)) > 0) {
        char *bname = basename(pathbuf);
        strncpy(out_name, bname, max_len - 1);
        out_name[max_len - 1] = '\0';
    } else {
        strncpy(out_name, "unknown", max_len - 1);
        out_name[max_len - 1] = '\0';
    }
}

void get_process_path_c(int pid, char *out_path, int max_len) {
    char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, pathbuf, sizeof(pathbuf)) > 0) {
        strncpy(out_path, pathbuf, max_len - 1);
        out_path[max_len - 1] = '\0';
    } else {
        strncpy(out_path, "", max_len - 1);
        out_path[max_len - 1] = '\0';
    }
}

// Thread-safe basename extraction (POSIX basename() may modify its input or
// return a static buffer shared across concurrent callers; this pure helper
// has neither problem). Returns pointer INTO path -- no allocation, no copy.
static const char *path_basename_of(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

// Case-insensitive substring test. Used for the owner-mandated guard:
// any process whose executable path contains "hermes", "syncthing" or
// "omlx" in ANY case is never a kill candidate.
static int path_contains_ci(const char *hay, const char *needle) {
    if (!hay || !needle || !*needle) return 0;
    const size_t n = strlen(needle);
    for (const char *p = hay; *p; ++p) {
        size_t i = 0;
        while (i < n && p[i] &&
               tolower((unsigned char)p[i]) == tolower((unsigned char)needle[i])) {
            ++i;
        }
        if (i == n) return 1;
    }
    return 0;
}

int is_system_process_c(const char *path) {
    if (!path) return 1;

    // Owner mandate (2026-11-02): protect every process whose executable
    // path contains "hermes", "syncthing" or "omlx", case-insensitively.
    // Substring (not basename) so helpers under a matching directory are
    // covered too.
    if (path_contains_ci(path, "hermes") ||
        path_contains_ci(path, "syncthing") ||
        path_contains_ci(path, "omlx")) return 1;

    const char *force_tame[] = {
        "ReportCrash", "warp-dex", "contactsd", "AddressBookManager",
        "Control Center", "Notification Center", "sysmond", "BiomeAgent",
        "duetexpertd", "coreduet", "cloudd", "airportd", "locationd", "symptomsd"
    };
    for (int i = 0; i < 14; i++) {
        if (strstr(path, force_tame[i])) return 0;
    }

    if (strstr(path, "Frameworks") ||
        strstr(path, "CoreServices") ||
        strstr(path, "/System/Library/CoreServices/") ||
        strstr(path, "/usr/libexec") ||
        strstr(path, "/System/Library/DriverExtensions") ||
        strstr(path, "/System/Library/ExtensionKit") ||
        strstr(path, "/Library/SystemExtensions")) return 1;

    // Exact-basename matching (audit 🟡18/🔵32): the previous strstr() scan
    // matched these names ANYWHERE in the path, so e.g. "/Users/x/myDockHelper"
    // was protected because of "Dock". Protection must be precise: a process
    // is on this list iff its final path component equals an entry exactly.
    // Path-STRUCTURE checks above (Frameworks, CoreServices, /usr/libexec)
    // intentionally remain substring-based: they describe locations, not names.
    const char *excluded[] = {
        "kernel_task", "WindowServer", "launchd", "sysmond", "apsd", "configd", "powerd",
        "coreaudiod", "loginwindow", "ScreenSaverEngine", "coreauthd", "SecurityAgent",
        "Dock", "SystemUIServer", "Finder", "runningboardd", "UserEventAgent", "lsd", "mDNSResponder",
        "FSUSBDriverIsolationBridge", "launchservicesd", "watchdogd", "rclone", "ffmpeg",
        "entrypoint.sh", "Terminal.app", "Terminal", "WhatsApp", "iTerm2", "iTerm", "iterm", "airportd",
        "oMLX", "omlx-server", "com.apple.Virtualization.VirtualMachine", "qemu-system-aarch64",
        "adelaide_server", "adelaide_watchdog", "syncthing"
    };
    for (int i = 0; i < 38; i++) {
        if (strcmp(path_basename_of(path), excluded[i]) == 0) return 1;
    }

    return 0;
}

int is_gamepolicyctl_available_c(void) {
    return access("/Applications/Xcode.app/Contents/Developer/usr/bin/gamepolicyctl", X_OK) == 0;
}

void set_game_mode_c(const char *state) {
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "/Applications/Xcode.app/Contents/Developer/usr/bin/gamepolicyctl game-mode set %s >/dev/null 2>&1", state);
    system(cmd);
}

int get_parent_pid_c(int pid) {
    struct kinfo_proc info;
    size_t length = sizeof(struct kinfo_proc);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    if (sysctl(mib, 4, &info, &length, NULL, 0) == 0 && length > 0) {
        return info.kp_eproc.e_ppid;
    }
    return -1;
}

int get_process_tree_c(int root_pid, int *out_pids, int max_count) {
    if (root_pid <= 0 || max_count <= 0) return 0;

    int num_pids = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0) / sizeof(pid_t);
    if (num_pids <= 0) return 0;

    pid_t *all_pids = malloc(sizeof(pid_t) * (num_pids + 100));
    if (all_pids == NULL) {
        fprintf(stderr, "[MACOS_UTILS ERROR] malloc(%zu) failed for process list in %s\n",
                (size_t)(sizeof(pid_t) * (num_pids + 100)), __func__);
        return 0;
    }
    num_pids = proc_listpids(PROC_ALL_PIDS, 0, all_pids, sizeof(pid_t) * (num_pids + 100)) / sizeof(pid_t);

    int count = 0;
    int queue_capacity = num_pids + 100;
    int *queue = malloc(sizeof(int) * queue_capacity);
    if (queue == NULL) {
        fprintf(stderr, "[MACOS_UTILS ERROR] malloc(%zu) failed for BFS queue in %s\n",
                (size_t)(sizeof(int) * queue_capacity), __func__);
        free(all_pids);
        return 0;
    }
    int head = 0;
    int tail = 0;

    if (tail < queue_capacity) {
        queue[tail++] = root_pid;
    } else {
        fprintf(stderr, "[MACOS_UTILS ERROR] process-tree BFS queue full (cap=%d) in %s\n", queue_capacity, __func__);
    }
    out_pids[count++] = root_pid;

    while (head < tail && count < max_count) {
        int cur = queue[head++];
        for (int i = 0; i < num_pids; i++) {
            pid_t pid = all_pids[i];
            if (pid == 0 || pid == cur) continue;
            if (get_parent_pid_c(pid) == cur) {
                int dup = 0;
                for (int j = 0; j < count; j++) {
                    if (out_pids[j] == pid) { dup = 1; break; }
                }
                if (!dup && count < max_count) {
                    out_pids[count++] = pid;
                    if (tail < queue_capacity) {
                        queue[tail++] = pid;
                    } else {
                        fprintf(stderr, "[MACOS_UTILS ERROR] process-tree BFS queue full (cap=%d) in %s\n", queue_capacity, __func__);
                    }
                }
            }
        }
    }

    free(all_pids);
    free(queue);
    return count;
}

void set_process_priority_c(int pid, int priority) {
    setpriority(PRIO_PROCESS, pid, priority);
}

void get_memory_snapshot_c(uint64_t *out_faults, uint64_t *out_pageins, uint64_t *out_decomp) {
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_statistics64_data_t vm_stat;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm_stat, &count) == KERN_SUCCESS) {
        *out_faults = vm_stat.faults;
        *out_pageins = vm_stat.pageins;
        *out_decomp = vm_stat.decompressions;
    } else {
        *out_faults = 0;
        *out_pageins = 0;
        *out_decomp = 0;
    }
}

typedef struct {
    int pid;
    uint64_t resident_size;
} ProcessEntry;

static int compare_proc_entries(const void *a, const void *b) {
    uint64_t memA = ((ProcessEntry *)a)->resident_size;
    uint64_t memB = ((ProcessEntry *)b)->resident_size;
    if (memA > memB) return -1;
    if (memA < memB) return 1;
    return 0;
}

int get_top_processes_by_memory_c(int *out_pids, uint64_t *out_resident_bytes, int n, int exclude_pid) {
    int num_pids = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0) / sizeof(pid_t);
    if (num_pids <= 0) return 0;

    pid_t *all_pids = malloc(sizeof(pid_t) * (num_pids + 100));
    if (all_pids == NULL) {
        fprintf(stderr, "[MACOS_UTILS ERROR] malloc(%zu) failed for process list in %s\n",
                (size_t)(sizeof(pid_t) * (num_pids + 100)), __func__);
        return 0;
    }
    num_pids = proc_listpids(PROC_ALL_PIDS, 0, all_pids, sizeof(pid_t) * (num_pids + 100)) / sizeof(pid_t);

    ProcessEntry *entries = malloc(sizeof(ProcessEntry) * num_pids);
    if (entries == NULL) {
        fprintf(stderr, "[MACOS_UTILS ERROR] malloc(%zu) failed for process entries in %s\n",
                (size_t)(sizeof(ProcessEntry) * num_pids), __func__);
        free(all_pids);
        return 0;
    }
    int entry_count = 0;

    for (int i = 0; i < num_pids; i++) {
        pid_t pid = all_pids[i];
        if (pid < 200 || pid == exclude_pid) continue;

        struct proc_taskinfo pti;
        if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &pti, sizeof(pti)) == sizeof(pti)) {
            char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
            if (proc_pidpath(pid, pathbuf, sizeof(pathbuf)) > 0) {
                char *bname = basename(pathbuf);

                /* Blacklisted processes are skipped (not deprioritized here).
                   Deprioritization is handled by deprioritize_blacklisted_c(). */
                const char *blacklist[] = {
                    "oMLX", "omlx-server", "com.apple.Virtualization.VirtualMachine", "qemu-system-aarch64"
                };
                int blacklisted = 0;
                for (int b = 0; b < 4; b++) {
                    if (strcmp(bname, blacklist[b]) == 0) {
                        blacklisted = 1;
                        break;
                    }
                }
                // Path-based exclusion: any process under an omlx/oMLX directory.
                if (!blacklisted && (strstr(pathbuf, "omlx") || strstr(pathbuf, "oMLX") || strstr(pathbuf, "OMLX"))) {
                    blacklisted = 1;
                }
                if (blacklisted) continue;

                entries[entry_count].pid = pid;
                entries[entry_count].resident_size = pti.pti_resident_size;
                entry_count++;
            }
        }
    }

    qsort(entries, entry_count, sizeof(ProcessEntry), compare_proc_entries);

    int returned = 0;
    for (int i = 0; i < entry_count && i < n; i++) {
        out_pids[i] = entries[i].pid;
        out_resident_bytes[i] = entries[i].resident_size;
        returned++;
    }

    free(all_pids);
    free(entries);
    return returned;
}

typedef struct {
    int pid;
    uint64_t footprint;
} FootprintEntry;

static int compare_footprint_entries(const void *a, const void *b) {
    uint64_t fpA = ((const FootprintEntry *)a)->footprint;
    uint64_t fpB = ((const FootprintEntry *)b)->footprint;
    if (fpA > fpB) return -1;  /* descending: biggest footprint first */
    if (fpA < fpB) return 1;
    return 0;
}

/*
 * get_top_processes_by_footprint_c — top-N processes by phys_footprint.
 *
 * This is the ACTIVITY MONITOR METHODOLOGY: Activity Monitor's "Memory"
 * column shows ri_phys_footprint (resident + compressed + internal - dirty
 * COW), NOT plain RSS. A process whose pages are all compressed can show
 * RSS=19MB but footprint=1.4GB (observed: python sidecar, PID 55883).
 *
 * AXIOMS:
 *   A1: proc_pid_rusage(pid, RUSAGE_INFO_V4) fills ri_phys_footprint with
 *       the same quantity Activity Monitor displays [1].
 *   A2: daemon runs as root (launchd LaunchDaemon) => rusage succeeds for
 *       all userspace PIDs; failures are skipped (dead/exiting PIDs).
 *   A3: pid < 200 excluded (kernel/launchd-era PIDs), consistent with
 *       get_top_processes_by_memory_c — kernel footprint is reported
 *       separately via wired/compressor metrics.
 *   A4: Unlike get_top_processes_by_memory_c there is NO blacklist filter:
 *       this is read-only monitoring; Activity Monitor shows every
 *       process, so must we (oMLX/qemu entries are meaningful data).
 *
 * THEOREMS:
 *   T1: qsort + descending comparator => out_pids[0] has the largest
 *       footprint among returned PIDs.
 *       PROOF: comparator returns -1 iff a.footprint > b.footprint; qsort
 *       orders per comparator; therefore index 0 is the maximum.
 *
 * CITATIONS:
 *   [1] Apple man proc_pid_rusage / libproc.h — rusage_info_v4.ri_phys_footprint
 *       https://developer.apple.com/documentation/libproc/1462732-proc_pid_rusage
 *   [2] XNU bsd/kern/proc_info.c — proc_pid_rusage implementation
 *   [3] Verified against `sudo footprint <pid>` and Activity Monitor UI
 *       (Lulu PID 689: both report 1540 MB; RSS via ps: only 71 MB).
 *
 * TIMING: O(P log P) — P = process count (~1100 observed), one rusage
 * trap + one proc_pidpath per PID. Typical ~3ms, WCET < 30ms.
 * Space: O(P) transient malloc, freed before return.
 */
int get_top_processes_by_footprint_c(int *out_pids, uint64_t *out_footprint_bytes, int n, int exclude_pid) {
    if (out_pids == NULL || out_footprint_bytes == NULL || n <= 0) {
        fprintf(stderr, "[MACOS_UTILS ERROR] get_top_processes_by_footprint_c: invalid args (n=%d)\n", n);
        return 0;
    }
    int num_pids = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0) / sizeof(pid_t);
    if (num_pids <= 0) {
        fprintf(stderr, "[MACOS_UTILS ERROR] proc_listpids returned %d in %s\n", num_pids, __func__);
        return 0;
    }

    pid_t *all_pids = malloc(sizeof(pid_t) * (num_pids + 100));
    if (all_pids == NULL) {
        fprintf(stderr, "[MACOS_UTILS ERROR] malloc(%zu) failed for process list in %s\n",
                (size_t)(sizeof(pid_t) * (num_pids + 100)), __func__);
        return 0;
    }
    num_pids = proc_listpids(PROC_ALL_PIDS, 0, all_pids, sizeof(pid_t) * (num_pids + 100)) / sizeof(pid_t);

    FootprintEntry *entries = malloc(sizeof(FootprintEntry) * (size_t)num_pids);
    if (entries == NULL) {
        fprintf(stderr, "[MACOS_UTILS ERROR] malloc(%zu) failed for footprint entries in %s\n",
                (size_t)(sizeof(FootprintEntry) * (size_t)num_pids), __func__);
        free(all_pids);
        return 0;
    }
    int entry_count = 0;

    for (int i = 0; i < num_pids; i++) {
        pid_t pid = all_pids[i];
        if (pid < 200 || pid == exclude_pid) continue;  /* A3 */

        struct rusage_info_v4 ri;
        memset(&ri, 0, sizeof(ri));
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t)&ri) == 0) {
            entries[entry_count].pid = (int)pid;
            entries[entry_count].footprint = ri.ri_phys_footprint;  /* A1 */
            entry_count++;
        }
        /* A2: rusage failure = inaccessible/exiting PID, skip silently
           (common race with short-lived processes; not an error state). */
    }

    qsort(entries, (size_t)entry_count, sizeof(FootprintEntry), compare_footprint_entries);

    int returned = 0;
    for (int i = 0; i < entry_count && i < n; i++) {  /* T1: index 0 = largest */
        out_pids[i] = entries[i].pid;
        out_footprint_bytes[i] = entries[i].footprint;
        returned++;
    }

    free(all_pids);
    free(entries);
    return returned;
}

/*
 * alloc_pid_snapshot — one-shot snapshot of the whole pid table.
 *
 * AXIOMS: A1) proc_listpids requires a sizing call then a fill call, and
 * pids may spawn between them (capacity + 100 slack, mirroring the
 * already-verified footprint scanner). A2) Any failure (sizing <= 0,
 * malloc NULL, fill <= 0) must be loud (stderr) and NULL-returning —
 * callers treat NULL as "no data, do nothing".
 * THEOREMS: T1) On success the caller owns the buffer and must free it;
 * on failure the function frees whatever it allocated (no leak on either
 * path). T2) *out_count is always written (0 before any early return).
 * APPLICATIONS: Used by find_leak_candidates_c only; the pre-existing
 * scanners (get_top_processes_by_footprint_c et al.) were deliberately
 * left untouched to avoid changing verified behavior — unify in a
 * follow-up if desired, not here.
 * CITATIONS: proc_listpids — https://developer.apple.com/documentation/libproc/1505977-proc_listpids
 */
static pid_t *alloc_pid_snapshot(int *out_count, const char *caller) {
    if (out_count == NULL || caller == NULL) {
        fprintf(stderr, "[MACOS_UTILS ERROR] alloc_pid_snapshot: NULL out_count or caller\n");
        return NULL;
    }
    *out_count = 0;
    int capacity = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0) / (int)sizeof(pid_t);
    if (capacity <= 0) {
        fprintf(stderr, "[MACOS_UTILS ERROR] proc_listpids sizing returned %d in %s\n",
                capacity, caller);
        return NULL;
    }
    capacity += 100; /* slack for pids spawned between sizing and fill */
    pid_t *pids = malloc(sizeof(pid_t) * (size_t)capacity);
    if (pids == NULL) {
        fprintf(stderr, "[MACOS_UTILS ERROR] malloc(%zu) failed for pid snapshot in %s\n",
                sizeof(pid_t) * (size_t)capacity, caller);
        return NULL;
    }
    int filled = proc_listpids(PROC_ALL_PIDS, 0, pids,
                               sizeof(pid_t) * (size_t)capacity) / (int)sizeof(pid_t);
    if (filled <= 0) {
        fprintf(stderr, "[MACOS_UTILS ERROR] proc_listpids fill returned %d in %s\n",
                filled, caller);
        free(pids); /* T1: no leak on failure path */
        return NULL;
    }
    *out_count = filled;
    return pids;
}

typedef struct {
    int pid;
    uint64_t footprint;
    int64_t age_seconds;
} LeakCandidate;

static int compare_leak_candidates(const void *a, const void *b) {
    uint64_t fpA = ((const LeakCandidate *)a)->footprint;
    uint64_t fpB = ((const LeakCandidate *)b)->footprint;
    if (fpA > fpB) return -1; /* descending: biggest footprint first */
    if (fpA < fpB) return 1;
    return 0;
}

/*
 * find_leak_candidates_c — leak scan: footprint > min AND age > min, sorted.
 *
 * AXIOMS: A1) A "memory leak" is a process that (a) physically holds more
 * than min_footprint_bytes (ri_phys_footprint — Activity Monitor "Memory"
 * methodology: resident + compressed + internal, NOT plain RSS) and (b)
 * has been alive longer than min_age_seconds (wall-clock age =
 * now - pbi_start_tvsec); both STRICT, both proven from kernel data.
 * A2) Data that cannot be obtained (rusage race, pbi fetch mismatch,
 * implausible start time, time() failure) means the criteria are UNPROVEN
 * — an unproven process is never a candidate (missing datum => no kill).
 * A3) pid < 200 and self (getpid) are never candidates, so the daemon
 * cannot target kernel-range services or itself.
 * THEOREMS: T1) Returns count in 0..n; 0 means "nothing matched OR scan
 * failed" — both are safe no-ops for the caller (errors already on
 * stderr). T2) Output arrays are filled 0..returned-1 largest-first.
 * T3) Every malloc'd buffer is freed on every path (success and each
 * error return).
 * APPLICATIONS: Called by Murasama_Footprint/Leak_Killer Ada policy layer
 * every LEAK_CHECK_INTERVAL_MS; the _C layer is pure data — policy
 * (username *_*, user-home /Users/ priority, kill cap, dry-run gate)
 * lives in Ada.
 * CITATIONS: proc_pid_rusage — https://developer.apple.com/documentation/libproc/1505956-proc_pidrusage
 *            proc_pidinfo/PIDTBSDINFO — https://developer.apple.com/documentation/libproc/1505969-proc_pidinfo
 *            ri_phys_footprint methodology — Activity Monitor "Memory" column.
 */
int find_leak_candidates_c(int64_t min_footprint_bytes, int64_t min_age_seconds,
                           int *out_pids, uint64_t *out_footprint_bytes,
                           int64_t *out_age_seconds, int n) {
    if (out_pids == NULL || out_footprint_bytes == NULL || out_age_seconds == NULL
        || n <= 0 || min_footprint_bytes <= 0 || min_age_seconds <= 0) {
        fprintf(stderr,
                "[MACOS_UTILS ERROR] find_leak_candidates_c: invalid args (n=%d, min_fp=%lld, min_age=%lld)\n",
                n, (long long)min_footprint_bytes, (long long)min_age_seconds);
        return 0;
    }

    int num_pids = 0;
    pid_t *all_pids = alloc_pid_snapshot(&num_pids, __func__);
    if (all_pids == NULL) {
        return 0; /* error already logged; T1: treat as empty scan */
    }

    LeakCandidate *cands = malloc(sizeof(LeakCandidate) * (size_t)num_pids);
    if (cands == NULL) {
        fprintf(stderr, "[MACOS_UTILS ERROR] malloc(%zu) failed for leak candidates in %s\n",
                sizeof(LeakCandidate) * (size_t)num_pids, __func__);
        free(all_pids);
        return 0;
    }

    const pid_t self_pid = getpid();
    const time_t now = time(NULL);
    if (now == (time_t)-1) {
        fprintf(stderr, "[MACOS_UTILS ERROR] time(NULL) failed in %s (errno=%d)\n",
                __func__, errno);
        free(all_pids);
        free(cands);
        return 0; /* A2: no trustworthy clock => no candidates */
    }

    int count = 0;
    for (int i = 0; i < num_pids; i++) {
        pid_t pid = all_pids[i];
        if (pid < 200 || pid == self_pid) continue; /* A3 */

        /* Gate 1: footprint (cheap rusage call first — kills most pids here) */
        struct rusage_info_v4 ri;
        memset(&ri, 0, sizeof ri);
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t)&ri) != 0) {
            continue; /* A2: inaccessible/exiting pid — normal race, not an error */
        }
        if ((int64_t)ri.ri_phys_footprint <= min_footprint_bytes) {
            continue; /* A1: STRICT > 1 GB of phys_footprint */
        }

        /* Gate 2: wall-clock age via PROC_PIDTBSDINFO (single call: start time) */
        struct proc_bsdinfo pbi;
        memset(&pbi, 0, sizeof pbi);
        int psz = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &pbi, PROC_PIDTBSDINFO_SIZE);
        if (psz != PROC_PIDTBSDINFO_SIZE) {
            continue; /* A2: race/permission — unproven age => not a candidate */
        }
        if (pbi.pbi_start_tvsec == 0 || now < pbi.pbi_start_tvsec) {
            continue; /* A2: implausible start time — never act on bad data */
        }
        int64_t age = (int64_t)(now - (time_t)pbi.pbi_start_tvsec);
        if (age <= min_age_seconds) {
            continue; /* A1: STRICT > 12 h alive */
        }

        cands[count].pid = (int)pid;
        cands[count].footprint = ri.ri_phys_footprint;
        cands[count].age_seconds = age;
        count++;
    }
    free(all_pids);

    qsort(cands, (size_t)count, sizeof(LeakCandidate), compare_leak_candidates);

    int returned = count < n ? count : n;
    for (int i = 0; i < returned; i++) { /* T2: index 0 = largest */
        out_pids[i] = cands[i].pid;
        out_footprint_bytes[i] = cands[i].footprint;
        out_age_seconds[i] = cands[i].age_seconds;
    }
    free(cands); /* T3: freed on success path (error paths freed above) */
    return returned;
}

/*
 * get_user_info_c — resolve a pid's owner uid + username.
 *
 * AXIOMS: A1) The owner identity comes from the kernel in ONE
 * PROC_PIDTBSDINFO fetch (pbi_uid); the username is the passwd
 * translation of that uid (getpwuid_r). A2) If either step fails the
 * owner is UNKNOWN, and unknown-owner processes must never be killed —
 * caller policy: -1 => skip + warn.
 * THEOREMS: T1) Returns 0 only when out_uid and out_username are both
 * validly written; any failure returns -1 with both outputs reset
 * (*out_uid = (uid_t)-1, out_username = ""). T2) Username is always
 * NUL-terminated within username_len (snprintf truncates, never overruns).
 * APPLICATIONS: Murasama_Leak_Killer reads the username for the *_*
 * (underscore) system-user exemption and the uid for the root exemption.
 * CITATIONS: proc_pidinfo — https://developer.apple.com/documentation/libproc/1505969-proc_pidinfo
 *            getpwuid_r — https://developer.apple.com/documentation/man/3/getpwuid_r
 */
int get_user_info_c(int pid, uid_t *out_uid, char *out_username, int username_len) {
    if (out_uid == NULL || out_username == NULL || username_len <= 0) {
        fprintf(stderr, "[MACOS_UTILS ERROR] get_user_info_c: invalid args (pid=%d, len=%d)\n",
                pid, username_len);
        return -1;
    }
    *out_uid = (uid_t)-1;
    out_username[0] = '\0';

    if (pid < 1) {
        fprintf(stderr, "[MACOS_UTILS ERROR] get_user_info_c: pid %d out of range\n", pid);
        return -1;
    }

    struct proc_bsdinfo pbi;
    memset(&pbi, 0, sizeof pbi);
    int psz = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &pbi, PROC_PIDTBSDINFO_SIZE);
    if (psz != PROC_PIDTBSDINFO_SIZE) {
        fprintf(stderr, "[MACOS_UTILS ERROR] get_user_info_c: proc_pidinfo(%d) returned %d (errno=%d)\n",
                pid, psz, errno);
        return -1; /* T1 */
    }

    struct passwd pw;
    struct passwd *result = NULL;
    char scratch[4096];
    int rc = getpwuid_r(pbi.pbi_uid, &pw, scratch, sizeof scratch, &result);
    if (rc != 0 || result == NULL || result->pw_name == NULL) {
        fprintf(stderr,
                "[MACOS_UTILS ERROR] get_user_info_c: getpwuid_r(uid=%u, pid=%d) failed (rc=%d, errno=%d)\n",
                (unsigned)pbi.pbi_uid, pid, rc, errno);
        return -1; /* T1 */
    }

    *out_uid = pbi.pbi_uid;
    snprintf(out_username, (size_t)username_len, "%s", result->pw_name); /* T2 */
    return 0;
}

int list_pids_c(int *out_pids, int max_count) {
    int num_pids = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0) / sizeof(pid_t);
    if (num_pids <= 0) return 0;

    pid_t *all_pids = malloc(sizeof(pid_t) * (num_pids + 100));
    if (all_pids == NULL) {
        fprintf(stderr, "[MACOS_UTILS ERROR] malloc(%zu) failed for process list in %s\n",
                (size_t)(sizeof(pid_t) * (num_pids + 100)), __func__);
        return 0;
    }
    num_pids = proc_listpids(PROC_ALL_PIDS, 0, all_pids, sizeof(pid_t) * (num_pids + 100)) / sizeof(pid_t);

    int count = 0;
    for (int i = 0; i < num_pids && count < max_count; i++) {
        if (all_pids[i] > 0) {
            out_pids[count++] = all_pids[i];
        }
    }

    free(all_pids);
    return count;
}

void run_system_command_c(const char *cmd) {
    if (cmd) {
        system(cmd);
    }
}

void restore_blacklisted_priorities_c(void) {
    /* Restore normal scheduling for all deprioritized processes when memory pressure is gone.
       Uses taskpolicy -B to clear background scheduling class. */
    int num_pids = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0) / sizeof(pid_t);
    if (num_pids <= 0) return;

    pid_t *all_pids = malloc(sizeof(pid_t) * (num_pids + 100));
    if (all_pids == NULL) {
        fprintf(stderr, "[MACOS_UTILS ERROR] malloc(%zu) failed for process list in %s\n",
                (size_t)(sizeof(pid_t) * (num_pids + 100)), __func__);
        return;
    }
    num_pids = proc_listpids(PROC_ALL_PIDS, 0, all_pids, sizeof(pid_t) * (num_pids + 100)) / sizeof(pid_t);

    /* Only the blacklisted processes that actually get deprioritized during high pressure */
    const char *restore_list[] = {
        "oMLX", "omlx-server", "com.apple.Virtualization.VirtualMachine", "qemu-system-aarch64"
    };

    for (int i = 0; i < num_pids; i++) {
        pid_t pid = all_pids[i];
        if (pid < 200) continue;

        char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pid, pathbuf, sizeof(pathbuf)) > 0) {
            char *bname = basename(pathbuf);
            int matched = 0;
            for (int b = 0; b < 4; b++) {
                if (strcmp(bname, restore_list[b]) == 0) { matched = 1; break; }
            }
            if (!matched && (strstr(pathbuf, "omlx") || strstr(pathbuf, "oMLX") || strstr(pathbuf, "OMLX"))) {
                matched = 1;
            }
            if (matched) {
                char taskpolicy_cmd[64];
                snprintf(taskpolicy_cmd, sizeof(taskpolicy_cmd),
                    "taskpolicy -p %d -B", pid);
                system(taskpolicy_cmd);
            }
        }
    }

    free(all_pids);
}

void deprioritize_blacklisted_c(void) {
    /* Explicitly set background scheduling for blacklisted processes.
       Call this during thrashing mitigation or bloodshed — NOT as a side effect of queries. */
    int num_pids = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0) / sizeof(pid_t);
    if (num_pids <= 0) return;

    pid_t *all_pids = malloc(sizeof(pid_t) * (num_pids + 100));
    if (all_pids == NULL) {
        fprintf(stderr, "[MACOS_UTILS ERROR] malloc(%zu) failed for process list in %s\n",
                (size_t)(sizeof(pid_t) * (num_pids + 100)), __func__);
        return;
    }
    num_pids = proc_listpids(PROC_ALL_PIDS, 0, all_pids, sizeof(pid_t) * (num_pids + 100)) / sizeof(pid_t);

    const char *blacklist[] = {
        "oMLX", "omlx-server", "com.apple.Virtualization.VirtualMachine", "qemu-system-aarch64"
    };

    for (int i = 0; i < num_pids; i++) {
        pid_t pid = all_pids[i];
        if (pid < 200) continue;

        char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pid, pathbuf, sizeof(pathbuf)) > 0) {
            char *bname = basename(pathbuf);
            int matched = 0;
            for (int b = 0; b < 4; b++) {
                if (strcmp(bname, blacklist[b]) == 0) { matched = 1; break; }
            }
            if (!matched && (strstr(pathbuf, "omlx") || strstr(pathbuf, "oMLX") || strstr(pathbuf, "OMLX"))) {
                matched = 1;
            }
            if (matched) {
                char taskpolicy_cmd[64];
                snprintf(taskpolicy_cmd, sizeof(taskpolicy_cmd),
                    "taskpolicy -p %d -b", pid);
                system(taskpolicy_cmd);
            }
        }
    }

    free(all_pids);
}

int lock_all_memory_c(void) {
    /* Pin ALL current and future memory pages of this process (mlockall).
       A memory-pressure daemon must never be paged out during crisis; MCL_FUTURE
       additionally pins every future heap allocation made by the hardened
       malloc paths above. Requires root (the daemon runs as root via launchd).
       Returns 0 on success, -1 on failure (errno preserved + reported). */
    if (mlockall(MCL_CURRENT | MCL_FUTURE) != 0) {
        int saved_errno = errno;
        fprintf(stderr,
                "[MACOS_UTILS ERROR] mlockall(MCL_CURRENT|MCL_FUTURE) failed in %s: errno=%d (%s)\n",
                __func__, saved_errno, strerror(saved_errno));
        return -1;
    }
    fprintf(stderr,
            "[MACOS_UTILS INFO] mlockall(MCL_CURRENT|MCL_FUTURE) succeeded in %s — daemon memory pinned\n",
            __func__);
    return 0;
}

/* ---- Clean-shutdown signal plumbing ----
   Async-signal-safe design: the handler ONLY sets a sig_atomic_t flag.
   The Ada main loop polls shutdown_requested_c() every cycle and performs
   all cleanup (un-boost priorities, game mode auto, kill sidecar) in
   normal tasking context. No locks, no mallocs, no stdio in handler. */

static volatile sig_atomic_t g_shutdown_requested = 0;

static void shutdown_flag_handler(int sig) {
    (void)sig; /* SIGTERM or SIGINT — same meaning here */
    g_shutdown_requested = 1;
}

void install_shutdown_handlers_c(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = shutdown_flag_handler;
    if (sigaction(SIGTERM, &sa, NULL) != 0) {
        fprintf(stderr, "[MACOS_UTILS ERROR] sigaction(SIGTERM) failed in %s: %s\n",
                __func__, strerror(errno));
    }
    if (sigaction(SIGINT, &sa, NULL) != 0) {
        fprintf(stderr, "[MACOS_UTILS ERROR] sigaction(SIGINT) failed in %s: %s\n",
                __func__, strerror(errno));
    }
}

int shutdown_requested_c(void) {
    return g_shutdown_requested ? 1 : 0;
}
