FUNCTION_BLOCK FB_Bronkhorst_FFDevice_RTU
VAR_INPUT
	Input_DeviceInstance: MFC_BHFF;
	
	Input_flow: FF_ProcessValue;
	Input_p_up: FF_ProcessValue;
	Input_p_down: FF_ProcessValue;
	
	Input_UserTag : STRING;
	Input_FluidName : STRING;
	Input_SN : STRING;
	Input_status : SINT;
	Input_AlarmMode : SINT;
	Input_ControlMode : SINT := 23; (*23: CONTROLMODE_DEACTIVATED*)
	Input_ControlFunction : SINT;
	Input_AV_Timeout : TIME := T#300s;
	Input_SV_Accept_Timeout: TIME := T#10s;

END_VAR

VAR_OUTPUT

	Output_SVreq_flow : REAL;
	Output_SVreq_p_up : REAL;
	Output_SVreq_p_down : REAL;
	Output_ControlMode : SINT;
	Output_ControlFunction : SINT;
	Output_Reset_to_device : SINT;
	Output_UserTag : STRING;
	Output_ErrorState : state_device_error := DEV_ERR_NONE;
	Output_DeviceInstance : MFC_BHFF;
	
END_VAR

VAR_IN_OUT

END_VAR

VAR
	state			: state_device := DV_INIT;
	state_next		: state_device := DV_INIT;
    state_prev      : state_device := DV_INIT;
    StateEntry		: BOOL;
    
    (* ==== Initialisierung ==== *)
    
    t_init_timeout   : TON;
    init_timeout     : TIME := T#5s;

    sn_valid         : BOOL;
    msg_str			 : STRING(255) := 'Device disabled.';
    
    req_reset		 : BOOL := FALSE;
	
	Input_alarm_info_flow : ARRAY [1..8] OF BOOL;
	Input_alarm_info_p_up : ARRAY [1..8] OF BOOL;
	Input_alarm_info_p_down : ARRAY [1..8] OF BOOL;
	
	Input_p_up_SV_mbarg: REAL; (* mbar(g) *)
	Input_p_up_AV_mbarg: REAL; (* mbar(a) *)
	Input_p_up_unit_mbarg: STRING := 'mbar (g)'; (* mbar (g) *)
	
	Input_p_down_SV_mbarg: REAL; (* mbar(g) *)
	Input_p_down_AV_mbarg: REAL; (* mbar(g) *)
	Input_p_down_unit_mbarg: STRING := 'mbar (g)'; (* mbar(g) *)
	
	FLAG_Alarm: BOOL := FALSE;
	FLAG_Warning: BOOL := FALSE;
	
    (* ==== Konfigurations-Latches ==== *)
    cfg_function_req : SINT;
    cfg_function_act : SINT;

    cfg_mode_req     : SINT;
    cfg_mode_act     : SINT;
    setpoint_mode_allowed : BOOL;

    cfg_pending      : BOOL;   (* TRUE sobald Funktion ODER Mode geändert wurde *)

    (* ==== SV-Latches ==== *)
    sv_req : FF_SV_LATCH;
	
	activePrimary : BH_ActiveChannel;
	activeSecondary : BH_ActiveChannel;
	secondaryChannelActive : BOOL;

	sv_rejected		 : BOOL;
	sv_changed		 : BOOL;
	sv_outofrange	 : BOOL;
    sv_pending       : BOOL;
    sv_applied		 : BOOL;
    sv_reached		 : BOOL;
    sv_maintained	 : BOOL;
    sv_accepted      : BOOL;   (* Gerät hat SV übernommen *)
    sv_active		 : BOOL;
    
   	SV_lower_range_limit : REAL;
	SV_upper_range_limit : REAL;
	AV_lower_range_limit : REAL;
	AV_upper_range_limit : REAL;
	SV_tolerance : REAL := 1.0; (* Fallback-Wert - Einstellung über User.Settings*)
	SV_in_range : BOOL := FALSE;
	AV_in_range : BOOL := FALSE;
    
    t_sv_accept   		: TON;
    t_av_timeout		: TON;
    t_av_NOTmaintained	: TON;

	
	(* ==== User Messages ==== *)
	prefix	: STRING;
	cf_str 	: STRING;
	cm_str	: STRING;
	sv_str	: STRING;
	unit_str: STRING;
	dev_status_str: STRING(255);
	err_msg	: STRING(255);
	warning_detail_str : STRING(255);
    
    (* ==== Magic Numbers ==== *)
	CONTROLMODE_DEACTIVATED : SINT := 23;
   	P_MAX_BAR : REAL := 3000.0; (* mbar (g)*)
	
	(* ==== Labels ==== *)
	alarm_lable : STRING := 'Alarm: ';
	error_lable : STRING := 'Error: ';
	warning_lable : STRING := 'Warning: ';
	notification_lable : STRING := 'Info: ';
	
	k : INT;

	
END_VAR

(* Eingangsdaten *)
Output_DeviceInstance := Input_DeviceInstance;
ACT_ProcessAlarmInfo_Input;
ACT_pInput_bara_to_mbarg;

(* User Requests *)
ACT_Latch_ControlFunction;
ACT_Latch_ControlMode;
ACT_Latch_SVreq;

(* Diagnose *)
ACT_Map_AlarmInfo;
ACT_AlarmInfo_wo_text;
ACT_Status_wo_text;

ACT_SelectActiveChannel;

(* STATE MACHINE *)
state_prev := state;
state := state_next;
StateEntry := state <> state_prev;

CASE state OF
	
	DV_INIT:
			ACT_Init;
			setpoint_mode_allowed := FALSE;
			
	DV_DISABLED:
			setpoint_mode_allowed := FALSE;
			IF Input_DeviceInstance.enable THEN
				state_next := DV_IDLE;
			ELSE
				ACT_Central_SVreq_Discard;
			END_IF
			
	DV_IDLE:
			IF StateEntry THEN
				ACT_Central_SVreq_Discard;
			END_IF
			
			(* === State neu festlegen === *)
			IF cfg_pending OR sv_pending THEN
				state_next := DV_SETTING_REQ;
			END_IF
			;
			
	DV_SETTING_REQ:
			ACT_Commit_Config;
			
			IF sv_pending OR sv_applied THEN
				ACT_Handle_SV;
			END_IF
			
			(* === State neu festlegen === *)
	        IF NOT cfg_pending AND NOT sv_pending AND NOT sv_applied AND NOT sv_accepted THEN
	            state_next := DV_IDLE;
	        ELSIF sv_accepted THEN
	            state_next := DV_CONTROLLING;
	        ELSIF t_sv_accept.Q THEN
				Output_ErrorState := DEV_ERR_SV_ACCEPT_TIMEOUT;
			    state_next := DV_ERROR;
	        END_IF
			;		
	DV_CONTROLLING:
			IF cfg_pending THEN
				state_next := DV_IDLE;
			ELSIF sv_pending THEN
				state_next := DV_SETTING_REQ;
			ELSIF NOT sv_active THEN
	            state_next := DV_IDLE;
	        ELSIF sv_reached THEN
	            state_next := DV_SETTLED;
	        ELSIF t_av_timeout.Q THEN
            	Output_ErrorState := DEV_ERR_AV_Reach_TIMEOUT;
                state_next := DV_ERROR;
            ELSE
            	ACT_Controlling;
			END_IF
			;
	DV_SETTLED:
			IF cfg_pending THEN
				state_next := DV_IDLE;
			ELSIF sv_pending THEN
				state_next := DV_SETTING_REQ;
			ELSIF NOT sv_active THEN
	            state_next := DV_IDLE;
	        ELSIF t_av_NOTmaintained.Q THEN
            	state_next := DV_ERROR;
            	Output_ErrorState := DEV_ERR_AV_Maintain_TIMEOUT;
            ELSE
            	ACT_Settled;
			END_IF
					
			;
	DV_ERROR:
			ACT_Latch_Reset;
			setpoint_mode_allowed := FALSE;
			IF req_reset THEN
				
				ACT_Reset_BH_Device;
				state_next := DV_IDLE;
				req_reset := FALSE;
				
				Output_ErrorState := DEV_ERR_NONE;
			END_IF
END_CASE

(* GLOBAL STATE TRANSITIONS *)
IF FLAG_Alarm THEN
	state_next := DV_ERROR;

ELSIF NOT Input_DeviceInstance.enable THEN
	state_next := DV_DISABLED;
END_IF


(* Outputs *)
ACT_Output_To_Device_And_User;
ACT_Build_StatusMessage;

END_FUNCTION_BLOCK

ACTIONS
	ACTION ACT_Init
		
		IF StateEntry THEN
	    (* Timeout starten *)
	   		t_init_timeout(IN := TRUE, PT := init_timeout);
	    END_IF
	
	    (* Seriennummer vom Gerät lesen *)
	    Output_DeviceInstance.serialnumber := Input_SN;
	
	    (* Plausibilitätsprüfung *)
	    sn_valid := (LEN(Input_SN) >= 4) AND (Input_SN <> '0000');
	
	    IF sn_valid THEN
	        (* Verbindung erfolgreich *)
	        t_init_timeout(IN := FALSE);
	        Output_DeviceInstance.status_msg :=  CONCAT('Device connection established. SN=',Input_SN);
			
			(* Erstmaligen Status abrufen *)
		    cfg_pending := TRUE;
		    
		    ACT_cfg_function_feedback;
		    ACT_cfg_mode_feedback;
		    
		    Output_ErrorState := DEV_ERR_NONE;
		    state_next := DV_IDLE;
	    END_IF

	    (* Timeout abgelaufen -> Fehler *)
	    IF t_init_timeout.Q THEN
			Output_ErrorState := DEV_ERR_INIT;
	        Output_DeviceInstance.status_msg := 'ERROR: Device connection timeout – no valid serial number';
	        state_next := DV_ERROR;
	    END_IF
	
	END_ACTION
		
	ACTION ACT_pInput_bara_to_mbarg
		Input_p_up_SV_mbarg := Input_p_up.SV*1000-1000; (* mbar(g) *)
		Input_p_up_AV_mbarg := Input_p_up.AV*1000-1000; (* mbar(a) *)
	
		Input_p_down_SV_mbarg := Input_p_down.SV*1000-1000; (* mbar(g) *)
		Input_p_down_AV_mbarg := Input_p_down.AV*1000-1000; (* mbar(g) *)
	END_ACTION
	
	ACTION ACT_Latch_Reset
		
		(* ERROR Reset *)
		
		req_reset := Input_DeviceInstance.reset;
		Input_DeviceInstance.reset := FALSE;
		Output_DeviceInstance.reset := FALSE;
	END_ACTION
	
	ACTION ACT_Latch_ControlFunction
	    (* ControlFunction *)
	    IF Input_DeviceInstance.control_function_req <> Input_ControlFunction THEN
	        cfg_function_req := Input_DeviceInstance.control_function_req;
	        cfg_pending := TRUE;
	    END_IF
	    cfg_function_act := Input_ControlFunction;
	    
	    IF cfg_pending THEN
	    	ACT_Central_SVreq_Discard;
	    END_IF
	END_ACTION
	
	ACTION ACT_Latch_ControlMode
	    (* ControlMode *)
	    IF Input_DeviceInstance.control_mode_req <> Input_ControlMode THEN
	        cfg_mode_req := Input_DeviceInstance.control_mode_req;
	        cfg_pending := TRUE;
	    END_IF
	    cfg_mode_act := Input_ControlMode;
	    
	    setpoint_mode_allowed := (cfg_mode_act = 0);   (* 0 = BUS/RS232 *)
	    
	    IF NOT setpoint_mode_allowed THEN
	    	ACT_Central_SVreq_Discard;
	    END_IF
	END_ACTION

	ACTION ACT_Latch_SVreq	
	    (* SV Requests *)
	    IF NOT cfg_pending AND setpoint_mode_allowed THEN
	    
	    sv_changed := FALSE;
	    
	    	CASE cfg_function_act OF
		    0:    
		    	sv_changed := ABS(Input_DeviceInstance.SV_flow_req - Input_flow.SV) >= 0.001;

				IF sv_changed THEN
		            sv_req.Flow := Input_DeviceInstance.SV_flow_req;
		        END_IF
			1:
		        sv_changed := ABS(Input_DeviceInstance.SV_p_up_req - Input_p_up_SV_mbarg) >= 0.001;

				IF sv_changed THEN
		            sv_req.PUp := Input_DeviceInstance.SV_p_up_req;
		        END_IF
			2:
		        sv_changed := ABS(Input_DeviceInstance.SV_p_down_req - Input_p_down_SV_mbarg) >= 0.001;

				IF sv_changed THEN
		            sv_req.PDown := Input_DeviceInstance.SV_p_down_req;
				END_IF
			4:
				sv_changed := ABS(Input_DeviceInstance.SV_p_down_req - Input_p_down_SV_mbarg) >= 0.001 OR
					ABS(Input_DeviceInstance.SV_flow_req - Input_flow.SV) >= 0.001;
				
				IF sv_changed THEN
		            sv_req.PDown := Input_DeviceInstance.SV_p_down_req;
		            sv_req.Flow := Input_DeviceInstance.SV_flow_req;
		        END_IF
		    END_CASE 
		    
		    IF sv_changed THEN		
				ACT_Reset_SV_Lifecycle;	(* Lebenszyklus neu starten *)
	            sv_pending := TRUE;
	        END_IF
	        
	    END_IF
	
	END_ACTION
	
	ACTION ACT_Reset_SV_Lifecycle
		sv_rejected := FALSE;
	    sv_applied  := FALSE;
	    sv_accepted := FALSE;
	    sv_reached  := FALSE;
	    sv_maintained := FALSE;
	    
	    t_sv_accept(IN := FALSE);
		t_av_timeout(IN := FALSE);
		t_av_NOTmaintained(IN := FALSE);
	    
	END_ACTION
	
	ACTION ACT_Controlling
			(* === CONTROLLING: Überwachung === *)

	        (* Timeout *)
	        CASE cfg_function_act OF
	        0..2:
	        	t_av_timeout(IN := NOT sv_reached, PT := Input_AV_Timeout);
	        4:
	        	t_av_timeout(IN := NOT sv_reached, PT := T#300s);
	        END_CASE
	
	        IF t_av_timeout.Q THEN
	        	RETURN;
	        END_IF
	        
	        (* Toleranzprüfung *)
	        AV_lower_range_limit := activePrimary.SVreq * (100.0-(SV_tolerance*0.5))/100.0;
			AV_upper_range_limit := activePrimary.SVreq * (100.0+(SV_tolerance*0.5))/100.0;
	
			AV_in_range := INRANGE(AV_lower_range_limit,activePrimary.AV,AV_upper_range_limit);
			
	        IF AV_in_range THEN
	            sv_reached := TRUE;
	        ELSE
	        	sv_reached := FALSE;
	        END_IF

	END_ACTION
	
	ACTION ACT_Settled
			(* Timeout *)
	    	t_av_NOTmaintained(IN := NOT sv_maintained, PT := T#10s); (* Variabel über User !!*)
	        
	        (* Rückfall, falls Wert wieder wegdriftet *)
	        AV_lower_range_limit := activePrimary.SVreq * (100.0-(SV_tolerance*1))/100.0;
			AV_upper_range_limit := activePrimary.SVreq * (100.0+(SV_tolerance*1))/100.0;
	
			AV_in_range := INRANGE(AV_lower_range_limit,activePrimary.AV,AV_upper_range_limit);
	        IF AV_in_range THEN
	        	sv_maintained := TRUE;
	        ELSE
	        	sv_maintained := FALSE;
	        END_IF
	END_ACTION
	
	ACTION ACT_Central_SVreq_Discard

        sv_pending := FALSE;

        (* SV-Latches zurücksetzen *)
		sv_req.Flow   := 0.0;
	    sv_req.PUp   := 0.0;
	    sv_req.PDown := 0.0;

        (* Lebenszyklus vollständig zurücksetzen *)
        ACT_Reset_SV_Lifecycle;

        (* Rückmeldung an User *)
        Output_DeviceInstance.SV_flow_req   := 0.0;
        Output_DeviceInstance.SV_p_up_req   := 0.0;
        Output_DeviceInstance.SV_p_down_req := 0.0;
		
		(* Device Reset zurücksetzten *)
		Output_Reset_to_device := 0;
	END_ACTION
	
	ACTION ACT_cfg_function_feedback
		CASE cfg_function_act OF
	        0: cf_str := ': Flow';
	        1: cf_str := ': Upstream pressure';
	        2: cf_str := ': Downstream pressure';
	        4: cf_str := ': Downstream pressure with flow limit';
	    ELSE
            cf_str := ' - undefined';
        END_CASE
	END_ACTION
	
	ACTION ACT_cfg_mode_feedback
		CASE cfg_mode_act OF
			0: cm_str := 'BUS/RS232';
			1: cm_str := 'Analog input';
			2: cm_str := 'FLOW-BUS slave';
			3: cm_str := 'Valve close';
			4: cm_str := 'Controller idle';
			5: cm_str := 'Testing mode';
			6: cm_str := 'Tuning mode';
			7: cm_str := 'Setpoint 100%';
			8: cm_str := 'Valve fully open';
			9: cm_str := 'Calibration mode';
			10: cm_str := 'Analog slave';
			12: cm_str := 'setpoint 0%';
			13: cm_str := 'FLOW-BUS analog slave';
			18: cm_str := 'RS232';
			20: cm_str := 'valve steering (valve = setpoint)';
			21: cm_str := 'analog valve steering(valve = analog input)';
			22: cm_str := 'valve safe state';
		ELSE
            cm_str := ' - undefined';
		END_CASE
	END_ACTION
	
	ACTION ACT_SelectActiveChannel
		
		secondaryChannelActive := FALSE;
		
		CASE cfg_function_act OF
		
		0: (* Flow *)
			activePrimary.SVreq := sv_req.Flow;
			activePrimary.AV := Input_flow.AV;
			activePrimary.DeviceSV := Input_flow.SV;
			activePrimary.Unit := Input_flow.Unit;
			activePrimary.SV_Min := Input_DeviceInstance.lower_limit;
			activePrimary.SV_Max := Input_DeviceInstance.upper_limit;
		1: (* Upstream Pressure *)
			activePrimary.SVreq := sv_req.PUp;
			activePrimary.AV := Input_p_up_AV_mbarg;
			activePrimary.DeviceSV := Input_p_up_SV_mbarg;
			activePrimary.Unit := Input_p_up_unit_mbarg;
			activePrimary.SV_Min := 0.0;
			activePrimary.SV_Max := P_MAX_BAR;
		2: (* Downstream Pressure *)
			activePrimary.SVreq := sv_req.PDown;
			activePrimary.AV := Input_p_down_AV_mbarg;
			activePrimary.DeviceSV := Input_p_down_SV_mbarg;
			activePrimary.Unit := Input_p_down_unit_mbarg;
			activePrimary.SV_Min := 0.0;
			activePrimary.SV_Max := P_MAX_BAR;			
		4: (* Downstream Pressure w flow limit *)
			activePrimary.SVreq := sv_req.PDown;
			activePrimary.AV := Input_p_down_AV_mbarg;
			activePrimary.DeviceSV := Input_p_down_SV_mbarg;
			activePrimary.Unit := Input_p_down_unit_mbarg;
			activePrimary.SV_Min := 0.0;
			activePrimary.SV_Max := P_MAX_BAR;
			
			secondaryChannelActive := TRUE;
			activeSecondary.SVreq := sv_req.Flow;
			activeSecondary.AV := Input_flow.AV;
			activeSecondary.DeviceSV := Input_flow.SV;
			activeSecondary.Unit := Input_flow.Unit;
			activeSecondary.SV_Min := Input_DeviceInstance.lower_limit;
			activeSecondary.SV_Max := Input_DeviceInstance.upper_limit;

		END_CASE
	
		sv_active := (activePrimary.SVreq <> 0.0);
	END_ACTION
	
	ACTION ACT_Commit_Config

	    IF cfg_pending THEN
	
	        (* === Commit ControlFunction === *)
	        Output_ControlFunction := cfg_function_req;
	            
	        IF Input_ControlFunction = cfg_function_req THEN
		       ACT_cfg_function_feedback;
	        END_IF
	
			 (* === Commit ControlMode === *)
	        Output_ControlMode := cfg_mode_req;
	        
			IF Input_ControlMode = cfg_mode_req THEN
		        ACT_cfg_mode_feedback;
	        END_IF
			
			IF  Input_ControlMode = cfg_mode_req AND Input_ControlFunction = cfg_function_req THEN
		        cfg_pending := FALSE;
	        END_IF
		
	    END_IF
	
	END_ACTION
	
	ACTION ACT_Handle_SV
		
		IF NOT setpoint_mode_allowed THEN
		    sv_rejected := TRUE;
		    RETURN;
		END_IF

	    (* Nur relevante States - nötig? *)
	    IF (state <> DV_SETTING_REQ) AND
	       (state <> DV_CONTROLLING) AND
	       (state <> DV_SETTLED) THEN
	        sv_rejected := TRUE;
	        RETURN;
	    END_IF
	
	    (* Keine Arbeit bei Config-Wechsel *)
	    IF cfg_pending THEN
	    	sv_rejected := TRUE;
	        RETURN;
	    END_IF
		
		sv_str := CONCAT(REAL_TO_STRING(activePrimary.SVreq),activePrimary.Unit);
		
	    IF secondaryChannelActive THEN
			sv_str := CONCAT(sv_str,' (Flow limit ');
			sv_str := CONCAT(sv_str,REAL_TO_STRING(activeSecondary.SVreq));
			sv_str := CONCAT(sv_str,' ');
			sv_str := CONCAT(sv_str,activeSecondary.Unit);
			sv_str := CONCAT(sv_str,')');
		END_IF
	
		IF NOT sv_applied THEN
		
	        (* Bereich prüfen *)
			SV_in_range := INRANGE(activePrimary.SV_Min, activePrimary.SVreq, activePrimary.SV_Max);
			
			IF NOT SV_in_range THEN
			    (* === Ungültigen User-Sollwert zurückweisen === *)
			
			    sv_pending := FALSE;
				
				IF activePrimary.SVreq < activePrimary.SV_Min OR activePrimary.SVreq > activePrimary.SV_Max THEN
				    (* User-SV auf aktuell gültigen Sollwert zurücksetzen *)
				    ACT_Restore_UserSetpoints;
				
				    (* Optional: Statusmeldung *)
				    sv_outofrange := TRUE;
					sv_rejected := TRUE;
					
				    RETURN;
				  END_IF
			END_IF
			
			sv_outofrange := FALSE;
	        sv_applied := TRUE;
	        sv_pending := FALSE;
		END_IF
		
		(* Prüfen, ob Gerät SV übernommen hat *)
		IF sv_applied AND NOT sv_accepted THEN
			(* Akzeptanz-Timer starten *)
		    t_sv_accept(IN := TRUE, PT := Input_SV_Accept_Timeout);
		    
		    IF NOT secondaryChannelActive THEN
				
				IF activePrimary.SVreq = activePrimary.DeviceSV THEN
					sv_accepted := TRUE;
				END_IF
				
			ELSE
				
				IF ABS(activePrimary.SVreq - activePrimary.DeviceSV)<= activePrimary.SVreq * 0.01 AND
					activeSecondary.SVreq = activeSecondary.DeviceSV THEN
					sv_accepted := TRUE;
				END_IF
				
			END_IF

		END_IF

	END_ACTION
	
	ACTION ACT_Restore_UserSetpoints
		 Output_DeviceInstance.SV_flow_req   := sv_req.Flow;
		 Output_DeviceInstance.SV_p_up_req   := sv_req.PUp;
		 Output_DeviceInstance.SV_p_down_req := sv_req.PDown;
	END_ACTION
	
	ACTION ACT_Output_To_Device_And_User

	    (* ================================================= *)
	    (* Default: keine Sollwerte an das Gerät             *)
	    (* ================================================= *)
	    Output_SVreq_flow   := 0.0;
	    Output_SVreq_p_up   := 0.0;
	    Output_SVreq_p_down := 0.0;
	
	    (* ================================================= *)
	    (* Sollwert nur ausgeben, wenn er gültig angewandt    *)
	    (* ================================================= *)
	    IF sv_applied AND
	       (state = DV_SETTING_REQ OR state = DV_CONTROLLING OR state = DV_SETTLED) THEN
			
	        CASE cfg_function_act OF
	
	            0:  (* Flow *)
	            	IF sv_req.Flow > 0 THEN
	                	Output_SVreq_flow := sv_req.Flow;
	                END_IF
	
	            1:  (* Upstream pressure *)
	                Output_SVreq_p_up := sv_req.PUp/1000+1; (* Umrechnung von mbar (g) zu bar (a) *)
	
	            2:  (* Downstream pressure *)
	                Output_SVreq_p_down := sv_req.PDown/1000+1; (* Umrechnung von mbar (g) zu bar (a) *)
	
	            4:  (* Downstream pressure with flow limit *)
	                Output_SVreq_p_down := sv_req.PDown/1000+1; (* Umrechnung von mbar (g) zu bar (a) *)
	                Output_SVreq_flow   := sv_req.Flow;
	
	        END_CASE
	    END_IF
	
	
	    (* ================================================= *)
	    (* Status an User                                    *)
	    (* ================================================= *)
		ACT_ReadAV;

	    Output_DeviceInstance.control_function := cfg_function_act;
	    Output_DeviceInstance.control_mode     := cfg_mode_act;
		Output_DeviceInstance.control_function_req := cfg_function_req;
	    Output_DeviceInstance.control_mode_req     := cfg_mode_req;
		
		Output_DeviceInstance.state := state;
		Output_DeviceInstance.enable := Input_DeviceInstance.enable;
		Output_DeviceInstance.SVaccepted := sv_accepted;
		Output_DeviceInstance.SVrejected := sv_rejected;
		Output_DeviceInstance.SVreached := sv_reached;
	    Output_DeviceInstance.SV_flow_req := sv_req.Flow;
	    Output_DeviceInstance.SV_flow := Input_flow.SV;
		Output_DeviceInstance.SV_p_up_req := sv_req.PUp;
		Output_DeviceInstance.SV_p_up := Input_p_up_SV_mbarg;
		Output_DeviceInstance.SV_p_down_req := sv_req.PDown;
		Output_DeviceInstance.SV_p_down := Input_p_down_SV_mbarg;
		
		
	END_ACTION
	
	ACTION ACT_Map_AlarmInfo
	
	    CASE cfg_function_act OF
	        0:  Output_DeviceInstance.alarm_info := Input_alarm_info_flow;
	        1:  Output_DeviceInstance.alarm_info := Input_alarm_info_p_up;
	        2,4: Output_DeviceInstance.alarm_info := Input_alarm_info_p_down;
	    END_CASE
	
	END_ACTION
	
	ACTION ACT_ReadAV
		Output_DeviceInstance.media := Input_FluidName;
		IF Input_flow.AV > Input_DeviceInstance.upper_limit/500 THEN
			Output_DeviceInstance.AV_flow := Input_flow.AV;
		ELSE Output_DeviceInstance.AV_flow := 0;
		END_IF;
		Output_DeviceInstance.unit_flow := Input_flow.Unit;
		Output_DeviceInstance.AV_p_up := Input_p_up_AV_mbarg;
		Output_DeviceInstance.unit_p := Input_p_up.Unit;
		Output_DeviceInstance.AV_p_down := Input_p_down_AV_mbarg;
		Output_DeviceInstance.unit_p := Input_p_down.Unit;
		Output_DeviceInstance.serialnumber := Input_SN;
		Output_DeviceInstance.name := Input_UserTag;
	END_ACTION

	ACTION ACT_ProcessAlarmInfo_Input
		
		Input_alarm_info_flow := BH_AlarmBitTOAlarmArray(Input_flow.AlarmInfo);
		Input_alarm_info_p_up := BH_AlarmBitTOAlarmArray(Input_p_up.AlarmInfo);
		Input_alarm_info_p_down := BH_AlarmBitTOAlarmArray(Input_p_down.AlarmInfo);
		
	END_ACTION
	
	ACTION ACT_AlarmInfo_wo_text

	    FLAG_Alarm := FALSE;
	    FLAG_Warning := FALSE;
		
		warning_detail_str := '';
		
	    FOR k := 1 TO 8 DO
	        IF Output_DeviceInstance.alarm_info[k] THEN
	
	            CASE k OF
	                1: (* Alarm *)
	                    FLAG_Alarm := TRUE;
	
	                2: (* Warning *)
	                    FLAG_Warning := TRUE;
	
	                3: (* Sensor < min *)
	                    FLAG_Warning := TRUE;
	                    warning_detail_str := CONCAT(warning_detail_str,'Sensor below minimum limit; ');
	
	                4: (* Sensor > max *)
	                    FLAG_Warning := TRUE;
	                    warning_detail_str := CONCAT(warning_detail_str,'Sensor above maximum limit; ');
	
	                5: (* Batch counter *)
	                    FLAG_Warning := TRUE;
	                    warning_detail_str := CONCAT(warning_detail_str,'Batch counter limit reached; ');
	
	                6: (* Power-up / deviation *)
	                    FLAG_Warning := TRUE;
	                    warning_detail_str := CONCAT(warning_detail_str,'Power-up alarm; ');
	
	                7: (* Communication *)
	                    FLAG_Alarm := TRUE;
	                    Output_ErrorState := DEV_ERR_COMMUNICATION;
	                8: (* Hardware *)
	                    FLAG_Alarm := TRUE;
	                    Output_ErrorState := DEV_ERR_HARDWARE;

	            END_CASE
	        END_IF
	    END_FOR
	
	    Output_DeviceInstance.warning := FLAG_Warning;
	    Output_DeviceInstance.alarm   := FLAG_Alarm;
	
	END_ACTION
	
	ACTION ACT_Status_wo_text
	
        Output_DeviceInstance.status := Input_status;

        (* Default zurücksetzen *)
        (* Wichtig: nicht alarm/warning global löschen! *)
        
        CASE Input_status OF

            0: (* Normal operation *)
                ;(* nichts setzen *)

            1: (* Maintenance required *)
                Output_DeviceInstance.warning := TRUE;

            2: (* Out of specification *)
                Output_DeviceInstance.warning := TRUE;

            4: (* Check function *)
                Output_DeviceInstance.warning := TRUE;

            8: (* Device failure *)
                Output_DeviceInstance.alarm := TRUE;
                FLAG_Alarm := TRUE;
                Output_ErrorState := DEV_ERR_DEVICE_FAILURE;

            ELSE
                (* unbekannter Status *)
                Output_DeviceInstance.warning := TRUE;

        END_CASE
	
	END_ACTION
	
	ACTION ACT_Name
	
		IF Input_UserTag <> Input_DeviceInstance.name THEN
			Output_UserTag := Input_DeviceInstance.name;;
			Output_DeviceInstance.name := Input_DeviceInstance.name;
		END_IF
	
	END_ACTION
	
	ACTION ACT_Build_StatusMessage

	    Output_DeviceInstance.status_msg := '';
	
	    (* === Priority Prefix === *)
	    IF state = DV_INIT THEN
	        Output_DeviceInstance.status_msg :=
	            CONCAT(notification_lable, 'Initializing device...');
	        RETURN;
	    END_IF
	
	    		    	
    	CASE Output_ErrorState OF
    		
    		DEV_ERR_NONE: err_msg := '';
    		
    		DEV_ERR_INIT: err_msg := 'Initialization timeout';
    		
    		DEV_ERR_SV_ACCEPT_TIMEOUT: err_msg:= 'Set Value not accepted - TIMEOUT';
    		
    		DEV_ERR_AV_Reach_TIMEOUT: err_msg:= 'Actual Value not in tolerance - TIMEOUT';
    		
    		DEV_ERR_AV_Maintain_TIMEOUT: err_msg:= 'Actual Value not maintained - TIMEOUT';
    		
    		DEV_ERR_COMMUNICATION: err_msg := 'Communication error';
    		
    		DEV_ERR_HARDWARE: err_msg := 'Hardware alarm';
    		
    		DEV_ERR_DEVICE_FAILURE: err_msg := 'Device failure';
    
    	END_CASE
		
		IF sv_rejected THEN
			Output_DeviceInstance.warning := TRUE;
			IF warning_detail_str <> '' THEN
				warning_detail_str :=CONCAT(warning_detail_str,', Setpoint rejected - ');
			ELSE
				warning_detail_str := 'Setpoint rejected - ';
			END_IF
			
			IF NOT setpoint_mode_allowed THEN
				warning_detail_str :=CONCAT(warning_detail_str,'no Setpoint allowed.');
			ELSIF cfg_pending THEN
				warning_detail_str :=CONCAT(warning_detail_str,'HW-Config pending.');
			ELSIF sv_outofrange THEN
				warning_detail_str :=CONCAT(warning_detail_str,'Setpoint out of range.');
			END_IF
				
		END_IF
		
	    IF Output_DeviceInstance.alarm THEN
	        prefix := alarm_lable;
	    ELSIF Output_DeviceInstance.warning THEN
	        prefix := warning_lable;
	    ELSE
	        prefix := notification_lable;
	    END_IF
	
	    Output_DeviceInstance.status_msg := prefix;
	
	    (* === ControlFunction / ControlMode === *)
	    Output_DeviceInstance.status_msg :=
	        CONCAT(Output_DeviceInstance.status_msg,'CF=');
	    Output_DeviceInstance.status_msg :=
	        CONCAT(Output_DeviceInstance.status_msg,cf_str);

		Output_DeviceInstance.status_msg :=
	        CONCAT(Output_DeviceInstance.status_msg,', CM=');
	    Output_DeviceInstance.status_msg :=
	        CONCAT(Output_DeviceInstance.status_msg,cm_str);
	
	    (* === Setpoint === *)
	    IF sv_applied THEN
	        Output_DeviceInstance.status_msg :=
		        CONCAT(Output_DeviceInstance.status_msg,', SV=');
		    Output_DeviceInstance.status_msg :=
		        CONCAT(Output_DeviceInstance.status_msg,sv_str);
	    END_IF
	
	    (* === State-dependent text === *)
	    CASE state OF
	        DV_IDLE:
	            msg_str := ' (Idle)';
	        DV_SETTING_REQ:
	            IF sv_accepted THEN
	                msg_str := ' (Setpoint accepted)';
	            ELSE
	                msg_str := ' (Waiting for device to accept setpoint)';
	            END_IF
	        DV_CONTROLLING:
	            msg_str := ' (Controlling)';
	        DV_SETTLED:
	            msg_str := ' (Setpoint reached)';
	        DV_DISABLED:
	            msg_str := ' (Disabled)';
	    ELSE
	        msg_str := '';
	    END_CASE
	    
	    CASE Output_DeviceInstance.status OF
		    0:
		        dev_status_str := 'Normal operation';
		
		    1:
		        dev_status_str := 'Maintenance required';
		
		    2:
		        dev_status_str := 'Out of specification';
		
		    4:
		        dev_status_str := 'Check function';
		
		    8:
		        dev_status_str := 'Device failure';
		
		ELSE
		    dev_status_str := 'Unknown device status';
		END_CASE

	    Output_DeviceInstance.status_msg :=
	        CONCAT(Output_DeviceInstance.status_msg, msg_str);
		
		Output_DeviceInstance.status_msg :=
	        CONCAT(Output_DeviceInstance.status_msg,' | Status: ');
	    Output_DeviceInstance.status_msg :=
	        CONCAT(Output_DeviceInstance.status_msg,dev_status_str);
		
		IF err_msg <> '' THEN
    		Output_DeviceInstance.status_msg := CONCAT(Output_DeviceInstance.status_msg,' | ');
    		Output_DeviceInstance.status_msg := CONCAT(Output_DeviceInstance.status_msg, error_lable);
        	Output_DeviceInstance.status_msg := CONCAT(Output_DeviceInstance.status_msg, err_msg);
	    END_IF
	    
	    IF warning_detail_str <> '' THEN
	    	Output_DeviceInstance.status_msg := CONCAT(Output_DeviceInstance.status_msg,' | ');
	    	Output_DeviceInstance.status_msg := CONCAT(Output_DeviceInstance.status_msg,warning_detail_str);
	    END_IF
	END_ACTION

	ACTION ACT_Reset_BH_Device

		IF Input_DeviceInstance.alarm_reset_enable = 4 THEN
			Output_Reset_to_device := 2; (*reset alarm*)
			msg_str := ': Device reset triggered.';
		    Output_DeviceInstance.status_msg := CONCAT(notification_lable, Input_DeviceInstance.name);
		    Output_DeviceInstance.status_msg := CONCAT(Output_DeviceInstance.status_msg, msg_str);
		    Output_DeviceInstance.reset := FALSE;
		 ELSE
		 	msg_str := ': Device reset NOT available.';
		    Output_DeviceInstance.status_msg := CONCAT(warning_lable, Input_DeviceInstance.name);
		    Output_DeviceInstance.status_msg := CONCAT(Output_DeviceInstance.status_msg, msg_str);
		 END_IF

	END_ACTION
	
(*	ACTION ACT_Serialnumber_identification *)
	
(*		FOR i:= 1 TO 20 DO *)
(*			IF i=1 THEN *)
(*				string_var := ''; *)
(*			END_IF *)
(*			ascii_byte := Input_SN_from_device[i]; *)
(*			string_var := CONCAT(string_var, Util_Chr(ascii_byte)); *)
(*		END_FOR *)

(*	Output_DeviceInstance.serialnumber := string_var; *)
	
(*	Output_DeviceInstance.serialnumber := Input_SN; *)
(*	END_ACTION *)
	
	
	
END_ACTIONS