#ifndef MACOS_UTILS_H
#define MACOS_UTILS_H

#include <stdint.h>
#include <sys/types.h>

// Memory Statistics
uint64_t get_page_size_c(void);
uid_t get_console_uid_c(void);
int get_memory_pressure_level_c(void);
double get_free_mb_c(uint64_t page_size);
double get_wired_mb_c(uint64_t page_size);
double get_compressor_mb_c(uint64_t page_size);
void get_swap_usage_c(double *out_total_mb, double *out_used_mb);
uint64_t get_process_memory_c(int pid);

// AppKit & Window Management
int get_frontmost_pid_c(void);

// Process Information
void get_process_name_c(int pid, char *out_name, int max_len);
void get_process_path_c(int pid, char *out_path, int max_len);
int is_system_process_c(const char *path);

// Game Mode & Priority Toggling
int is_gamepolicyctl_available_c(void);
void set_game_mode_c(const char *state);
int get_parent_pid_c(int pid);
int get_process_tree_c(int root_pid, int *out_pids, int max_count);
void set_process_priority_c(int pid, int priority);

// Thrashing Statistics (Mach VM Info)
void get_memory_snapshot_c(uint64_t *out_faults, uint64_t *out_pageins, uint64_t *out_decomp);

// Top Processes Query
int get_top_processes_by_memory_c(int *out_pids, uint64_t *out_resident_bytes, int n, int exclude_pid);

// Top Processes by phys_footprint (Activity Monitor "Memory" column methodology:
// proc_pid_rusage -> ri_phys_footprint, includes compressed + internal memory,
// NOT plain RSS from proc_taskinfo)
int get_top_processes_by_footprint_c(int *out_pids, uint64_t *out_footprint_bytes, int n, int exclude_pid);

// Leak candidate scan: keep pids whose ri_phys_footprint STRICTLY exceeds
// min_footprint_bytes AND whose wall-clock age (now - pbi_start_tvsec)
// STRICTLY exceeds min_age_seconds; sorted largest-footprint-first.
// Excludes pid < 200 (kernel/service range) and self (getpid) so the daemon
// can never target itself. Returns number of candidates written (<= n).
// Returns 0 on ANY error (invalid args, malloc failure, proc_listpids
// failure) — caller must treat 0 as "nothing to kill", errors are logged
// verbosely to stderr with the [MACOS_UTILS ERROR] prefix.
// Citations: proc_listpids https://developer.apple.com/documentation/libproc/1505977-proc_listpids
//            proc_pid_rusage https://developer.apple.com/documentation/libproc/1505956-proc_pidrusage
//            proc_pidinfo(PROC_PIDTBSDINFO) https://developer.apple.com/documentation/libproc/1505969-proc_pidinfo
int find_leak_candidates_c(int64_t min_footprint_bytes, int64_t min_age_seconds,
                           int *out_pids, uint64_t *out_footprint_bytes,
                           int64_t *out_age_seconds, int n);

// Owner lookup for one pid: proc_pidinfo(PROC_PIDTBSDINFO) -> pbi_uid, then
// getpwuid_r -> username copied into out_username (NUL-terminated, truncated
// to username_len - 1 if needed). Returns 0 on success; -1 on ANY failure
// (pid exited, pbi fetch failed, uid has no passwd entry) with a verbose
// [MACOS_UTILS ERROR] line on stderr. Callers must treat -1 as "owner is
// unknown — do NOT kill" (policy lives in Ada: missing data => no kill).
// Citations: proc_pidinfo https://developer.apple.com/documentation/libproc/1505969-proc_pidinfo
//            getpwuid_r https://developer.apple.com/documentation/man/3/getpwuid_r
int get_user_info_c(int pid, uid_t *out_uid, char *out_username, int username_len);

// Listing PIDs and Bulk Retrieval
int list_pids_c(int *out_pids, int max_count);

// System Execution Helper
void run_system_command_c(const char *cmd);
void run_system_command_popup_c(const char *cmd);
int atomic_rename_c(const char *old_path, const char *new_path);
int get_cpu_ticks_c(unsigned long long *out_user, unsigned long long *out_system,
                    unsigned long long *out_idle, unsigned long long *out_nice);

// Restore normal scheduling for blacklisted processes (clears background scheduling)
void restore_blacklisted_priorities_c(void);

// Explicitly set background scheduling for blacklisted processes
void deprioritize_blacklisted_c(void);

// Pin all current + future daemon memory in RAM via mlockall(2). 0 = success.
int lock_all_memory_c(void);

// Install SIGTERM/SIGINT handlers that only raise an internal flag (async-safe).
void install_shutdown_handlers_c(void);

// Poll the shutdown flag raised by the signal handlers. 1 = shutdown requested.
int shutdown_requested_c(void);

// Total physical RAM in MB (dynamic detection via sysctl hw.memsize).
// Returns 0.0 on failure; callers fall back to a sane default.
// Citation: sysctl hw.memsize https://developer.apple.com/documentation/kernel/1387446-sysctlbyname
double get_total_ram_mb_c(void);

#endif // MACOS_UTILS_H
