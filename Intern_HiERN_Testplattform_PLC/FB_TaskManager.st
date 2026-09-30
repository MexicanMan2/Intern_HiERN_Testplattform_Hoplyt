FUNCTION_BLOCK FB_TaskManager
VAR_INPUT
	newOrder : STRING;
	response: BOOL;	(*Response from the serial connection*)
END_VAR

VAR_OUTPUT
	queued: BOOL;
	commandReady: BOOL := FALSE; (* Flag to indicate a command is ready to be sent *)
	currentOrder: STRING;
END_VAR

VAR
	orderQueue: ARRAY[1..100] OF STRING;
	queueHead: INT :=1;
	queueTail: INT :=1;
	orderInProgress: BOOL := FALSE;
(*	lastOrder : STRING := ''; *)
END_VAR

(*	IF lastOrder <> newOrder THEN *)
(*		Act_AddOrder; *)
(*	END_IF *)
	;
END_FUNCTION_BLOCK

ACTIONS
	
	ACTION Act_AddOrder
		IF (queueTail MOD 100) + 1 <> queueHead THEN
			(* IF newOrder <> orderQueue[queueTail-1] THEN (* reject command if already exists *) *)
				orderQueue[queueTail] := newOrder;
				queueTail := (queueTail MOD 100) + 1;
				queued := TRUE;
	(*			lastOrder := newOrder; *)
			(* END_IF *)
		ELSE
			queued := FALSE; (* success: BOOL; *)
		END_IF
	END_ACTION
	
	
	ACTION Act_ProcessOrder
	
		IF NOT orderInProgress AND queueHead <> queueTail THEN
			currentOrder := orderQueue[queueHead];
			queueHead := (queueHead MOD 100) + 1;
			orderInProgress := TRUE;
			commandReady := TRUE; (* Set the flag to indicate the command is ready *)
		END_IF
		
		IF response THEN (*Reset the flags*)
			orderInProgress := FALSE;
			commandReady := FALSE; 
			response := FALSE;
		END_IF
		
	END_ACTION

END_ACTIONS