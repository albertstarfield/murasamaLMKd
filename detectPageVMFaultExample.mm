#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <iostream>
#include <vector>
#include <thread>
#include <chrono>
#include <string>
#include <algorithm>
#include <atomic>
#include <csignal>
#include <mach/mach_init.h>
#include <mach/mach_host.h>
#include <mach/host_info.h>
#include <libproc.h>
#include <sys/stat.h>
#include <cstdlib>

// --- Structs for Data ---
struct MemoryFaultSnapshot {
    uint64_t total_faults;
    uint64_t hard_pageins;
    uint64_t decompressions;
};

struct ProcessStat {
    pid_t pid;
    std::string name;
    std::string path;
    uint64_t resident_memory_bytes;
    uint64_t cumulative_pageins;
};

// --- Globals & State ---
const uint64_t THRASHING_THRESHOLD_PAGEINS = 500;
const uint64_t THRASHING_THRESHOLD_DECOMP = 10000;
const int HYSTERESIS_SECONDS = 10;

std::atomic<bool> is_running(true);
std::atomic<bool> is_currently_mitigating(false);
std::chrono::steady_clock::time_point mitigation_end_time;

std::vector<pid_t> throttled_pids;
pid_t currently_boosted_pid = 0;

// --- Native Frontmost App Fetcher (Replaces osascript) ---
pid_t get_frontmost_pid() {
    @autoreleasepool {
        NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
        NSRunningApplication *frontApp = [workspace frontmostApplication];
        if (frontApp) {
            return [frontApp processIdentifier];
        }
        return 0;
    }
}

// --- User's Exclusion List ---
bool isSystemProcess(const std::string& path) {
    std::vector<std::string> force_tame = {
        "ReportCrash", "warp-dex", "contactsd", "AddressBookManager",
        "Control Center", "Notification Center", "sysmond", "BiomeAgent",
        "duetexpertd", "coreduet", "cloudd", "airportd", "locationd", "symptomsd"
    };
    for (const auto& ft : force_tame) {
        if (path.find(ft) != std::string::npos) return false;
    }

    if (path.find("Frameworks") != std::string::npos ||
        path.find("CoreServices") != std::string::npos ||
        path.find("/System/Library/CoreServices/") != std::string::npos ||
        path.find("/usr/libexec") != std::string::npos ||
        path.find("/System/Library/DriverExtensions") != std::string::npos ||
        path.find("/System/Library/ExtensionKit") != std::string::npos ||
        path.find("/Library/SystemExtensions") != std::string::npos) return true;

    std::vector<std::string> excluded = {
        "kernel_task", "WindowServer", "launchd", "sysmond", "apsd", "configd", "powerd",
        "coreaudiod", "loginwindow", "ScreenSaverEngine", "coreauthd", "SecurityAgent",
        "Dock", "SystemUIServer", "Finder", "runningboardd", "UserEventAgent", "lsd", "mDNSResponder",
        "FSUSBDriverIsolationBridge", "launchservicesd", "watchdogd", "rclone", "ffmpeg",
        "entrypoint.sh", "Terminal.app", "Terminal", "WhatsApp", "iTerm2", "iTerm", "iterm", "airportd"
    };

    for (const auto& sys_proc : excluded) {
        if (path.find(sys_proc) != std::string::npos) return true;
    }

    return false;
}

// --- Snapshot Logic ---
MemoryFaultSnapshot get_memory_snapshot() {
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_statistics64_data_t vm_stat;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm_stat, &count) == KERN_SUCCESS) {
        return {vm_stat.faults, vm_stat.pageins, vm_stat.decompressions};
    }
    return {0, 0, 0};
}

// --- Mitigation Logic ---
void methodMurasamaThrashingMitigation_In(pid_t current_front) {
    if (is_currently_mitigating) return;
    std::cout << "\n[CRITICAL] Thrashing tripped! Engaging 10-Second Mitigation...\n";

    system("su - $(stat -f '%Su' /dev/console) -c 'defaults write com.apple.dock single-app -bool true && killall Dock'");

    int pid_count = proc_listpids(PROC_ALL_PIDS, 0, nullptr, 0) / sizeof(pid_t);
    std::vector<pid_t> pids(pid_count);
    proc_listpids(PROC_ALL_PIDS, 0, pids.data(), pids.size() * sizeof(pid_t));

    std::vector<ProcessStat> proc_stats;
    for (pid_t pid : pids) {
        if (pid == 0) continue;
        struct proc_taskinfo pti;
        if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &pti, sizeof(pti)) == sizeof(pti)) {
            char name_buf[256];
            char path_buf[PROC_PIDPATHINFO_MAXSIZE];
            proc_name(pid, name_buf, sizeof(name_buf));
            proc_pidpath(pid, path_buf, sizeof(path_buf));

            proc_stats.push_back({
                pid, std::string(name_buf), std::string(path_buf),
                pti.pti_resident_size, static_cast<uint64_t>(pti.pti_pageins)
            });
        }
    }

    std::sort(proc_stats.begin(), proc_stats.end(), [](const ProcessStat& a, const ProcessStat& b) {
        return a.cumulative_pageins > b.cumulative_pageins;
    });

    if (proc_stats.size() > 10) proc_stats.resize(10);

    std::sort(proc_stats.begin(), proc_stats.end(), [](const ProcessStat& a, const ProcessStat& b) {
        return a.resident_memory_bytes > b.resident_memory_bytes;
    });

    std::cout << "\n[!] Top 10 Thrashers (Sorted by RAM):\n";
    for (const auto& proc : proc_stats) {
        std::cout << "PID: " << proc.pid << " | " << proc.name
                  << " | RAM: " << (proc.resident_memory_bytes / 1024 / 1024) << " MB\n";

        if (proc.pid == current_front) continue;
        if (isSystemProcess(proc.path)) continue;

        std::string limit_cmd = "cpulimit -l 1 -z -p " + std::to_string(proc.pid) + " >/dev/null 2>&1 &";
        system(limit_cmd.c_str());
        throttled_pids.push_back(proc.pid);
    }

    if (current_front > 0) {
        std::string boost_cmd = "renice -20 -p " + std::to_string(current_front) + " >/dev/null 2>&1";
        system(boost_cmd.c_str());
        currently_boosted_pid = current_front;
        std::cout << "[+] Boosted Frontmost PID: " << current_front << "\n";
    }

    is_currently_mitigating = true;
}

void methodMurasamaThrashingMitigation_Out() {
    if (!is_currently_mitigating) return;
    std::cout << "\n[RECOVERY] Hysteresis timer expired. Restoring system state...\n";

    system("CURRENT_USER=$(stat -f '%Su' /dev/console | cut -d '@' -f 1); sudo -u \"$CURRENT_USER\" defaults write com.apple.dock single-app -bool false && sudo -u \"$CURRENT_USER\" killall Dock");
    system("pkill -f 'cpulimit.*-p'");
    throttled_pids.clear();

    if (currently_boosted_pid > 0) {
        std::string unboost_cmd = "renice 0 -p " + std::to_string(currently_boosted_pid) + " >/dev/null 2>&1";
        system(unboost_cmd.c_str());
        currently_boosted_pid = 0;
    }

    is_currently_mitigating = false;
}

// --- Signal Handler ---
void handle_interrupt(int signum) {
    std::cout << "\n[!] Caught signal " << signum << ". Cleaning up before exit...\n";
    is_running = false;
    methodMurasamaThrashingMitigation_Out();
    exit(signum);
}

// --- Main Loop ---
int main() {
    using namespace std::chrono;

    std::signal(SIGINT, handle_interrupt);
    std::signal(SIGTERM, handle_interrupt);

    std::cout << "Murasama Manager Started (Native AppKit Mode). Press Ctrl+C to stop.\n";

    while (is_running) {
        auto cycle_start = steady_clock::now();

        MemoryFaultSnapshot snap_start = get_memory_snapshot();
        std::this_thread::sleep_for(milliseconds(100));
        MemoryFaultSnapshot snap_end = get_memory_snapshot();

        uint64_t pageins_per_sec = (snap_end.hard_pageins - snap_start.hard_pageins) * 10;
        uint64_t decomp_per_sec = (snap_end.decompressions - snap_start.decompressions) * 10;

        // Grab frontmost PID instantly via AppKit
        pid_t current_front_pid = get_frontmost_pid();

        std::cout << "Pageins/s: " << pageins_per_sec
                  << " | Decomp/s: " << decomp_per_sec
                  << " | Active PID: " << current_front_pid;

        auto now = steady_clock::now();

        // Condition to Trigger
        if (pageins_per_sec > THRASHING_THRESHOLD_PAGEINS || decomp_per_sec > THRASHING_THRESHOLD_DECOMP) {
            std::cout << "  [TRIPWIRE HIT!]";
            mitigation_end_time = now + seconds(HYSTERESIS_SECONDS);
            if (!is_currently_mitigating) {
                methodMurasamaThrashingMitigation_In(current_front_pid);
            }
        }

        // Condition to Release
        if (is_currently_mitigating) {
            auto time_left = duration_cast<seconds>(mitigation_end_time - now).count();
            if (time_left > 0) {
                std::cout << "  [Mitigation Active: " << time_left << "s left]";
            } else {
                methodMurasamaThrashingMitigation_Out();
            }
        }

        std::cout << "\n";

        // Sleep remainder of cycle
        now = steady_clock::now();
        auto elapsed_in_cycle = duration_cast<milliseconds>(now - cycle_start);
        auto time_to_sleep = milliseconds(1000) - elapsed_in_cycle;
        if (time_to_sleep.count() > 0) std::this_thread::sleep_for(time_to_sleep);
    }

    return 0;
}
