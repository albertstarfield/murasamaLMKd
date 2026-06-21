-- FIX: Removed 'with Murasama_Types; use Murasama_Types' from spec.
-- REASON: No entities from Murasama_Types are referenced in the spec. The with/use
--         clause belongs in the body where Murasama_Types is actually used.
--         (Warning: -gnatwu)
package Murasama_Weights is
   pragma SPARK_Mode (Off);

   -- Initialize weights
   procedure Init_Weights;

   -- Load weights from file
   procedure Load_Weights;

   -- Save weights to file
   procedure Save_Weights;

   -- Increment weight for a given process name
   procedure Increment_Weight (Name : String);

   -- Decrement all weights (runs periodically)
   procedure Decrement_Weights (Changed : out Boolean);

   -- Get the weight value of a given process name
   function Get_Weight (Name : String) return Natural;

end Murasama_Weights;
