with Interfaces.C;

package MacOS_Bridge is
   -- SPARK_Mode => Off: This package declares C imported subprograms via
   -- pragma Import(C, ...). Imported foreign code cannot be verified by SPARK
   -- because its implementation is outside the SPARK domain. All subprograms
   -- here are thin bindings to Objective-C Mach/libproc APIs in macos_utils.m.
   pragma SPARK_Mode (Off);
   pragma Preelaborate;

   use Interfaces.C;

   subtype PID_T is int;
   subtype UID_T is unsigned;
   subtype UINT64_T is unsigned_long_long;

   function Get_Page_Size_C return UINT64_T;
   pragma Import (C, Get_Page_Size_C, "get_page_size_c");

   function Get_Console_UID_C return UID_T;
   pragma Import (C, Get_Console_UID_C, "get_console_uid_c");

   function Get_Memory_Pressure_Level_C return int;
   pragma Import (C, Get_Memory_Pressure_Level_C, "get_memory_pressure_level_c");

   function Get_Free_MB_C (Page_Size : UINT64_T) return double;
   pragma Import (C, Get_Free_MB_C, "get_free_mb_c");

   function Get_Wired_MB_C (Page_Size : UINT64_T) return double;
   pragma Import (C, Get_Wired_MB_C, "get_wired_mb_c");

   -- VM compressor occupied size in MB (Activity Monitor "Compressor" line).
   -- Source: host_statistics64 compressor_page_count (XNU HOST_VM_INFO64).
   function Get_Compressor_MB_C (Page_Size : UINT64_T) return double;
   pragma Import (C, Get_Compressor_MB_C, "get_compressor_mb_c");

   -- Swap usage in MB via sysctl vm.swapusage (struct xsw_usage).
   -- On sysctl failure both outputs are 0.0 (documented in macos_utils.m).
   procedure Get_Swap_Usage_C (Out_Total_MB : out double; Out_Used_MB : out double);
   pragma Import (C, Get_Swap_Usage_C, "get_swap_usage_c");

   function Get_Process_Memory_C (PID : PID_T) return UINT64_T;
   pragma Import (C, Get_Process_Memory_C, "get_process_memory_c");

   function Get_Frontmost_PID_C return PID_T;
   pragma Import (C, Get_Frontmost_PID_C, "get_frontmost_pid_c");

   procedure Get_Process_Name_C (PID : PID_T; Out_Name : out char_array; Max_Len : int);
   pragma Import (C, Get_Process_Name_C, "get_process_name_c");

   procedure Get_Process_Path_C (PID : PID_T; Out_Path : out char_array; Max_Len : int);
   pragma Import (C, Get_Process_Path_C, "get_process_path_c");

   function Is_System_Process_C (Path : char_array) return int;
   pragma Import (C, Is_System_Process_C, "is_system_process_c");

   function Is_Gamepolicyctl_Available_C return int;
   pragma Import (C, Is_Gamepolicyctl_Available_C, "is_gamepolicyctl_available_c");

   procedure Set_Game_Mode_C (State : char_array);
   pragma Import (C, Set_Game_Mode_C, "set_game_mode_c");

   function Get_Parent_PID_C (PID : PID_T) return PID_T;
   pragma Import (C, Get_Parent_PID_C, "get_parent_pid_c");

   type PID_Array is array (int range <>) of aliased PID_T;
   type UINT64_Array is array (int range <>) of aliased UINT64_T;
   -- int64_t (C "long long" on Darwin LP64): leak-scan ages and thresholds.
   subtype INT64_T is long_long;
   type INT64_Array is array (int range <>) of aliased INT64_T;

   function Get_Process_Tree_C (Root_PID : PID_T; Out_Pids : in out PID_Array; Max_Count : int) return int;
   pragma Import (C, Get_Process_Tree_C, "get_process_tree_c");

   procedure Set_Process_Priority_C (PID : PID_T; Priority : int);
   pragma Import (C, Set_Process_Priority_C, "set_process_priority_c");

   procedure Get_Memory_Snapshot_C (Out_Faults : out UINT64_T; Out_Pageins : out UINT64_T; Out_Decomp : out UINT64_T);
   pragma Import (C, Get_Memory_Snapshot_C, "get_memory_snapshot_c");

   function Get_Top_Processes_By_Memory_C (Out_Pids : in out PID_Array; Out_Resident_Bytes : in out UINT64_Array; N : int; Exclude_PID : PID_T) return int;
   pragma Import (C, Get_Top_Processes_By_Memory_C, "get_top_processes_by_memory_c");

   -- Activity Monitor methodology: top-N by ri_phys_footprint (proc_pid_rusage),
   -- which counts resident + compressed + internal memory — NOT plain RSS.
   -- Returns count filled (0 on error). Index 0 = largest footprint (T1).
   function Get_Top_Processes_By_Footprint_C (Out_Pids : in out PID_Array; Out_Footprint_Bytes : in out UINT64_Array; N : int; Exclude_PID : PID_T) return int;
   pragma Import (C, Get_Top_Processes_By_Footprint_C, "get_top_processes_by_footprint_c");

   -- Leak scan: returns pids with ri_phys_footprint STRICTly >
   -- Min_Footprint_Bytes AND wall-clock age STRICTly > Min_Age_Seconds,
   -- largest-footprint-first; self (getpid) and pid < 200 excluded in C.
   -- Returns count filled (0 = none matched OR scan error — errors are
   -- logged to stderr in macos_utils.m; caller treats both as no-op).
   -- Citations: proc_listpids https://developer.apple.com/documentation/libproc/1505977-proc_listpids
   --            proc_pid_rusage https://developer.apple.com/documentation/libproc/1505956-proc_pidrusage
   --            proc_pidinfo https://developer.apple.com/documentation/libproc/1505969-proc_pidinfo
   function Find_Leak_Candidates_C
     (Min_Footprint_Bytes : INT64_T;
      Min_Age_Seconds     : INT64_T;
      Out_Pids            : in out PID_Array;
      Out_Footprint_Bytes : in out UINT64_Array;
      Out_Age_Seconds     : in out INT64_Array;
      N                   : int) return int;
   pragma Import (C, Find_Leak_Candidates_C, "find_leak_candidates_c");

   -- Owner of a pid: PROC_PIDTBSDINFO pbi_uid + getpwuid_r username.
   -- Returns 0 only when BOTH outputs are valid; -1 = owner unknown —
   -- policy rule: caller must NOT kill on -1 (missing data => no kill).
   -- Citations: proc_pidinfo https://developer.apple.com/documentation/libproc/1505969-proc_pidinfo
   --            getpwuid_r https://developer.apple.com/documentation/man/3/getpwuid_r
   function Get_User_Info_C
     (PID          : PID_T;
      Out_UID      : out UID_T;
      Out_Username : out char_array;
      Max_Len      : int) return int;
   pragma Import (C, Get_User_Info_C, "get_user_info_c");

   function List_Pids_C (Out_Pids : in out PID_Array; Max_Count : int) return int;
   pragma Import (C, List_Pids_C, "list_pids_c");

   procedure Run_System_Command_C (Cmd : char_array);
   pragma Import (C, Run_System_Command_C, "run_system_command_c");

   function Atomic_Rename_C (Old_Path : char_array; New_Path : char_array) return int;
   pragma Import (C, Atomic_Rename_C, "atomic_rename_c");

   procedure Restore_Blacklisted_Priorities_C;
   pragma Import (C, Restore_Blacklisted_Priorities_C, "restore_blacklisted_priorities_c");

   procedure Deprioritize_Blacklisted_C;
   pragma Import (C, Deprioritize_Blacklisted_C, "deprioritize_blacklisted_c");

   -- Pin all daemon memory via mlockall(2). Returns 0 on success, -1 on failure.
   -- Rationale: a memory-pressure mitigation daemon must never be paged out
   -- during a crisis; MCL_FUTURE also pins all future heap allocations.
   function Lock_All_Memory_C return int;
   pragma Import (C, Lock_All_Memory_C, "lock_all_memory_c");

   -- Install async-safe SIGTERM/SIGINT flag-only handlers (see macos_utils.m).
   procedure Install_Shutdown_Handlers_C;
   pragma Import (C, Install_Shutdown_Handlers_C, "install_shutdown_handlers_c");

   -- Poll shutdown flag: returns 1 when SIGTERM/SIGINT was received.
   function Shutdown_Requested_C return int;
   pragma Import (C, Shutdown_Requested_C, "shutdown_requested_c");

   -- Total physical RAM in MB (dynamic detection). Returns 0.0 on failure.
   function Get_Total_RAM_MB_C return double;
   pragma Import (C, Get_Total_RAM_MB_C, "get_total_ram_mb_c");

end MacOS_Bridge;
