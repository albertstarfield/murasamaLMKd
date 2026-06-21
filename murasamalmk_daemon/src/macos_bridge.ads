with Interfaces.C;

package MacOS_Bridge is
   -- SPARK_Mode => Off: This package declares C imported subprograms via
   -- pragma Import(C, ...). Imported foreign code cannot be verified by SPARK
   -- because its implementation is outside the SPARK domain. All 16 subprograms
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

   function Get_Process_Tree_C (Root_PID : PID_T; Out_Pids : in out PID_Array; Max_Count : int) return int;
   pragma Import (C, Get_Process_Tree_C, "get_process_tree_c");

   procedure Set_Process_Priority_C (PID : PID_T; Priority : int);
   pragma Import (C, Set_Process_Priority_C, "set_process_priority_c");

   procedure Get_Memory_Snapshot_C (Out_Faults : out UINT64_T; Out_Pageins : out UINT64_T; Out_Decomp : out UINT64_T);
   pragma Import (C, Get_Memory_Snapshot_C, "get_memory_snapshot_c");

   function Get_Top_Processes_By_Memory_C (Out_Pids : in out PID_Array; Out_Resident_Bytes : in out UINT64_Array; N : int; Exclude_PID : PID_T) return int;
   pragma Import (C, Get_Top_Processes_By_Memory_C, "get_top_processes_by_memory_c");

   function List_Pids_C (Out_Pids : in out PID_Array; Max_Count : int) return int;
   pragma Import (C, List_Pids_C, "list_pids_c");

   procedure Run_System_Command_C (Cmd : char_array);
   pragma Import (C, Run_System_Command_C, "run_system_command_c");

end MacOS_Bridge;
