(********************************************************************************
 * FUNCTION_BLOCK: FB_CAN_Broker
 * 
 * Beschreibung:
 *   Zentraler Hardware-Treiber-Manager für den CAN-Bus an Bachmann M1 (CUL_PLC).
 *   
 *   Aufgaben:
 *     1. Kapselt den Hardware-Zugriff (CardNb, NetNb, Chan, CUL_PLC).
 *     2. Liest in jedem SPS-Zyklus die Hardware-Empfangsqueue vollständig leer
 *        und verteilt empfangene Telegramme an den passenden Kanal.
 *     3. Verwaltet Sendeaufträge über ein faires Round-Robin-Verfahren
 *        (nicht-blockierend über CUL_SendMsg_NB), sodass keine Buskollisionen entstehen.
 ********************************************************************************)
FUNCTION_BLOCK FB_CAN_Broker
VAR_INPUT
    Enable          : BOOL := TRUE;             (* Broker aktivieren *)
    Reset           : BOOL := FALSE;            (* Re-Init auslösen *)
    NetNb           : DINT := 1;                (* CAN NetNumber (Standard: 1) *)
    CardNb          : DINT := 2;                (* CPU Card Number (Card 2) *)
    Chan            : UDINT := 0;               (* CAN-Kanal (0 = CAN A) *)
END_VAR

VAR_IN_OUT
    Channel1        : ST_CAN_Broker_Channel;    (* Kanal für Sensor 1 *)
    Channel2        : ST_CAN_Broker_Channel;    (* Kanal für Sensor 2 *)
    Channel3        : ST_CAN_Broker_Channel;    (* Kanal für Sensor 3 *)
END_VAR

VAR_OUTPUT
    Ready           : BOOL := FALSE;            (* Treiber initialisiert und empfangsbereit *)
    Error           : BOOL := FALSE;            (* Treiberfehler *)
    ErrorID         : DINT := 0;
END_VAR

VAR
    initStep        : INT := 0;
    initDone        : BOOL := FALSE;
    
    (* CUL Instanzen *)
    fbAttachEvent   : CUL_AttachEvent;
    fbSendMsg       : CUL_SendMsg_NB;
    fbRecvMsg       : CUL_ReceiveMsg;
    
    dwEventFlags    : UDINT := 0;
    nRet            : DINT := 0;
    
    (* Dynamische Rx-ID-Registrierung *)
    lastEnabledRx1  : UDINT := 0;
    lastEnabledRx2  : UDINT := 0;
    lastEnabledRx3  : UDINT := 0;
    
    (* Sende-Verwaltung *)
    txActive        : BOOL := FALSE;
    activeChan      : INT := 0;                 (* 1, 2 oder 3 *)
    lastServedChan  : INT := 1;
    currTxCobId     : UDINT := 0;
    currTxData      : ARRAY [0..7] OF BYTE;
    
    (* Hilfsvariablen *)
    i               : INT;
    candChan        : INT;
    rxCount         : INT;
END_VAR

(* ============================================================================ *)
(* Deaktivierung & Reset                                                       *)
(* ============================================================================ *)
IF NOT Enable THEN
    IF initDone THEN
        Cul_DetachEvent(NetNb := NetNb, Event := 0);
    END_IF;
    Ready    := FALSE;
    initDone := FALSE;
    initStep := 0;
    txActive := FALSE;
    RETURN;
END_IF;

IF Reset THEN
    IF initDone THEN
        Cul_DetachEvent(NetNb := NetNb, Event := 0);
    END_IF;
    Ready          := FALSE;
    Error          := FALSE;
    ErrorID        := 0;
    initDone       := FALSE;
    initStep       := 0;
    txActive       := FALSE;
    lastEnabledRx1 := 0;
    lastEnabledRx2 := 0;
    lastEnabledRx3 := 0;
END_IF;

(* ============================================================================ *)
(* Initialisierung der Hardware (Schritt 0)                                     *)
(* ============================================================================ *)
IF NOT initDone THEN
    CASE initStep OF
        0:
            (* Alle 3 Antwort-IDs freischalten *)
            IF Channel1.RxCobId > 0 AND Channel1.RxCobId <> lastEnabledRx1 THEN
                nRet := Cul_EnableMsg(CardNb := CardNb, Chan := Chan, CobId := Channel1.RxCobId);
                lastEnabledRx1 := Channel1.RxCobId;
            END_IF;
            IF Channel2.RxCobId > 0 AND Channel2.RxCobId <> lastEnabledRx2 THEN
                nRet := Cul_EnableMsg(CardNb := CardNb, Chan := Chan, CobId := Channel2.RxCobId);
                lastEnabledRx2 := Channel2.RxCobId;
            END_IF;
            IF Channel3.RxCobId > 0 AND Channel3.RxCobId <> lastEnabledRx3 THEN
                nRet := Cul_EnableMsg(CardNb := CardNb, Chan := Chan, CobId := Channel3.RxCobId);
                lastEnabledRx3 := Channel3.RxCobId;
            END_IF;
            
            dwEventFlags := 0;
            fbAttachEvent(Req := TRUE, NetNb := NetNb, Event := dwEventFlags);
            
            IF fbAttachEvent.Done THEN
                fbAttachEvent(Req := FALSE, NetNb := NetNb, Event := dwEventFlags);
                initDone := TRUE;
                Ready    := TRUE;
                Error    := FALSE;
                ErrorID  := 0;
            ELSIF fbAttachEvent.Error THEN
                Error    := TRUE;
                ErrorID  := fbAttachEvent.Status;
            END_IF;
    END_CASE;
    RETURN;
END_IF;

(* Nachträglich konfigurierte oder geänderte RxCobIds beim CAN-Controller freischalten *)
IF Channel1.RxCobId > 0 AND Channel1.RxCobId <> lastEnabledRx1 THEN
    nRet := Cul_EnableMsg(CardNb := CardNb, Chan := Chan, CobId := Channel1.RxCobId);
    lastEnabledRx1 := Channel1.RxCobId;
END_IF;
IF Channel2.RxCobId > 0 AND Channel2.RxCobId <> lastEnabledRx2 THEN
    nRet := Cul_EnableMsg(CardNb := CardNb, Chan := Chan, CobId := Channel2.RxCobId);
    lastEnabledRx2 := Channel2.RxCobId;
END_IF;
IF Channel3.RxCobId > 0 AND Channel3.RxCobId <> lastEnabledRx3 THEN
    nRet := Cul_EnableMsg(CardNb := CardNb, Chan := Chan, CobId := Channel3.RxCobId);
    lastEnabledRx3 := Channel3.RxCobId;
END_IF;

(* ============================================================================ *)
(* Zyklus-Start: Flanken / Trigger der Kanäle zurücksetzen                      *)
(* ============================================================================ *)
Channel1.RxNew  := FALSE;
Channel1.TxDone := FALSE;
Channel1.TxError:= FALSE;

Channel2.RxNew  := FALSE;
Channel2.TxDone := FALSE;
Channel2.TxError:= FALSE;

Channel3.RxNew  := FALSE;
Channel3.TxDone := FALSE;
Channel3.TxError:= FALSE;

(* ============================================================================ *)
(* 1. EMPFANG: Hardware-Queue vollständig auslesen & an Kanäle verteilen        *)
(* ============================================================================ *)
rxCount := 0;
REPEAT
    fbRecvMsg(NetNb := NetNb);
    rxCount := rxCount + 1;
    
    IF fbRecvMsg.Status = 0 AND fbRecvMsg.Msg_Length >= 7 THEN
        IF fbRecvMsg.CobId = Channel1.RxCobId THEN
            Channel1.RxNew  := TRUE;
            Channel1.RxData := fbRecvMsg.Msg_Data;
            Channel1.RxLen  := fbRecvMsg.Msg_Length;
        ELSIF fbRecvMsg.CobId = Channel2.RxCobId THEN
            Channel2.RxNew  := TRUE;
            Channel2.RxData := fbRecvMsg.Msg_Data;
            Channel2.RxLen  := fbRecvMsg.Msg_Length;
        ELSIF fbRecvMsg.CobId = Channel3.RxCobId THEN
            Channel3.RxNew  := TRUE;
            Channel3.RxData := fbRecvMsg.Msg_Data;
            Channel3.RxLen  := fbRecvMsg.Msg_Length;
        END_IF;
    END_IF;
UNTIL (fbRecvMsg.Status <> 0) OR (fbRecvMsg.Msg_Left = 0) OR (rxCount > 30)
END_REPEAT;

(* ============================================================================ *)
(* 2. SENDEN: Laufende Übertragung überwachen oder neuen Auftrag starten        *)
(* ============================================================================ *)
IF txActive THEN
    (* Laufenden Sendevorgang pollen *)
    fbSendMsg(
        Req        := TRUE,
        NetNb      := NetNb,
        CobId      := currTxCobId,
        Msg_Data   := currTxData,
        Msg_Length := 8
    );
    
    IF fbSendMsg.Done THEN
        fbSendMsg(Req := FALSE, NetNb := NetNb, CobId := currTxCobId, Msg_Data := currTxData, Msg_Length := 8);
        txActive := FALSE;
        CASE activeChan OF
            1: Channel1.TxDone := TRUE; Channel1.TxBusy := FALSE; Channel1.TxReq := FALSE;
            2: Channel2.TxDone := TRUE; Channel2.TxBusy := FALSE; Channel2.TxReq := FALSE;
            3: Channel3.TxDone := TRUE; Channel3.TxBusy := FALSE; Channel3.TxReq := FALSE;
        END_CASE;
    ELSIF fbSendMsg.Error THEN
        fbSendMsg(Req := FALSE, NetNb := NetNb, CobId := currTxCobId, Msg_Data := currTxData, Msg_Length := 8);
        txActive := FALSE;
        CASE activeChan OF
            1: Channel1.TxError := TRUE; Channel1.TxBusy := FALSE; Channel1.TxReq := FALSE;
            2: Channel2.TxError := TRUE; Channel2.TxBusy := FALSE; Channel2.TxReq := FALSE;
            3: Channel3.TxError := TRUE; Channel3.TxBusy := FALSE; Channel3.TxReq := FALSE;
        END_CASE;
    END_IF;

ELSE
    (* Kein Sendevorgang aktiv: Nächsten Sendeauftrag per Round-Robin auswählen *)
    FOR i := 1 TO 3 DO
        candChan := ((lastServedChan - 1 + i) MOD 3) + 1;
        
        IF candChan = 1 AND Channel1.TxReq THEN
            activeChan      := 1;
            lastServedChan  := 1;
            currTxCobId     := Channel1.TxCobId;
            currTxData      := Channel1.TxData;
            Channel1.TxBusy := TRUE;
            txActive        := TRUE;
            EXIT;
        ELSIF candChan = 2 AND Channel2.TxReq THEN
            activeChan      := 2;
            lastServedChan  := 2;
            currTxCobId     := Channel2.TxCobId;
            currTxData      := Channel2.TxData;
            Channel2.TxBusy := TRUE;
            txActive        := TRUE;
            EXIT;
        ELSIF candChan = 3 AND Channel3.TxReq THEN
            activeChan      := 3;
            lastServedChan  := 3;
            currTxCobId     := Channel3.TxCobId;
            currTxData      := Channel3.TxData;
            Channel3.TxBusy := TRUE;
            txActive        := TRUE;
            EXIT;
        END_IF;
    END_FOR;
    
    IF txActive THEN
        fbSendMsg(
            Req        := TRUE,
            NetNb      := NetNb,
            CobId      := currTxCobId,
            Msg_Data   := currTxData,
            Msg_Length := 8
        );
    END_IF;
END_IF;

END_FUNCTION_BLOCK
