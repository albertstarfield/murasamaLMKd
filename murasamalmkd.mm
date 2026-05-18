#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <iostream>
#include <vector>
#include <chrono>
#include <thread>
#include <iomanip>
#include <algorithm>
#include <map>
#include <fstream>
#include <sstream>
#include <mutex>
#include <atomic>
#include <csignal>
#include <mach/mach.h>
#include <mach/vm_statistics.h>
#include <mach/mach_host.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <signal.h>
#include <unistd.h>
#include <cstdlib>
#include <cstring>
#include <libgen.h>
#include <queue>
#include <set>
#include <sys/resource.h>
#include <condition_variable>

// ==================== CONFIGURATION ====================
// --- Bloodshed (original) ---
const int POLL_INTERVAL_MS = 25;
const int REPORT_INTERVAL_MS = 5000;
const double CRITICAL_FREE_MB = 128.0;
const double PANIC_VELOCITY_MB_S = 21000.0;
const int MIN_PRESSURE_LEVEL_TO_KILL = 4;
const int GRADIENT_MEASURE_MS = 100;
const int TOP_N_PROCESSES = 3;

const std::string WEIGHTS_FILE = "/usr/local/murasamaLMKd/weights.csv";
const int WEIGHT_DECREMENT_HOURS = 12;
const int WEIGHT_PRIORITY_THRESHOLD = 3;

const std::vector<std::string> BLACKLIST = {
    "WindowServer",
    "loginwindow",
    "SystemUIServer",
    "Dock",
    "Finder",
    "NotificationCenter",
    "ControlCenter",
    "Spotlight",
    "launchd"
};

// --- Thrashing detection ---
const uint64_t THRASHING_THRESHOLD_PAGEINS = 500;
const uint64_t THRASHING_THRESHOLD_DECOMP = 10000;
const int HYSTERESIS_SECONDS = 60;

// --- Game mode ---
const std::string GAMEPOLICY_CTL_PATH = "/Applications/Xcode.app/Contents/Developer/usr/bin/gamepolicyctl";

// ==================== STRUCT DEFINITIONS ====================
struct ProcessStat {
    pid_t pid;
    std::string name;
    std::string path;
    uint64_t resident_memory_bytes;
    uint64_t cumulative_pageins;
};

// ==================== ASYNC APPLESCRIPT HANDLER ====================
class AppleScriptAsync {
public:
    AppleScriptAsync() : running(true) {
        worker = std::thread(&AppleScriptAsync::workerLoop, this);
    }
    ~AppleScriptAsync() {
        running = false;
        cv.notify_all();
        if (worker.joinable()) worker.join();
    }
    void enqueue(const std::string& command) {
        {
            std::lock_guard<std::mutex> lock(mtx);
            queue.push(command);
        }
        cv.notify_one();
    }
    std::string getLastResult() {
        std::lock_guard<std::mutex> lock(mtx);
        return lastResult;
    }
private:
    void workerLoop() {
        while (running) {
            std::unique_lock<std::mutex> lock(mtx);
            cv.wait(lock, [this] { return !queue.empty() || !running; });
            if (!running) break;
            std::string cmd = queue.front();
            queue.pop();
            lock.unlock();
            
            // Execute command and capture output
            std::string result;
            FILE* pipe = popen(cmd.c_str(), "r");
            if (pipe) {
                char buffer[128];
                while (fgets(buffer, sizeof(buffer), pipe) != nullptr) {
                    result += buffer;
                }
                pclose(pipe);
            }
            
            // Store last result
            {
                std::lock_guard<std::mutex> lock2(mtx);
                lastResult = result;
            }
            
            // Enforce 30-second throttle
            std::this_thread::sleep_for(std::chrono::seconds(30));
        }
    }
    std::queue<std::string> queue;
    std::string lastResult;
    std::mutex mtx;
    std::condition_variable cv;
    std::thread worker;
    std::atomic<bool> running;
};

// ==================== GLOBALS ====================
// Bloodshed globals
std::map<std::string, int> g_weights;
std::mutex g_weights_mutex;

// Thrashing globals
struct ThrashingSummary {
    int total_triggers = 0;
    int reason_pageins = 0;
    int reason_decomp = 0;
    int reason_pressure = 0;
    std::chrono::steady_clock::time_point last_summary_time = std::chrono::steady_clock::now();
    std::mutex mtx;
};
ThrashingSummary g_thrashing_summary;

std::atomic<bool> is_thrashing_mitigating(false);
std::chrono::steady_clock::time_point mitigation_end_time;
std::vector<pid_t> throttled_pids;
pid_t currently_boosted_pid = 0;
std::vector<pid_t> boosted_pids;
std::atomic<bool> game_mode_enabled(false);
std::mutex boosting_mutex;
std::mutex thrashing_mutex;
std::atomic<bool> is_running(true);

// AppleScript async handler (global instance)
AppleScriptAsync g_appleScript;

// ==================== HELPER FUNCTIONS ====================
uint64_t get_page_size() {
    vm_size_t page_size;
    host_page_size(mach_host_self(), &page_size);
    return page_size;
}

uid_t get_console_uid() {
    struct stat sb;
    if (stat("/dev/console", &sb) == 0) {
        return sb.st_uid;
    }
    return 0;
}

int get_memory_pressure_level() {
    int pressure = 1;
    size_t size = sizeof(pressure);
    sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, NULL, 0);
    return pressure;
}

void notify_bloodshed(const char* target_name, const std::string& reason) {
    uid_t uid = get_console_uid();
    if (uid == 0) return;

    char uid_str[32];
    snprintf(uid_str, sizeof(uid_str), "%d", uid);

    char message[512];
    snprintf(message, sizeof(message), "Terminated %s. Reason: %s", target_name, reason.c_str());

    char command[1024];
    snprintf(command, sizeof(command),
             "launchctl asuser %s /opt/homebrew/bin/zenity --warning --text=\"%s\" --title=\"Murasama LMKd: Bloodshed\" --width=300",
             uid_str, message);

    // Offload to async AppleScript handler (now handles zenity too)
    g_appleScript.enqueue(command);
}

void notify_thrashing(const std::string& frontmost_name, pid_t frontmost_pid) {
    uid_t uid = get_console_uid();
    if (uid == 0) return;

    char uid_str[32];
    snprintf(uid_str, sizeof(uid_str), "%d", uid);

    std::string message = "Optimizing " + frontmost_name + " (PID " + std::to_string(frontmost_pid) + ")";
    char command[1024];
    snprintf(command, sizeof(command),
             "launchctl asuser %s osascript -e 'display notification \"%s\" with title \"%s\"'",
             uid_str, message.c_str(), "Murasama: High Fault Situation!");

    // Offload to async AppleScript handler
    g_appleScript.enqueue(command);
}

void send_thrashing_summary_notification() {
    uid_t uid = get_console_uid();
    if (uid == 0) return;

    char uid_str[32];
    snprintf(uid_str, sizeof(uid_str), "%d", uid);

    char message[1024];
    {
        std::lock_guard<std::mutex> lock(g_thrashing_summary.mtx);
        snprintf(message, sizeof(message), 
            "Total triggers: %d (Pageins: %d, Decomp: %d, Pressure: %d)",
            g_thrashing_summary.total_triggers,
            g_thrashing_summary.reason_pageins,
            g_thrashing_summary.reason_decomp,
            g_thrashing_summary.reason_pressure);
    }

    char command[2048];
    snprintf(command, sizeof(command),
             "launchctl asuser %s osascript -e 'display notification \"%s\" with title \"%s\"'",
             uid_str, message, "Murasama: Thrashing Summary (Last 1h)");

    g_appleScript.enqueue(command);
}

// ==================== GAME MODE & PRIORITY HELPERS ====================
bool is_gamepolicyctl_available() {
    return access(GAMEPOLICY_CTL_PATH.c_str(), X_OK) == 0;
}

void set_game_mode(const std::string& state) {
    if (!is_gamepolicyctl_available()) return;
    std::string cmd = GAMEPOLICY_CTL_PATH + " game-mode set " + state;
    system(cmd.c_str());
}

pid_t get_parent_pid(pid_t pid) {
    struct kinfo_proc info;
    size_t length = sizeof(struct kinfo_proc);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    if (sysctl(mib, 4, &info, &length, NULL, 0) == 0 && length > 0) {
        return info.kp_eproc.e_ppid;
    }
    return -1;
}

std::vector<pid_t> get_process_tree(pid_t root_pid) {
    std::vector<pid_t> result;
    if (root_pid <= 0) return result;

    int num_pids = proc_listpids(PROC_ALL_PIDS, 0, nullptr, 0);
    std::vector<pid_t> all_pids(num_pids);
    proc_listpids(PROC_ALL_PIDS, 0, all_pids.data(), all_pids.size() * sizeof(pid_t));

    std::map<pid_t, std::vector<pid_t>> children;
    for (pid_t pid : all_pids) {
        if (pid == 0) continue;
        pid_t ppid = get_parent_pid(pid);
        if (ppid > 0) {
            children[ppid].push_back(pid);
        }
    }

    std::queue<pid_t> q;
    q.push(root_pid);
    while (!q.empty()) {
        pid_t cur = q.front();
        q.pop();
        result.push_back(cur);
        auto it = children.find(cur);
        if (it != children.end()) {
            for (pid_t child : it->second) {
                q.push(child);
            }
        }
    }
    return result;
}

// ==================== THRASHING DETECTION ====================
struct MemoryFaultSnapshot {
    uint64_t total_faults;
    uint64_t hard_pageins;
    uint64_t decompressions;
};

MemoryFaultSnapshot get_memory_snapshot() {
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_statistics64_data_t vm_stat;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm_stat, &count) == KERN_SUCCESS) {
        return {vm_stat.faults, vm_stat.pageins, vm_stat.decompressions};
    }
    return {0, 0, 0};
}

pid_t get_frontmost_pid() {
    static pid_t last_frontmost_pid = 0;
    static std::chrono::steady_clock::time_point last_refresh = std::chrono::steady_clock::time_point::min();
    auto now = std::chrono::steady_clock::now();

    if (now - last_refresh < std::chrono::seconds(5)) {
        return last_frontmost_pid;
    }

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
                        pid_t pid = 0;
                        CFNumberGetValue(pidNumber, kCFNumberIntType, &pid);
                        if (pid > 0 && pid != getpid()) {
                            CFRelease(windowList);
                            last_frontmost_pid = pid;
                            last_refresh = now;
                            return pid;
                        }
                    }
                }
            }
            CFRelease(windowList);
        }
    }
    last_refresh = now;
    return last_frontmost_pid;
}

std::string get_process_name(pid_t pid) {
    char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, pathbuf, sizeof(pathbuf)) > 0) {
        return basename(pathbuf);
    }
    return "unknown";
}

bool is_system_process(const std::string& path) {
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

void methodMurasamaThrashingMitigation_In(pid_t current_front) {
    if (is_thrashing_mitigating) return;
    std::cout << "\n[CRITICAL] Thrashing tripped! Engaging 10-Second Mitigation...\n";

    std::string frontmost_name = get_process_name(current_front);
    // notify_thrashing(frontmost_name, current_front); // Disabled per user request, replaced by hourly summary

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
    if (proc_stats.size() > 50) proc_stats.resize(50);
    std::sort(proc_stats.begin(), proc_stats.end(), [](const ProcessStat& a, const ProcessStat& b) {
        return a.resident_memory_bytes > b.resident_memory_bytes;
    });

    std::cout << "\n[!] Top 50 Thrashers (Sorted by RAM):\n";
    for (const auto& proc : proc_stats) {
        std::cout << "PID: " << proc.pid << " | " << proc.name
                  << " | RAM: " << (proc.resident_memory_bytes / 1024 / 1024) << " MB\n";
        if (proc.pid == current_front) continue;
        if (is_system_process(proc.path)) continue;
        // Throttling commented out (caused UI glitches)
        // std::string limit_cmd = "taskpolicy -b -p " + std::to_string(proc.pid);
        // system(limit_cmd.c_str());
        throttled_pids.push_back(proc.pid);
    }

    if (current_front > 0) {
        std::vector<pid_t> tree = get_process_tree(current_front);
        {
            std::lock_guard<std::mutex> lock(boosting_mutex);
            boosted_pids.clear();
            if (!tree.empty()) {
                boosted_pids = tree;
                for (pid_t pid : boosted_pids) {
                    setpriority(PRIO_PROCESS, pid, -20);
                }
                std::cout << "[+] Boosted " << boosted_pids.size() << " PIDs for frontmost app.\n";
            } else {
                setpriority(PRIO_PROCESS, current_front, -20);
                boosted_pids = {current_front};
                std::cout << "[+] Boosted frontmost PID only.\n";
            }
        }

        if (!game_mode_enabled && is_gamepolicyctl_available()) {
            set_game_mode("on");
            game_mode_enabled = true;
            std::cout << "[+] Enabled game mode.\n";
        }
    }

    currently_boosted_pid = current_front;
    is_thrashing_mitigating = true;
    mitigation_end_time = std::chrono::steady_clock::now() + std::chrono::seconds(HYSTERESIS_SECONDS);
}

void methodMurasamaThrashingMitigation_Out() {
    if (!is_thrashing_mitigating) return;
    std::cout << "\n[RECOVERY] Hysteresis timer expired. Restoring system state...\n";

    {
        std::lock_guard<std::mutex> lock(boosting_mutex);
        for (pid_t pid : boosted_pids) {
            setpriority(PRIO_PROCESS, pid, 0);
        }
        boosted_pids.clear();
    }

    if (game_mode_enabled) {
        set_game_mode("auto");
        game_mode_enabled = false;
        std::cout << "[+] Disabled game mode (reverted to auto).\n";
    }

    system("pkill -f 'cpulimit.*-p'");
    throttled_pids.clear();

    if (currently_boosted_pid > 0) {
        std::string unboost_cmd = "renice 0 -p " + std::to_string(currently_boosted_pid) + " >/dev/null 2>&1";
        system(unboost_cmd.c_str());
        currently_boosted_pid = 0;
    }

    is_thrashing_mitigating = false;
}

void thrashing_detection_loop() {
    using namespace std::chrono;

    while (is_running) {
        auto cycle_start = steady_clock::now();

        MemoryFaultSnapshot snap_start = get_memory_snapshot();
        std::this_thread::sleep_for(milliseconds(100));
        MemoryFaultSnapshot snap_end = get_memory_snapshot();

        uint64_t pageins_per_sec = (snap_end.hard_pageins - snap_start.hard_pageins) * 10;
        uint64_t decomp_per_sec = (snap_end.decompressions - snap_start.decompressions) * 10;
        int pressure_level = get_memory_pressure_level();

        pid_t current_front_pid = get_frontmost_pid();

        auto now = steady_clock::now();

        if (pageins_per_sec > THRASHING_THRESHOLD_PAGEINS ||
            decomp_per_sec > THRASHING_THRESHOLD_DECOMP ||
            pressure_level >= 3) {
            if (!is_thrashing_mitigating) {
                {
                    std::lock_guard<std::mutex> lock(g_thrashing_summary.mtx);
                    g_thrashing_summary.total_triggers++;
                    if (pageins_per_sec > THRASHING_THRESHOLD_PAGEINS) g_thrashing_summary.reason_pageins++;
                    if (decomp_per_sec > THRASHING_THRESHOLD_DECOMP) g_thrashing_summary.reason_decomp++;
                    if (pressure_level >= 3) g_thrashing_summary.reason_pressure++;
                }
                methodMurasamaThrashingMitigation_In(current_front_pid);
            }
        }

        // Check for hourly summary notification
        bool should_send_summary = false;
        {
            std::lock_guard<std::mutex> lock(g_thrashing_summary.mtx);
            if (duration_cast<seconds>(now - g_thrashing_summary.last_summary_time).count() >= 3600) {
                if (g_thrashing_summary.total_triggers > 0) {
                    should_send_summary = true;
                } else {
                    g_thrashing_summary.last_summary_time = now; // Reset timer even if no triggers
                }
            }
        }

        if (should_send_summary) {
            send_thrashing_summary_notification();
            {
                std::lock_guard<std::mutex> lock(g_thrashing_summary.mtx);
                g_thrashing_summary.total_triggers = 0;
                g_thrashing_summary.reason_pageins = 0;
                g_thrashing_summary.reason_decomp = 0;
                g_thrashing_summary.reason_pressure = 0;
                g_thrashing_summary.last_summary_time = steady_clock::now();
            }
        }

        if (is_thrashing_mitigating) {
            if (now >= mitigation_end_time) {
                methodMurasamaThrashingMitigation_Out();
            }
        }

        auto elapsed = duration_cast<milliseconds>(steady_clock::now() - cycle_start);
        auto sleep_ms = milliseconds(1000) - elapsed;
        if (sleep_ms.count() > 0) {
            std::this_thread::sleep_for(sleep_ms);
        }
    }
}

// ==================== BLOODSHED FUNCTIONS (original) ====================
struct MemoryStats {
    double free_mb;
    double wired_mb;
    int pressure_level;
};

MemoryStats get_memory_stats(uint64_t page_size) {
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_statistics64_data_t vm_stat;
    host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm_stat, &count);

    int pressure_level = 1;
    size_t size = sizeof(pressure_level);
    sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure_level, &size, NULL, 0);

    MemoryStats stats;
    stats.free_mb = (vm_stat.free_count * page_size) / (1024.0 * 1024.0);
    stats.wired_mb = (vm_stat.wire_count * page_size) / (1024.0 * 1024.0);
    stats.pressure_level = pressure_level;

    return stats;
}

uint64_t get_process_memory(pid_t pid) {
    struct proc_taskinfo pti;
    if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &pti, sizeof(pti)) == sizeof(pti)) {
        return pti.pti_resident_size;
    }
    return 0;
}

bool is_blacklisted(pid_t pid, const std::string& name) {
    if (pid < 200) return true;
    for (const auto& banned : BLACKLIST) {
        if (name == banned) return true;
    }
    return false;
}

std::vector<std::pair<pid_t, uint64_t>> get_top_processes_by_memory(int n) {
    int max_pids = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0) / sizeof(pid_t);
    std::vector<pid_t> pids(max_pids + 100);
    int num_pids = proc_listpids(PROC_ALL_PIDS, 0, pids.data(), pids.size() * sizeof(pid_t)) / sizeof(pid_t);

    std::vector<std::pair<pid_t, uint64_t>> processes;
    pid_t my_pid = getpid();

    for (int i = 0; i < num_pids; ++i) {
        pid_t pid = pids[i];
        if (pid < 200 || pid == my_pid) continue;

        struct proc_taskinfo pti;
        if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &pti, sizeof(pti)) == sizeof(pti)) {
            char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
            std::string name = "unknown";
            if (proc_pidpath(pid, pathbuf, sizeof(pathbuf)) > 0) {
                name = basename(pathbuf);
            }
            if (is_blacklisted(pid, name)) continue;

            processes.emplace_back(pid, pti.pti_resident_size);
        }
    }

    std::sort(processes.begin(), processes.end(),
              [](const auto& a, const auto& b) { return a.second > b.second; });

    if (processes.size() > static_cast<size_t>(n))
        processes.resize(n);
    return processes;
}

std::vector<std::tuple<pid_t, std::string, double>> compute_allocation_rates(
    const std::vector<std::pair<pid_t, uint64_t>>& initial_mem, int delay_ms) {

    std::this_thread::sleep_for(std::chrono::milliseconds(delay_ms));
    double delta_seconds = delay_ms / 1000.0;

    std::vector<std::tuple<pid_t, std::string, double>> results;

    for (const auto& entry : initial_mem) {
        pid_t pid = entry.first;
        uint64_t mem0 = entry.second;
        uint64_t mem1 = get_process_memory(pid);
        if (mem1 == 0) continue;

        char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
        std::string name = "unknown";
        if (proc_pidpath(pid, pathbuf, sizeof(pathbuf)) > 0) {
            name = basename(pathbuf);
        }
        if (is_blacklisted(pid, name)) continue;

        double rate_mb_s = (static_cast<double>(mem1) - static_cast<double>(mem0)) /
                           (1024.0 * 1024.0 * delta_seconds);

        results.emplace_back(pid, name, rate_mb_s);
    }

    std::sort(results.begin(), results.end(),
              [](const auto& a, const auto& b) { return std::get<2>(a) > std::get<2>(b); });

    return results;
}

void load_weights() {
    std::lock_guard<std::mutex> lock(g_weights_mutex);
    std::ifstream file(WEIGHTS_FILE);
    if (!file.is_open()) return;
    std::string line;
    while (std::getline(file, line)) {
        std::istringstream ss(line);
        std::string name;
        int weight;
        if (std::getline(ss, name, ',') && ss >> weight) {
            if (name != "unknown") {
                g_weights[name] = weight;
            }
        }
    }
}

void save_weights() {
    std::lock_guard<std::mutex> lock(g_weights_mutex);
    std::string dir = "/usr/local/murasamaLMKd";
    mkdir(dir.c_str(), 0755);
    std::ofstream file(WEIGHTS_FILE);
    if (!file.is_open()) {
        std::cerr << "Failed to open weights file for writing: " << WEIGHTS_FILE << std::endl;
        return;
    }
    for (const auto& [name, weight] : g_weights) {
        file << name << "," << weight << "\n";
    }
}

void increment_weight(const std::string& name) {
    if (name == "unknown") return;
    {
        std::lock_guard<std::mutex> lock(g_weights_mutex);
        g_weights[name]++;
    }
    save_weights();
}

void decrement_weights_periodically() {
    while (is_running) {
        std::this_thread::sleep_for(std::chrono::hours(WEIGHT_DECREMENT_HOURS));
        bool changed = false;
        {
            std::lock_guard<std::mutex> lock(g_weights_mutex);
            for (auto it = g_weights.begin(); it != g_weights.end(); ) {
                if (it->second > 0) {
                    it->second--;
                    if (it->second == 0) {
                        it = g_weights.erase(it);
                    } else {
                        ++it;
                    }
                    changed = true;
                } else {
                    ++it;
                }
            }
        }
        if (changed) {
            save_weights();
        }
    }
}

void handle_bloodshed(const std::string& trigger_reason, uint64_t page_size) {
    std::cout << "\n--- BLOODSHED INITIATED ---" << std::endl;
    std::cout << "Reason: " << trigger_reason << std::endl;

    const int MAX_KILLS = 3;
    int kill_count = 0;

    while (kill_count < MAX_KILLS) {
        auto top_processes = get_top_processes_by_memory(TOP_N_PROCESSES);
        if (top_processes.empty()) {
            std::cout << "No processes to evaluate. Aborting bloodshed." << std::endl;
            break;
        }

        auto rates = compute_allocation_rates(top_processes, GRADIENT_MEASURE_MS);
        if (rates.empty()) {
            std::cout << "No processes survived rate measurement. Aborting bloodshed." << std::endl;
            break;
        }

        pid_t target_pid = -1;
        std::string target_name;
        double target_rate = 0.0;
        std::string phase_desc;

        {
            std::lock_guard<std::mutex> lock(g_weights_mutex);
            int max_weight = -1;
            for (const auto& r : rates) {
                const std::string& name = std::get<1>(r);
                auto it = g_weights.find(name);
                if (it != g_weights.end() && it->second > WEIGHT_PRIORITY_THRESHOLD) {
                    if (it->second > max_weight) {
                        max_weight = it->second;
                        target_pid = std::get<0>(r);
                        target_name = name;
                        target_rate = std::get<2>(r);
                    }
                }
            }
        }

        if (target_pid != -1) {
            phase_desc = "priority kill (weight > " + std::to_string(WEIGHT_PRIORITY_THRESHOLD) + ")";
        } else {
            if (kill_count < 2) {
                auto& last = rates.back();
                target_pid = std::get<0>(last);
                target_name = std::get<1>(last);
                target_rate = std::get<2>(last);
                phase_desc = (kill_count == 0) ? "first kill (lowest rate)" : "second kill (lowest rate)";
            } else {
                auto& first = rates.front();
                target_pid = std::get<0>(first);
                target_name = std::get<1>(first);
                target_rate = std::get<2>(first);
                phase_desc = "third kill (highest rate)";
            }
        }

        std::cout << "Phase: " << phase_desc << std::endl;
        std::cout << "Target: PID " << target_pid << " (" << target_name << "), rate = "
                  << std::fixed << std::setprecision(2) << target_rate << " MB/s" << std::endl;

        notify_bloodshed(target_name.c_str(),
                         trigger_reason + " (" + phase_desc + ")");

        kill(target_pid, SIGKILL);
        kill_count++;

        increment_weight(target_name);

        std::this_thread::sleep_for(std::chrono::milliseconds(200));

        MemoryStats current_stats = get_memory_stats(page_size);
        bool condition_cleared = (current_stats.free_mb >= CRITICAL_FREE_MB &&
                                  current_stats.pressure_level < MIN_PRESSURE_LEVEL_TO_KILL);

        if (condition_cleared) {
            std::cout << "Memory pressure resolved after " << kill_count << " kill(s)." << std::endl;
            break;
        }
    }

    if (kill_count == MAX_KILLS) {
        std::cout << "Maximum kills reached. Pressure may still persist." << std::endl;
    }
}

// ==================== SIGNAL HANDLER ====================
void handle_interrupt(int signum) {
    std::cout << "\n[!] Caught signal " << signum << ". Cleaning up...\n";
    is_running = false;
}

// ==================== MAIN ====================
int main() {
    setenv("PATH",
           "/opt/homebrew/opt/heimdal/bin:/Users/albertstarfield/.local/bin:/opt/homebrew/anaconda3/bin:"
           "/opt/homebrew/anaconda3/condabin:/opt/homebrew/bin:/Users/albertstarfield/bin:/usr/local/bin:"
           "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:"
           "/bin:/usr/sbin:/sbin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/local/bin:"
           "/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin:"
           "/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/appleinternal/bin:"
           "/opt/pmk/env/global/bin:/Library/TeX/texbin:/opt/podman/bin:/usr/local/Homebrew/bin:"
           "/Users/albertstarfield/.lmstudio/bin",
           1);

    std::cout << "[Murasama LMKd] Unsheathed. GUI Notifications Enabled. Polling interval = 25ms." << std::endl;
    std::cout << "Thrashing detection active. Mitigation threshold: pageins/s > " << THRASHING_THRESHOLD_PAGEINS
              << " or decomp/s > " << THRASHING_THRESHOLD_DECOMP << std::endl;

    std::signal(SIGINT, handle_interrupt);
    std::signal(SIGTERM, handle_interrupt);

    load_weights();
    std::thread weight_decrement_thread(decrement_weights_periodically);
    weight_decrement_thread.detach();

    std::thread thrashing_thread(thrashing_detection_loop);
    thrashing_thread.detach();

    uint64_t page_size = get_page_size();

    auto last_time = std::chrono::steady_clock::now();
    auto last_report_time = last_time;
    MemoryStats last_stats = get_memory_stats(page_size);

    std::cout << std::fixed << std::setprecision(2);

    while (is_running) {
        std::this_thread::sleep_for(std::chrono::milliseconds(POLL_INTERVAL_MS));

        auto current_time = std::chrono::steady_clock::now();
        MemoryStats current_stats = get_memory_stats(page_size);

        std::chrono::duration<double> elapsed = current_time - last_time;

        double wired_velocity = (current_stats.wired_mb - last_stats.wired_mb) / elapsed.count();
        if (wired_velocity < 0) wired_velocity = 0;

        std::chrono::duration<double, std::milli> time_since_report = current_time - last_report_time;
        if (time_since_report.count() >= REPORT_INTERVAL_MS) {
            std::cout << "[HEALTH CHECK] Free: " << current_stats.free_mb << " MB | "
                      << "Wired: " << current_stats.wired_mb << " MB | "
                      << "Lvl: " << current_stats.pressure_level << " | "
                      << "Vel: " << wired_velocity << " MB/s" << std::endl;
            last_report_time = current_time;
        }

        bool condition_met = false;
        std::string trigger_reason = "";

        if (current_stats.pressure_level >= 4) {
            condition_met = true;
            trigger_reason = "Level 4 OS Memory Pressure";
        } else if (current_stats.free_mb < CRITICAL_FREE_MB) {
            condition_met = true;
            trigger_reason = "Free Memory Below Threshold";
        } else if (wired_velocity > PANIC_VELOCITY_MB_S && current_stats.free_mb < (CRITICAL_FREE_MB * 4)) {
            condition_met = true;
            trigger_reason = "Violent Memory Allocation Spike";
        }

        if (condition_met && current_stats.pressure_level >= MIN_PRESSURE_LEVEL_TO_KILL && !is_thrashing_mitigating) {
            handle_bloodshed(trigger_reason, page_size);
            current_time = std::chrono::steady_clock::now();
            current_stats = get_memory_stats(page_size);
        }

        last_time = current_time;
        last_stats = current_stats;
    }

    methodMurasamaThrashingMitigation_Out();
    std::cout << "[Murasama LMKd] Exited cleanly.\n";
    return 0;
}
