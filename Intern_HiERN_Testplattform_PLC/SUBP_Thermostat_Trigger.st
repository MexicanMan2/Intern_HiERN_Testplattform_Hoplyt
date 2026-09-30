PROGRAM SUBP_Thermostat_Trigger
VAR

	
	(* Task Manager for Serial Orders *)
	COM_taskManager     : FB_TaskManager;
	LastCommandSent     : STRING;
	LastRevievedMessage : STRING;
	
	(* Bachmann Serial Driver Instances *)
	COM 	        : FILE_OpenSerial; (* Bachmann FILE_OpenSerial *)
	ParmMask	    : WORD;
	COM_STATISTIC	: FILE_SIOSTATISTIC;
	is_init_COM     : BOOL := FALSE;
	retries         : INT := 0;
	
	is_ADR          : BOOL := FALSE;
	COM_Read	    : FILE_Read;
	rx_bytes        : ARRAY[0..255] OF BYTE;
	RX_ADD		    : DWORD; (* Memory address for RX buffer *)
	COM_Write	    : FILE_Write;
	TX_ADD		    : DWORD; (* Memory address for TX buffer *)
	
	(* Send & Receive Strings *)
	RX_STRING	     : STRING := '';
	is_RX_STRING_New : BOOL;
	COM_ReadLength   : DINT;
	TX_STRING	     : STRING := '';
	is_TX_STRING_New : BOOL;
	CR	             : STRING;
	LF	             : STRING;
	CRLF             : STRING;
	AKKU	         : STRING;
	OLD_STRING       : STRING;
	
	hist_commands : ARRAY[1..10] OF STRING;
	hist_answer   : ARRAY[1..10] OF STRING;
	commandID     : INT := 1;
	responseID    : INT := 1;
	
	(* Process Timing & Execution *)
	ProzessTakt : TON;
	TaktZeit    : TIME := T#250ms;
	
	(* Startup & Connection Delay *)
	Init_StartUpConnection : BOOL := TRUE;
	Init_ConnectionDelay   : TON;
	ConnectionDelay_Time   : TIME := T#3s;
	
	(* Device Initialization Timers *)
	Init_Timer   : TON;
	Init_Time    : TIME := T#1s;
	Init_Timeout : TON;
	Init_MaxTime : TIME := T#15s;
	
	(* Watchdog Timer *)
	Watchdog_Timer : TON;
	Watchdog_Time  : TIME := T#15s;
	watchdog_reset : BOOL := FALSE;
	
	(* Cyclic Polling Timer *)
	Poll_Timer : TON;
	Poll_Time  : TIME := T#1s;
	
	(* State Machine Variables *)
	state_next : state_device := DV_INIT;
	state_prev : state_device := DV_INIT;
	StateEntry : BOOL := TRUE;
	
	(* Internal Helpers for LAI-Hex Protocol Formatting & Parsing *)
	mode_char   : STRING;
	alarm_char  : STRING;
	hex_sp      : STRING;
	cmd_body    : STRING;
	full_cmd    : STRING;
	
	sp_hex      : STRING;
	ti_hex      : STRING;
	te_hex      : STRING;
	temp_real   : REAL;
	
	is_valid_LAI_response : BOOL := FALSE;
	
	i_loop          : DINT;
	byte_ord        : INT;
	nibble_val      : DINT;
	temp_hundredths : DINT;
	w_val           : DINT;
	n1, n2, n3, n4  : INT;
	n_high, n_low   : INT;
	c1, c2, c3, c4  : STRING;
	
	(* Parameters for Local Actions *)
	chk_in_str    : STRING;
	chk_out_str   : STRING;
	real_in_val   : REAL;
	hex16_out_str : STRING;
	hex16_in_str  : STRING;
	real_out_val  : REAL;
	manual_mode   : BOOL := TRUE; (* Defaults to TRUE so manual testing is active on startup *)
	
END_VAR

(* Reset 1-cycle response flag at top of every cycle *)
is_valid_LAI_response := FALSE;

(* Automatic connection attempt on startup *)
IF Init_StartUpConnection THEN
	Init_ConnectionDelay.IN := TRUE;
	Init_ConnectionDelay.PT := ConnectionDelay_Time;
END_IF

Init_ConnectionDelay;

IF Init_ConnectionDelay.Q THEN
	Init_StartUpConnection := FALSE;
	Init_ConnectionDelay.IN := FALSE;
	ACT_CONNECT_AND_RETRY;
END_IF

ACT_DEBUG_Processes;

manual_mode := ser_debug.manual_mode;

IF is_init_COM OR ser_debug.receive THEN
	
	IF manual_mode THEN
		(* In manual mode: run transmission & reception directly, freeze everything else *)
		ACT_Handle_Data_Transmission;
	ELSE
		(* In automatic mode: run TaskManager and State Machine *)
		COM_taskManager.Act_ProcessOrder();
		
		ProzessTakt(IN := TRUE, PT := TaktZeit);
		IF ProzessTakt.Q THEN
			ACT_Handle_Data_Transmission;
			ProzessTakt(IN := FALSE);
		END_IF
		
		(* Device State Machine Execution *)
		ACT_Device_StateMachine;
		
		(* Cyclic polling of temperatures & status via LAI "G" command *)
		ACT_CyclicPolling;
		
		(* Connection Watchdog monitoring *)
		ACT_Watchdog_Check;
	END_IF
	
END_IF

END_PROGRAM

ACTIONS

	ACTION ACT_DefineStringAdresses
		IF NOT is_ADR THEN
			RX_ADD := ADR(RX_STRING);
			TX_ADD := ADR(TX_STRING);
			is_ADR := TRUE;
		END_IF
	END_ACTION
	
	ACTION ACT_Define_CR_LF
		LF := Util_Chr(BYTE#10);
		CR := Util_Chr(BYTE#13);
		CRLF := CONCAT(CR, LF);
		AKKU := '';
	END_ACTION
	
	ACTION ACT_DEBUG_Processes
		IF ser_debug.req_connect THEN
			ACT_CONNECT_AND_RETRY;
		END_IF
		
		IF ser_debug.req_disconnect THEN
			ser_debug.req_connect := FALSE;
			ACT_DISCONNECT;
		END_IF
		
		(* Hardware statistics *)
		IF is_init_COM THEN
			COM_STATISTIC := File_GetSioStatistic(FileId := COM.FileId);
			ser_debug.tx_bytes := COM_STATISTIC.TxCount;
			ser_debug.rx_bytes := COM_STATISTIC.RxCount;
			ser_debug.frame_errors := COM_STATISTIC.FrameErrors;
			ser_debug.overrun_errors := COM_STATISTIC.ORunErrrors;
			ser_debug.parity_errors := COM_STATISTIC.ParityErrors;
		END_IF
	END_ACTION
	
	ACTION ACT_CONNECT_AND_RETRY
		IF NOT is_init_COM THEN
			ACT_CONNECT;
			retries := 0;
		ELSIF COM.Error AND retries < 5 THEN
			ACT_DISCONNECT;
			ACT_CONNECT;
			retries := retries + 1;
		END_IF
	END_ACTION
	
	ACTION ACT_CONNECT
		ACT_DefineStringAdresses;
		ACT_Define_CR_LF;
		
		ParmMask := File_PARM_BaudRate OR File_PARM_RdBufSize OR File_PARM_WrBufSize;

		COM(Req := TRUE,
			Cmd := File_CMD_Open,
			AccessMode := File_ACCESS_RdWr,
			OpMode := File_OPMODE_Direct,
			ParmMask := ParmMask,
			BaudRate := thermostat_1.baud_rate,
			RdBufSize := 1024,
			WrBufSize := 1024,
			CardNb := thermostat_1.card_nb,
			ChanNb := thermostat_1.chan_nb );
		
		IF COM.Error THEN
			thermostat_1.com_status := CONCAT('Connection Error. Code: ', DINT_TO_STRING(COM.Status));
			thermostat_1.com_ready := FALSE;
			state_next := DV_ERROR;
		ELSIF COM.Done THEN
			is_init_COM := TRUE;
			thermostat_1.com_status := 'connected';
			thermostat_1.com_ready := FALSE;
			thermostat_1.watchdog_error := FALSE;
			thermostat_1.device_alarm := FALSE;
			watchdog_reset := FALSE;
			Watchdog_Timer(IN := FALSE);
			Init_Timeout(IN := FALSE);
			ser_debug.req_connect := FALSE;
			state_next := DV_INIT;
		END_IF
	END_ACTION
	
	ACTION ACT_DISCONNECT
		COM(Req := TRUE,
			Cmd := File_CMD_Close,
			AccessMode := File_ACCESS_RdWr,
			OpMode := File_OPMODE_Direct,
			ParmMask := ParmMask,
			BaudRate := thermostat_1.baud_rate,
			RdBufSize := 1024,
			WrBufSize := 1024,
			CardNb := thermostat_1.card_nb,
			ChanNb := thermostat_1.chan_nb );
						
		ser_debug.req_disconnect := FALSE;
		is_init_COM := FALSE;
		watchdog_reset := FALSE;
		Watchdog_Timer(IN := FALSE);
		Init_Timeout(IN := FALSE);
		
		thermostat_1.com_status := 'disconnected';
		thermostat_1.com_ready := FALSE;
		state_next := DV_DISABLED;
	END_ACTION
	
	ACTION ACT_Handle_Data_Transmission
		(* 1. Write to Serial *)
		IF manual_mode THEN
			(* MANUAL MODE: Only send when user sets ser_debug.sent := TRUE *)
			IF ser_debug.sent THEN
				TX_STRING := ser_debug.test_message;
				LastCommandSent := TX_STRING;
				hist_commands[commandID] := LastCommandSent;
				commandID := (commandID MOD 10) + 1;
				
				TX_STRING := CONCAT(TX_STRING, CR);
				OLD_STRING := TX_STRING;
				
				COM_Write.Addr := TX_ADD;
				COM_Write.Length := LEN(TX_STRING);
				COM_Write(Req := TRUE, FileId := COM.FileId);
				
				IF (COM_Write.Status = 0) THEN
					COM_Write(Req := FALSE, FileId := COM.FileId);
					TX_STRING := '';
					ser_debug.sent := FALSE; (* Reset sent flag: exactly ONE message is sent *)
				END_IF
			ELSE
				TX_STRING := '';
				COM_Write(Req := FALSE, FileId := COM.FileId);
			END_IF
			ser_debug.ser_w_status := COM_Write.Status;
		ELSE
			(* AUTOMATIC MODE: Process orders from TaskManager *)
			IF COM_taskManager.commandReady AND TX_STRING = '' THEN
				is_TX_STRING_New := TRUE;
				TX_STRING := COM_taskManager.currentOrder;
			END_IF
			
			IF TX_STRING <> '' THEN
				IF is_TX_STRING_New THEN
					LastCommandSent := TX_STRING;
					ser_debug.test_message := LastCommandSent;
					hist_commands[commandID] := LastCommandSent;
					commandID := (commandID MOD 10) + 1;
					TX_STRING := CONCAT(TX_STRING, CR);
					OLD_STRING := TX_STRING;
				END_IF
				
				COM_Write.Addr := TX_ADD;
				COM_Write.Length := LEN(TX_STRING);
				COM_Write(Req := TRUE, FileId := COM.FileId);
				ser_debug.ser_w_status := COM_Write.Status;
				
				IF (COM_Write.Status = 0) THEN
					COM_Write(Req := FALSE, FileId := COM.FileId);
					TX_STRING := '';
					COM_taskManager.response := TRUE;
				ELSE
					is_TX_STRING_New := FALSE;
				END_IF
			END_IF
		END_IF
		
		(* 2. Read from Serial - exact GC logic with immediate CR extraction *)
		COM_ReadLength := File_GetNumOfUnread(FileId := COM.FileId);
		ser_debug.read_len := COM_ReadLength;
		ser_debug.n_read := COM_Read.NRead;
		ser_debug.ser_r_status := COM_Read.Status;
		
		IF COM_ReadLength > 0 THEN
			COM_Read.Req := TRUE;
		ELSIF COM_Read.Ndr = TRUE AND COM_Read.Status = 0 THEN
			COM_Read.Req := FALSE;
			is_RX_STRING_New := TRUE;
		END_IF

		IF COM_Read.Status <> 1 AND COM_Read.Status <> 2 THEN
		    COM_Read(FileId := COM.FileId,
		              Addr := RX_ADD, Length := DINT_TO_UINT(File_GetNumOfUnread(FileId := COM.FileId)));

			    IF RX_STRING <> '' THEN
			        RX_STRING := LEFT(RX_STRING, COM_Read.NRead);
			        AKKU := CONCAT(AKKU, RX_STRING);
			        RX_STRING := '';
			    END_IF
		END_IF
		
		
		IF (is_RX_STRING_New OR FIND(AKKU, CR) > 0) AND AKKU <> '' THEN
			LastRevievedMessage := '';
			LastRevievedMessage := AKKU;
			AKKU := '';
			is_RX_STRING_New := FALSE;
			IF LastRevievedMessage <> '' THEN
				LastRevievedMessage := TrimCRLF(LastRevievedMessage);
				ser_debug.received_message := LastRevievedMessage;
				ser_debug.receive := TRUE;
				hist_answer[responseID] := LastRevievedMessage;
				responseID := (responseID MOD 10) + 1;
				
				(* Parse LAI-Hex Response *)
				ACT_Parse_LAI_Response;
			END_IF
		END_IF
	END_ACTION
	
	ACTION ACT_CalcChksum
		w_val := 0;
		FOR i_loop := 1 TO LEN(chk_in_str) DO
			w_val := w_val + BYTE_TO_INT(Util_Ord(Str := chk_in_str, Index := i_loop));
		END_FOR
		w_val := w_val MOD 256;
		n_high := DINT_TO_INT(w_val / 16);
		n_low := DINT_TO_INT(w_val MOD 16);
		chk_out_str := CONCAT(MID('0123456789ABCDEF', 1, n_high + 1), MID('0123456789ABCDEF', 1, n_low + 1));
	END_ACTION
	
	ACTION ACT_RealToHex16
		temp_hundredths := REAL_TO_DINT(real_in_val * 100.0);
		IF temp_hundredths < 0 THEN
			w_val := 65536 + temp_hundredths;
		ELSE
			w_val := temp_hundredths;
		END_IF

		n1 := DINT_TO_INT((w_val / 4096) MOD 16);
		n2 := DINT_TO_INT((w_val / 256) MOD 16);
		n3 := DINT_TO_INT((w_val / 16) MOD 16);
		n4 := DINT_TO_INT(w_val MOD 16);

		c1 := MID('0123456789ABCDEF', 1, n1 + 1);
		c2 := MID('0123456789ABCDEF', 1, n2 + 1);
		c3 := MID('0123456789ABCDEF', 1, n3 + 1);
		c4 := MID('0123456789ABCDEF', 1, n4 + 1);

		hex16_out_str := CONCAT(c3, c4);
		hex16_out_str := CONCAT(c2, hex16_out_str);
		hex16_out_str := CONCAT(c1, hex16_out_str);
	END_ACTION
	
	ACTION ACT_Hex16ToReal
		w_val := 0;
		FOR i_loop := 1 TO 4 DO
			byte_ord := BYTE_TO_INT(Util_Ord(Str := hex16_in_str, Index := i_loop));
			IF byte_ord >= 48 AND byte_ord <= 57 THEN
				nibble_val := byte_ord - 48;
			ELSIF byte_ord >= 65 AND byte_ord <= 70 THEN
				nibble_val := byte_ord - 55;
			ELSIF byte_ord >= 97 AND byte_ord <= 102 THEN
				nibble_val := byte_ord - 87;
			ELSE
				nibble_val := 0;
			END_IF
			w_val := (w_val * 16) + nibble_val;
		END_FOR

		IF w_val >= 32768 THEN
			w_val := w_val - 65536;
		END_IF

		real_out_val := DINT_TO_REAL(w_val) / 100.0;
	END_ACTION
	
	ACTION ACT_Parse_LAI_Response
		is_valid_LAI_response := FALSE;
		
		IF LEN(LastRevievedMessage) >= 23 AND LEFT(LastRevievedMessage, 7) = '[S01G15' THEN
			chk_in_str := LEFT(LastRevievedMessage, 21);
			ACT_CalcChksum;
			
			IF chk_out_str = MID(LastRevievedMessage, 2, 22) THEN
				is_valid_LAI_response := TRUE;
				watchdog_reset := TRUE;
				
				mode_char := MID(LastRevievedMessage, 1, 8);
				IF mode_char = 'C' OR mode_char = 'I' THEN
					thermostat_1.control_active := TRUE;
				ELSE
					thermostat_1.control_active := FALSE;
				END_IF
				
				alarm_char := MID(LastRevievedMessage, 1, 9);
				IF alarm_char = '1' THEN
					thermostat_1.device_alarm := TRUE;
				ELSE
					thermostat_1.device_alarm := FALSE;
				END_IF
				
				hex16_in_str := MID(LastRevievedMessage, 4, 10);
				ACT_Hex16ToReal;
				thermostat_1.act_setpoint := real_out_val;
				
				hex16_in_str := MID(LastRevievedMessage, 4, 14);
				ACT_Hex16ToReal;
				thermostat_1.temp_internal := real_out_val;
				
				hex16_in_str := MID(LastRevievedMessage, 4, 18);
				ACT_Hex16ToReal;
				temp_real := real_out_val;
				thermostat_1.temp_external := temp_real;
				
				IF temp_real <= -150.0 THEN
					thermostat_1.sensor_ext_connected := FALSE;
				ELSE
					thermostat_1.sensor_ext_connected := TRUE;
				END_IF
			END_IF
		END_IF
	END_ACTION
	
	ACTION ACT_Device_StateMachine
		state_prev := thermostat_1.state;
		thermostat_1.state := state_next;
		StateEntry := (thermostat_1.state <> state_prev);

		CASE thermostat_1.state OF
			
			DV_INIT:
				thermostat_1.com_status := 'initializing (LAI-Hex)';
				thermostat_1.com_ready := FALSE;
				thermostat_1.SVaccepted := FALSE;
				thermostat_1.SVreached := FALSE;
				
				IF is_init_COM THEN
					Init_Timeout(IN := NOT ser_debug.manual_mode, PT := Init_MaxTime);
					Init_Timer(IN := TRUE, PT := Init_Time);
					
					IF NOT ser_debug.manual_mode AND (StateEntry OR Init_Timer.Q) THEN
						Init_Timer(IN := FALSE);
						cmd_body := '[M01G0D******';
						chk_in_str := cmd_body;
						ACT_CalcChksum;
						full_cmd := CONCAT(cmd_body, chk_out_str);
						COM_taskManager.newOrder := full_cmd;
						COM_taskManager.Act_AddOrder();
					END_IF
					
					IF is_valid_LAI_response THEN
						Init_Timeout(IN := FALSE);
						IF thermostat_1.enable THEN
							thermostat_1.com_status := 'ready';
							thermostat_1.com_ready := TRUE;
							state_next := DV_IDLE;
						ELSE
							thermostat_1.com_status := 'disabled';
							thermostat_1.com_ready := FALSE;
							state_next := DV_DISABLED;
						END_IF
					ELSIF Init_Timeout.Q THEN
						Init_Timeout(IN := FALSE);
						thermostat_1.com_status := 'ERROR: Thermostat initialization timeout';
						thermostat_1.com_ready := FALSE;
						state_next := DV_ERROR;
					END_IF
				END_IF

			DV_DISABLED:
				thermostat_1.com_status := 'disabled';
				thermostat_1.com_ready := FALSE;
				thermostat_1.SVaccepted := FALSE;
				thermostat_1.SVreached := FALSE;
				
				IF thermostat_1.enable THEN
					state_next := DV_IDLE;
				END_IF

			DV_IDLE:
				thermostat_1.com_status := 'idle / ready';
				thermostat_1.com_ready := TRUE;
				
				IF thermostat_1.set_setpoint OR thermostat_1.start OR thermostat_1.stop THEN
					state_next := DV_SETTING_REQ;
				ELSIF thermostat_1.control_active THEN
					state_next := DV_CONTROLLING;
				END_IF

			DV_SETTING_REQ:
				thermostat_1.com_status := 'setting request in progress';
				
				IF NOT ser_debug.manual_mode AND StateEntry THEN
					thermostat_1.SVaccepted := FALSE;
					thermostat_1.SVreached := FALSE;
					
					mode_char := '*';
					IF thermostat_1.start THEN
						mode_char := 'C';
						thermostat_1.start := FALSE;
					ELSIF thermostat_1.stop THEN
						mode_char := 'O';
						thermostat_1.stop := FALSE;
					END_IF
					
					hex_sp := '****';
					IF thermostat_1.set_setpoint THEN
						real_in_val := thermostat_1.target_setpoint;
						ACT_RealToHex16;
						hex_sp := hex16_out_str;
						thermostat_1.set_setpoint := FALSE;
					END_IF
					
					cmd_body := CONCAT('*', hex_sp);
					cmd_body := CONCAT(mode_char, cmd_body);
					cmd_body := CONCAT('[M01G0D', cmd_body);
					
					chk_in_str := cmd_body;
					ACT_CalcChksum;
					full_cmd := CONCAT(cmd_body, chk_out_str);
					
					COM_taskManager.newOrder := full_cmd;
					COM_taskManager.Act_AddOrder();
				END_IF
				
				IF is_valid_LAI_response THEN
					thermostat_1.SVaccepted := TRUE;
					IF thermostat_1.control_active THEN
						state_next := DV_CONTROLLING;
					ELSE
						state_next := DV_IDLE;
					END_IF
				END_IF

			DV_CONTROLLING:
				thermostat_1.com_status := 'controlling active';
				
				IF thermostat_1.set_setpoint OR thermostat_1.start OR thermostat_1.stop THEN
					state_next := DV_SETTING_REQ;
				ELSIF NOT thermostat_1.control_active THEN
					state_next := DV_IDLE;
				ELSE
					IF ABS(thermostat_1.temp_internal - thermostat_1.act_setpoint) <= thermostat_1.SV_tolerance THEN
						thermostat_1.SVreached := TRUE;
						state_next := DV_SETTLED;
					ELSE
						thermostat_1.SVreached := FALSE;
					END_IF
				END_IF

			DV_SETTLED:
				thermostat_1.com_status := 'settled (setpoint reached)';
				thermostat_1.SVreached := TRUE;
				
				IF thermostat_1.set_setpoint OR thermostat_1.start OR thermostat_1.stop THEN
					state_next := DV_SETTING_REQ;
				ELSIF NOT thermostat_1.control_active THEN
					state_next := DV_IDLE;
				ELSIF ABS(thermostat_1.temp_internal - thermostat_1.act_setpoint) > (thermostat_1.SV_tolerance * 1.5) THEN
					thermostat_1.SVreached := FALSE;
					state_next := DV_CONTROLLING;
				END_IF

			DV_ERROR:
				thermostat_1.com_ready := FALSE;
				thermostat_1.SVaccepted := FALSE;
				thermostat_1.SVreached := FALSE;
				
				IF thermostat_1.reset THEN
					thermostat_1.reset := FALSE;
					thermostat_1.watchdog_error := FALSE;
					thermostat_1.device_alarm := FALSE;
					thermostat_1.com_status := 'error reset, re-initializing';
					Init_Timeout(IN := FALSE);
					state_next := DV_INIT;
				END_IF

		END_CASE

		(* GLOBAL STATE TRANSITIONS *)
		IF thermostat_1.watchdog_error OR thermostat_1.device_alarm THEN
			state_next := DV_ERROR;
		ELSIF NOT thermostat_1.enable AND thermostat_1.state <> DV_INIT AND thermostat_1.state <> DV_ERROR THEN
			state_next := DV_DISABLED;
		END_IF
	END_ACTION

	ACTION ACT_CyclicPolling
		IF NOT ser_debug.manual_mode AND thermostat_1.enable AND thermostat_1.com_ready AND NOT COM_taskManager.commandReady THEN
			Poll_Timer(IN := TRUE, PT := Poll_Time);
			
			IF Poll_Timer.Q THEN
				Poll_Timer(IN := FALSE);
				cmd_body := '[M01G0D******';
				chk_in_str := cmd_body;
				ACT_CalcChksum;
				full_cmd := CONCAT(cmd_body, chk_out_str);
				COM_taskManager.newOrder := full_cmd;
				COM_taskManager.Act_AddOrder();
			END_IF
		END_IF
	END_ACTION

	ACTION ACT_Watchdog_Check
		IF is_init_COM AND thermostat_1.com_ready THEN
			Watchdog_Timer(IN := NOT watchdog_reset, PT := Watchdog_Time);
			
			IF Watchdog_Timer.Q THEN
				thermostat_1.watchdog_error := TRUE;
				thermostat_1.com_ready := FALSE;
				thermostat_1.com_status := 'ERROR: Watchdog Timeout - No LAI response from Huber Thermostat';
				watchdog_reset := FALSE;
				Watchdog_Timer(IN := FALSE);
				ACT_DISCONNECT;
			END_IF
			
			watchdog_reset := FALSE;
		END_IF
	END_ACTION

END_ACTIONS
