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
#include <libgen.h>

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

int is_system_process_c(const char *path) {
    if (!path) return 1;

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

    const char *excluded[] = {
        "kernel_task", "WindowServer", "launchd", "sysmond", "apsd", "configd", "powerd",
        "coreaudiod", "loginwindow", "ScreenSaverEngine", "coreauthd", "SecurityAgent",
        "Dock", "SystemUIServer", "Finder", "runningboardd", "UserEventAgent", "lsd", "mDNSResponder",
        "FSUSBDriverIsolationBridge", "launchservicesd", "watchdogd", "rclone", "ffmpeg",
        "entrypoint.sh", "Terminal.app", "Terminal", "WhatsApp", "iTerm2", "iTerm", "iterm", "airportd"
    };
    for (int i = 0; i < 32; i++) {
        if (strstr(path, excluded[i])) return 1;
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
    num_pids = proc_listpids(PROC_ALL_PIDS, 0, all_pids, sizeof(pid_t) * (num_pids + 100)) / sizeof(pid_t);

    int count = 0;
    int *queue = malloc(sizeof(int) * (num_pids + 100));
    int head = 0;
    int tail = 0;

    queue[tail++] = root_pid;
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
                    queue[tail++] = pid;
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
    num_pids = proc_listpids(PROC_ALL_PIDS, 0, all_pids, sizeof(pid_t) * (num_pids + 100)) / sizeof(pid_t);

    ProcessEntry *entries = malloc(sizeof(ProcessEntry) * num_pids);
    int entry_count = 0;

    for (int i = 0; i < num_pids; i++) {
        pid_t pid = all_pids[i];
        if (pid < 200 || pid == exclude_pid) continue;

        struct proc_taskinfo pti;
        if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &pti, sizeof(pti)) == sizeof(pti)) {
            char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
            if (proc_pidpath(pid, pathbuf, sizeof(pathbuf)) > 0) {
                char *bname = basename(pathbuf);

                const char *blacklist[] = {
                    "WindowServer", "loginwindow", "SystemUIServer", "Dock", "Finder",
                    "NotificationCenter", "ControlCenter", "Spotlight", "launchd"
                };
                int blacklisted = 0;
                for (int b = 0; b < 9; b++) {
                    if (strcmp(bname, blacklist[b]) == 0) {
                        blacklisted = 1;
                        break;
                    }
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

int list_pids_c(int *out_pids, int max_count) {
    int num_pids = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0) / sizeof(pid_t);
    if (num_pids <= 0) return 0;

    pid_t *all_pids = malloc(sizeof(pid_t) * (num_pids + 100));
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
