PROGRAM PLC_PRG
VAR
init : BOOL;
DEV_ERROR_STATE : state_device_error;
device_type : BH_DeviceSingleType;
END_VAR

IF NOT init THEN
	
Read_SV_flow := 0;
Read_AV_flow := 0;
Read_unit_flow := 'mln/min';
Read_alarm_info_flow := 0;

Read_SV_p_up := 1;
Read_AV_p_up := 1;
Read_unit_p_up := 'bar';
Read_alarm_info_p_up := 0;

Read_SV_p_down := 1;
Read_AV_p_down := 1;
Read_unit_p_down := 'bar';
Read_alarm_info_p_down := 0;

Read_temperature := 0;
Read_density := 0;
	
Read_UserTag := '';
Read_FluidName := '';
Read_SN := 'TESTSN';
Read_status := 0;
Read_AlarmMode := 0;
Read_ControlMode := 0;
Read_ControlFunction := 0;

Write_SVreq_flow := 0;
Write_SVreq_p_up := 0;
Write_SVreq_p_down := 0;
Write_ControlMode := 0;
Write_ControlFunction := 0;
Write_UserTag := '';
Write_Reset_to_device := 0;
Write_Reset_Alarm_Enable := 0;

init := TRUE;

END_IF

(* device_type := CORIFLOW; *)
device_type := ELPRESS;

CASE device_type OF
CORIFLOW:
		CORIFLOW_CONTROLLER.Input_DeviceInstance := CORIFLOW_INSTANCE;
		CORIFLOW_CONTROLLER.Input_DeviceType := device_type;
		
		CORIFLOW_CONTROLLER.Input.AlarmInfo := Read_alarm_info_flow;
		CORIFLOW_CONTROLLER.Input.AV := Read_AV_flow;
		CORIFLOW_CONTROLLER.Input.SV := Read_SV_flow;
		CORIFLOW_CONTROLLER.Input.Unit := Read_unit_flow;
		
		CORIFLOW_CONTROLLER.Input_temperature:= Read_temperature;
		CORIFLOW_CONTROLLER.Input_density:= Read_density;
		
		CORIFLOW_CONTROLLER.Input_UserTag:= Read_UserTag;
		CORIFLOW_CONTROLLER.Input_FluidName:= Read_FluidName;
		CORIFLOW_CONTROLLER.Input_SN:= Read_SN;
		CORIFLOW_CONTROLLER.Input_status:= Read_status;
		CORIFLOW_CONTROLLER.Input_AlarmMode:= Read_AlarmMode;
		CORIFLOW_CONTROLLER.Input_ControlMode:= Read_ControlMode;
		
		CORIFLOW_CONTROLLER;
		
		Write_SVreq_flow := CORIFLOW_CONTROLLER.Output_SVreq;
		Write_ControlMode := CORIFLOW_CONTROLLER.Output_ControlMode;
		Write_ControlFunction := CORIFLOW_CONTROLLER.Output_ControlFunction;
		Write_Reset_to_device := CORIFLOW_CONTROLLER.Output_Reset_to_device;
		Write_UserTag := CORIFLOW_CONTROLLER.Output_UserTag;
		Write_Reset_Alarm_Enable := CORIFLOW_CONTROLLER.Output_Reset_Alarm_Enable;
		DEV_ERROR_STATE := CORIFLOW_CONTROLLER.Output_ErrorState;
		
		CORIFLOW_INSTANCE := CORIFLOW_CONTROLLER.Output_DeviceInstance;
		
		
		Read_SV_flow := Write_SVreq_flow;
		Read_AV_flow := Read_AV_flow + (Write_SVreq_flow-Read_AV_flow)*0.05;
		Read_ControlMode := Write_ControlMode;
		Read_UserTag := Write_UserTag;

ELPRESS:
		ELPRESS_CONTROLLER.Input_DeviceInstance := ELPRESS_INSTANCE;
		ELPRESS_CONTROLLER.Input_DeviceType := device_type;
		
		ELPRESS_CONTROLLER.Input.AlarmInfo := Read_alarm_info_p_up;
		ELPRESS_CONTROLLER.Input.AV := Read_AV_p_up;
		ELPRESS_CONTROLLER.Input.SV := Read_SV_p_up;
		ELPRESS_CONTROLLER.Input.Unit := Read_unit_p_up;
		
		ELPRESS_CONTROLLER.Input_temperature:= Read_temperature;
		ELPRESS_CONTROLLER.Input_density:= Read_density;
		
		ELPRESS_CONTROLLER.Input_UserTag:= Read_UserTag;
		ELPRESS_CONTROLLER.Input_FluidName:= Read_FluidName;
		ELPRESS_CONTROLLER.Input_SN:= Read_SN;
		ELPRESS_CONTROLLER.Input_status:= Read_status;
		ELPRESS_CONTROLLER.Input_AlarmMode:= Read_AlarmMode;
		ELPRESS_CONTROLLER.Input_ControlMode:= Read_ControlMode;
		
		ELPRESS_CONTROLLER;
		
		Write_SVreq_p_up := ELPRESS_CONTROLLER.Output_SVreq;
		Write_ControlMode := ELPRESS_CONTROLLER.Output_ControlMode;
		Write_ControlFunction := ELPRESS_CONTROLLER.Output_ControlFunction;
		Write_Reset_to_device := ELPRESS_CONTROLLER.Output_Reset_to_device;
		Write_UserTag := ELPRESS_CONTROLLER.Output_UserTag;
		Write_Reset_Alarm_Enable := ELPRESS_CONTROLLER.Output_Reset_Alarm_Enable;
		DEV_ERROR_STATE := ELPRESS_CONTROLLER.Output_ErrorState;
		
		ELPRESS_INSTANCE := ELPRESS_CONTROLLER.Output_DeviceInstance;
		
		
		Read_SV_p_up := Write_SVreq_p_up;
		Read_AV_p_up := Read_AV_p_up + (Write_SVreq_p_up-Read_AV_p_up)*0.05;
		Read_ControlMode := Write_ControlMode;
		Read_UserTag := Write_UserTag;
		
ELSE
		MFC_CONTROLLER.Input_DeviceInstance := MFC_INSTANCE;
		
		MFC_CONTROLLER.Input_flow.AlarmInfo := Read_alarm_info_flow;
		MFC_CONTROLLER.Input_flow.AV := Read_AV_flow;
		MFC_CONTROLLER.Input_flow.SV := Read_SV_flow;
		MFC_CONTROLLER.Input_flow.Unit := Read_unit_flow;
		
		MFC_CONTROLLER.Input_p_up.AlarmInfo := Read_alarm_info_p_up;
		MFC_CONTROLLER.Input_p_up.AV := Read_AV_p_up;
		MFC_CONTROLLER.Input_p_up.SV := Read_SV_p_up;
		MFC_CONTROLLER.Input_p_up.Unit := Read_unit_p_up;
		
		MFC_CONTROLLER.Input_p_down.AlarmInfo := Read_alarm_info_p_down;
		MFC_CONTROLLER.Input_p_down.AV := Read_AV_p_down;
		MFC_CONTROLLER.Input_p_down.SV := Read_SV_p_down;
		MFC_CONTROLLER.Input_p_down.Unit := Read_unit_p_down;
		
		MFC_CONTROLLER.Input_UserTag:= Read_UserTag;
		MFC_CONTROLLER.Input_FluidName:= Read_FluidName;
		MFC_CONTROLLER.Input_SN:= Read_SN;
		MFC_CONTROLLER.Input_status:= Read_status;
		MFC_CONTROLLER.Input_AlarmMode:= Read_AlarmMode;
		MFC_CONTROLLER.Input_ControlMode:= Read_ControlMode;
		MFC_CONTROLLER.Input_ControlFunction:= Read_ControlFunction;
		
		MFC_CONTROLLER;
		
		Write_SVreq_flow := MFC_CONTROLLER.Output_SVreq_flow;
		Write_SVreq_p_up := MFC_CONTROLLER.Output_SVreq_p_up;
		Write_SVreq_p_down := MFC_CONTROLLER.Output_SVreq_p_down;
		Write_ControlMode := MFC_CONTROLLER.Output_ControlMode;
		Write_ControlFunction := MFC_CONTROLLER.Output_ControlFunction;
		Write_Reset_to_device := MFC_CONTROLLER.Output_Reset_to_device;
		Write_UserTag := MFC_CONTROLLER.Output_UserTag;
		Write_Reset_Alarm_Enable := MFC_CONTROLLER.Output_Reset_Alarm_Enable;
		DEV_ERROR_STATE := MFC_CONTROLLER.Output_ErrorState;
		
		MFC_INSTANCE := MFC_CONTROLLER.Output_DeviceInstance;
		
		
		Read_SV_flow := Write_SVreq_flow;
		Read_AV_flow := Read_AV_flow + (Write_SVreq_flow-Read_AV_flow)*0.05;
		Read_SV_p_up := Write_SVreq_p_up;
		Read_AV_p_up := Read_AV_p_up + (Write_SVreq_p_up-Read_AV_p_up)*0.05;
		Read_SV_p_down := Write_SVreq_p_down;
		Read_AV_p_down := Read_AV_p_down + (Write_SVreq_p_down-Read_AV_p_down)*0.05;
		Read_ControlMode := Write_ControlMode;
		Read_ControlFunction := Write_ControlFunction;
		Read_UserTag := Write_UserTag;

END_CASE

;
END_PROGRAM

ACTIONS

END_ACTIONS