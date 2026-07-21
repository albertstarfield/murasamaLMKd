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

// Listing PIDs and Bulk Retrieval
int list_pids_c(int *out_pids, int max_count);

// System Execution Helper
void run_system_command_c(const char *cmd);

// Restore normal scheduling for blacklisted processes (clears background scheduling)
void restore_blacklisted_priorities_c(void);

// Explicitly set background scheduling for blacklisted processes
void deprioritize_blacklisted_c(void);

#endif // MACOS_UTILS_H
