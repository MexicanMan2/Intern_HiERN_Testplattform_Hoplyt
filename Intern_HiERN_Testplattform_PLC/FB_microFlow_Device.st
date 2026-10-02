(********************************************************************************
 * FUNCTION_BLOCK: FB_microFlow_Device
 * 
 * Beschreibung:
 *   Modularer, gerätespezifischer Treiberbaustein für einen einzelnen 
 *   microFlow Gas-Sensor (Wi.Tec).
 *
 *   Highlights:
 *     1. Auto-Discovery beim Initialisieren:
 *        Liest Seriennummer, Firmware, Gastyp (z.B. CO, CO2), Messbereich (z.B. 50.0)
 *        und Einheit (ppm / Vol.%) vollautomatisch aus dem Sensor aus!
 *     2. Volle Zustandsmaschine (State Machine) nach Industriestandard.
 *     3. Automatische Übernahme und Klartext-Meldung von Gerätefehlern
 *        (z.B. IR-Signalpegel < 50%, Strahler fehlt, UV-Pegelfehler, Timeout).
 *     4. Trennung von Treiber und Logik: Kommuniziert über ST_CAN_Broker_Channel.
 ********************************************************************************)
FUNCTION_BLOCK FB_microFlow_Device
VAR_INPUT
    Enable              : BOOL := TRUE;         (* Sensor-Baustein aktivieren *)
    Reset               : BOOL := FALSE;        (* Fehler-Quittierung / Re-Init *)
    
    (* Adressierung *)
    Tx_CobId            : UDINT := 16#300;      (* Sende-ID an diesen Sensor *)
    Rx_CobId            : UDINT := 16#208;      (* Empfangs-ID von diesem Sensor *)
    
    (* Abtastraten *)
    PollInterval_Conc   : TIME := T#100ms;      (* Schnelle Abtastung Konzentration (z.B. 100ms = 10Hz) *)
    PollInterval_Temp   : TIME := T#5s;         (* Langsame Abtastung Temperatur (alle 5 Sekunden) *)
    TimeoutTime         : TIME := T#150ms;      (* Wartezeit auf Antwort *)
    ReadCH2             : BOOL := FALSE;        (* Kanal 2 ebenfalls abfragen *)
    
    (* Steuerbefehle *)
    Cmd_ZeroCalibration : BOOL := FALSE;        (* Flanke startet Nullpunkt-Kalibrierung (Cmd 16#11) *)
    Cmd_ResetDevice     : BOOL := FALSE;        (* Flanke startet Software-Reset des Sensors (Cmd 16#04) *)
END_VAR

VAR_IN_OUT
    Bus                 : ST_CAN_Broker_Channel; (* Verbindung zum zentralen CAN-Broker *)
END_VAR

VAR_OUTPUT
    Data                : ST_microFlow_Data;    (* Sämtliche Messwerte, Gerätedaten und Fehler *)
END_VAR

VAR
    (* Zustandssteuerung *)
    eState              : E_microFlow_State := MF_STATE_DISABLED;
    subStep             : INT := 0;             (* 0=Send, 1=Wait *)
    queryCH2Active      : BOOL := FALSE;
    timeoutCounter      : INT := 0;
    
    (* Flankenerkennung für Befehle *)
    oldZeroCalib        : BOOL := FALSE;
    oldResetDev         : BOOL := FALSE;
    
    (* Timer *)
    tPollConc           : TON;
    tPollTemp           : TON;
    tTimeout            : TON;
    tTimeoutInit        : TIME := T#1500ms;     (* Großzügiges Timeout für Initialisierung *)
    initRetryCounter    : INT := 0;             (* Retry-Zähler für Initialisierung *)
    
    (* Helfer für Float & Integer *)
    dwHelper            : DWORD;
    pRealHelper         : POINTER TO REAL;
    nUnitVal            : UINT;
    nGasIdx             : USINT;
END_VAR

(* ============================================================================ *)
(* Bus-Kanal-IDs synchronisieren                                               *)
(* ============================================================================ *)
Bus.TxCobId := Tx_CobId;
Bus.RxCobId := Rx_CobId;

(* ============================================================================ *)
(* Baustein-Deaktivierung                                                      *)
(* ============================================================================ *)
IF NOT Enable THEN
    eState          := MF_STATE_DISABLED;
    Data.State      := MF_STATE_DISABLED;
    Data.StateText  := 'Deaktiviert';
    Data.Connected  := FALSE;
    Bus.TxReq       := FALSE;
    subStep         := 0;
    RETURN;
END_IF;

(* ============================================================================ *)
(* Fehler-Reset                                                                *)
(* ============================================================================ *)
IF Reset THEN
    Data.Error      := FALSE;
    Data.ErrorCode  := MF_ERR_NONE;
    Data.ErrorText  := 'OK';
    timeoutCounter  := 0;
    subStep         := 0;
    eState          := MF_STATE_INIT_START;
END_IF;

(* ============================================================================ *)
(* Kontinuierliche Übernahme von Gerätefehlern aus dem Statusbyte              *)
(* ============================================================================ *)
IF Bus.RxNew AND Bus.RxLen >= 7 THEN
    Data.StatusByte      := Bus.RxData[6];
    
    (* Bit-Zuordnung laut microFlow Handbuch S. 9 *)
    Data.IR_Detected     := (Data.StatusByte AND 16#80) <> 16#00; (* Bit 7: 1 = IR-Strahler erkannt *)
    Data.UV1_Detected    := (Data.StatusByte AND 16#20) <> 16#00; (* Bit 5: 1 = UV-LED 1 erkannt *)
    Data.UV2_Detected    := (Data.StatusByte AND 16#10) <> 16#00; (* Bit 4: 1 = UV-LED 2 erkannt *)
    Data.IR_Level_OK     := (Data.StatusByte AND 16#08) = 16#00;  (* Bit 3: 0 = Normal > 50%, 1 = Fehler < 50% *)
    Data.UV1_Level_Error := (Data.StatusByte AND 16#02) <> 16#00; (* Bit 1: 1 = UV-LED 1 Pegelfehler *)
    Data.UV2_Level_Error := (Data.StatusByte AND 16#01) <> 16#00; (* Bit 0: 1 = UV-LED 2 Pegelfehler *)

    (* Fehlerbehandlung direkt aus den Statusbits des Sensors *)
    IF NOT Data.IR_Detected THEN
        Data.Error     := TRUE;
        Data.ErrorCode := MF_ERR_IR_LAMP_MISSING;
        Data.ErrorText := 'Gerätefehler: IR-Quelle nicht erkannt oder defekt';
    ELSIF NOT Data.IR_Level_OK THEN
        Data.Error     := TRUE;
        Data.ErrorCode := MF_ERR_IR_LAMP_LEVEL;
        Data.ErrorText := 'Gerätefehler: IR-Pegel < 50% (Verschmutzung oder Alterung)';
    ELSIF (Data.Gastype_CH1 = 'SO2' OR Data.Gastype_CH1 = 'NO' OR Data.Gastype_CH1 = 'NO2' OR Data.Gastype_CH1 = 'O3') AND Data.UV1_Level_Error THEN
        Data.Error     := TRUE;
        Data.ErrorCode := MF_ERR_UV_LEVEL;
        Data.ErrorText := 'Gerätefehler: UV-LED 1 Pegelfehler';
    ELSE
        (* Wenn kein Gerätefehler ansteht und kein Timeout aktiv ist -> OK *)
        IF Data.ErrorCode <> MF_ERR_COMM_TIMEOUT THEN
            Data.Error     := FALSE;
            Data.ErrorCode := MF_ERR_NONE;
            Data.ErrorText := 'OK';
        END_IF;
    END_IF;
END_IF;

(* ============================================================================ *)
(* Flankenauswertung für Sonderbefehle                                          *)
(* ============================================================================ *)
IF Cmd_ZeroCalibration AND NOT oldZeroCalib AND eState = MF_STATE_READY THEN
    eState  := MF_STATE_ZERO_CALIB;
    subStep := 0;
END_IF;
oldZeroCalib := Cmd_ZeroCalibration;

IF Cmd_ResetDevice AND NOT oldResetDev AND eState = MF_STATE_READY THEN
    eState  := MF_STATE_RESET_DEVICE;
    subStep := 0;
END_IF;
oldResetDev := Cmd_ResetDevice;

(* ============================================================================ *)
(* Zustandsmaschine (State Machine)                                            *)
(* ============================================================================ *)
Data.State := eState;

CASE eState OF
    
    (* ------------------------------------------------------------------------ *)
    (* DISABLED                                                                 *)
    (* ------------------------------------------------------------------------ *)
    MF_STATE_DISABLED:
        Data.StateText := 'Deaktiviert';
        IF Enable THEN
            eState := MF_STATE_INIT_START;
        END_IF;

    (* ------------------------------------------------------------------------ *)
    (* INIT_START                                                               *)
    (* ------------------------------------------------------------------------ *)
    MF_STATE_INIT_START:
        Data.StateText   := 'Initialisiere...';
        subStep          := 0;
        timeoutCounter   := 0;
        initRetryCounter := 0;
        eState           := MF_STATE_READ_SN;

    (* ------------------------------------------------------------------------ *)
    (* 1. Seriennummer abfragen (Cmd 16#40)                                     *)
    (* ------------------------------------------------------------------------ *)
    MF_STATE_READ_SN:
        Data.StateText := 'Lese Seriennummer...';
        IF subStep = 0 THEN
            Bus.TxData[0] := 16#40; Bus.TxData[1] := 16#00; Bus.TxData[2] := 16#00; Bus.TxData[3] := 16#00;
            Bus.TxData[4] := 16#00; Bus.TxData[5] := 16#00; Bus.TxData[6] := 16#55; Bus.TxData[7] := 16#30;
            Bus.TxReq := TRUE;
            subStep   := 1;
        ELSIF subStep = 1 THEN
            tTimeout(IN := TRUE, PT := tTimeoutInit);
            IF Bus.RxNew AND Bus.RxData[0] = 16#40 THEN
                tTimeout(IN := FALSE);
                initRetryCounter := 0;
                Data.SerialNumber := WORD_TO_UINT(SHL(BYTE_TO_WORD(Bus.RxData[3]), 8) OR BYTE_TO_WORD(Bus.RxData[2]));
                subStep := 0;
                eState  := MF_STATE_READ_SW_REV;
            ELSIF tTimeout.Q THEN
                tTimeout(IN := FALSE);
                initRetryCounter := initRetryCounter + 1;
                IF initRetryCounter >= 3 THEN
                    initRetryCounter := 0;
                    Data.Connected := FALSE;
                    Data.Error     := TRUE;
                    Data.ErrorCode := MF_ERR_COMM_TIMEOUT;
                    Data.ErrorText := 'Timeout bei Abfrage Seriennummer';
                    subStep := 0;
                    eState  := MF_STATE_ERROR;
                ELSE
                    subStep := 0; (* Automatische Wiederholung *)
                END_IF;
            END_IF;
        END_IF;

    (* ------------------------------------------------------------------------ *)
    (* 2. Firmware-Revision abfragen (Cmd 16#0B)                                *)
    (* ------------------------------------------------------------------------ *)
    MF_STATE_READ_SW_REV:
        Data.StateText := 'Lese Firmware-Version...';
        IF subStep = 0 THEN
            Bus.TxData[0] := 16#0B; Bus.TxData[1] := 16#00; Bus.TxData[2] := 16#00; Bus.TxData[3] := 16#00;
            Bus.TxData[4] := 16#00; Bus.TxData[5] := 16#00; Bus.TxData[6] := 16#55; Bus.TxData[7] := 16#30;
            Bus.TxReq := TRUE;
            subStep   := 1;
        ELSIF subStep = 1 THEN
            tTimeout(IN := TRUE, PT := tTimeoutInit);
            IF Bus.RxNew AND Bus.RxData[0] = 16#0B THEN
                tTimeout(IN := FALSE);
                initRetryCounter := 0;
                Data.SoftwareRevision := WORD_TO_UINT(SHL(BYTE_TO_WORD(Bus.RxData[3]), 8) OR BYTE_TO_WORD(Bus.RxData[2]));
                subStep := 0;
                eState  := MF_STATE_READ_CONFIG_ID;
            ELSIF tTimeout.Q THEN
                tTimeout(IN := FALSE);
                initRetryCounter := initRetryCounter + 1;
                IF initRetryCounter >= 3 THEN
                    initRetryCounter := 0;
                    Data.Connected := FALSE;
                    Data.Error     := TRUE;
                    Data.ErrorCode := MF_ERR_COMM_TIMEOUT;
                    Data.ErrorText := 'Timeout bei Abfrage Firmware';
                    subStep := 0;
                    eState  := MF_STATE_ERROR;
                ELSE
                    subStep := 0; (* Automatische Wiederholung *)
                END_IF;
            END_IF;
        END_IF;

    (* ------------------------------------------------------------------------ *)
    (* 3. Config-ID & Gastyp abfragen (Cmd 16#62)                               *)
    (* ------------------------------------------------------------------------ *)
    MF_STATE_READ_CONFIG_ID:
        Data.StateText := 'Lese Gastyp (Config ID)...';
        IF subStep = 0 THEN
            Bus.TxData[0] := 16#62; Bus.TxData[1] := 16#00; Bus.TxData[2] := 16#00; Bus.TxData[3] := 16#00;
            Bus.TxData[4] := 16#00; Bus.TxData[5] := 16#00; Bus.TxData[6] := 16#55; Bus.TxData[7] := 16#30;
            Bus.TxReq := TRUE;
            subStep   := 1;
        ELSIF subStep = 1 THEN
            tTimeout(IN := TRUE, PT := tTimeoutInit);
            IF Bus.RxNew AND Bus.RxData[0] = 16#62 THEN
                tTimeout(IN := FALSE);
                initRetryCounter := 0;
                dwHelper := SHL(BYTE_TO_DWORD(Bus.RxData[5]), 24) OR SHL(BYTE_TO_DWORD(Bus.RxData[4]), 16) OR
                            SHL(BYTE_TO_DWORD(Bus.RxData[3]), 8)  OR BYTE_TO_DWORD(Bus.RxData[2]);
                Data.ConfigID := dwHelper;
                
                (* Gastyp für Kanal 1 (Nibble 3: Bits 12..15 laut Handbuch S. 10/11) *)
                nGasIdx := DWORD_TO_USINT(SHR(dwHelper, 12) AND 16#0F);
                CASE nGasIdx OF
                    0: Data.Gastype_CH1 := 'none';
                    1: Data.Gastype_CH1 := 'SO2';
                    2: Data.Gastype_CH1 := 'CO2';
                    3: Data.Gastype_CH1 := 'CO';
                    4: Data.Gastype_CH1 := 'NO';
                    5: Data.Gastype_CH1 := 'NO2';
                    6: Data.Gastype_CH1 := 'N2O';
                    7: Data.Gastype_CH1 := 'H2S';
                    8: Data.Gastype_CH1 := 'CH4';
                    9: Data.Gastype_CH1 := 'CnHm';
                    16#0A: Data.Gastype_CH1 := 'Cl2';
                    16#0B: Data.Gastype_CH1 := 'H2O';
                    16#0C: Data.Gastype_CH1 := 'ClO2';
                    16#0D: Data.Gastype_CH1 := 'O3';
                    16#0E: Data.Gastype_CH1 := 'SF6';
                    16#0F: Data.Gastype_CH1 := 'CF4';
                    ELSE   Data.Gastype_CH1 := 'Unknown';
                END_CASE;
                
                subStep := 0;
                eState  := MF_STATE_READ_RANGE;
            ELSIF tTimeout.Q THEN
                tTimeout(IN := FALSE);
                initRetryCounter := initRetryCounter + 1;
                IF initRetryCounter >= 3 THEN
                    initRetryCounter := 0;
                    Data.Connected := FALSE;
                    Data.Error     := TRUE;
                    Data.ErrorCode := MF_ERR_COMM_TIMEOUT;
                    Data.ErrorText := 'Timeout bei Abfrage Config-ID';
                    subStep := 0;
                    eState  := MF_STATE_ERROR;
                ELSE
                    subStep := 0; (* Automatische Wiederholung *)
                END_IF;
            END_IF;
        END_IF;

    (* ------------------------------------------------------------------------ *)
    (* 4. Messbereichsendwert CH1 abfragen (Cmd 16#47, Index 16#02)              *)
    (* ------------------------------------------------------------------------ *)
    MF_STATE_READ_RANGE:
        Data.StateText := 'Lese Messbereichsendwert...';
        IF subStep = 0 THEN
            Bus.TxData[0] := 16#47; Bus.TxData[1] := 16#02; Bus.TxData[2] := 16#00; Bus.TxData[3] := 16#00;
            Bus.TxData[4] := 16#00; Bus.TxData[5] := 16#00; Bus.TxData[6] := 16#55; Bus.TxData[7] := 16#30;
            Bus.TxReq := TRUE;
            subStep   := 1;
        ELSIF subStep = 1 THEN
            tTimeout(IN := TRUE, PT := tTimeoutInit);
            IF Bus.RxNew AND Bus.RxData[0] = 16#47 AND Bus.RxData[1] = 16#02 THEN
                tTimeout(IN := FALSE);
                initRetryCounter := 0;
                dwHelper := SHL(BYTE_TO_DWORD(Bus.RxData[5]), 24) OR SHL(BYTE_TO_DWORD(Bus.RxData[4]), 16) OR
                            SHL(BYTE_TO_DWORD(Bus.RxData[3]), 8)  OR BYTE_TO_DWORD(Bus.RxData[2]);
                pRealHelper := ADR(dwHelper);
                Data.MeasurementRange_CH1 := pRealHelper^;
                subStep := 0;
                eState  := MF_STATE_READ_UNIT;
            ELSIF tTimeout.Q THEN
                tTimeout(IN := FALSE);
                initRetryCounter := initRetryCounter + 1;
                IF initRetryCounter >= 3 THEN
                    initRetryCounter := 0;
                    Data.Connected := FALSE;
                    Data.Error     := TRUE;
                    Data.ErrorCode := MF_ERR_COMM_TIMEOUT;
                    Data.ErrorText := 'Timeout bei Abfrage Messbereich';
                    subStep := 0;
                    eState  := MF_STATE_ERROR;
                ELSE
                    subStep := 0; (* Automatische Wiederholung *)
                END_IF;
            END_IF;
        END_IF;

    (* ------------------------------------------------------------------------ *)
    (* 5. Messeinheit CH1 abfragen (Cmd 16#61, Index 16#02)                     *)
    (* ------------------------------------------------------------------------ *)
    MF_STATE_READ_UNIT:
        Data.StateText := 'Lese Messeinheit...';
        IF subStep = 0 THEN
            Bus.TxData[0] := 16#61; Bus.TxData[1] := 16#02; Bus.TxData[2] := 16#00; Bus.TxData[3] := 16#00;
            Bus.TxData[4] := 16#00; Bus.TxData[5] := 16#00; Bus.TxData[6] := 16#55; Bus.TxData[7] := 16#30;
            Bus.TxReq := TRUE;
            subStep   := 1;
        ELSIF subStep = 1 THEN
            tTimeout(IN := TRUE, PT := tTimeoutInit);
            IF Bus.RxNew AND Bus.RxData[0] = 16#61 AND Bus.RxData[1] = 16#02 THEN
                tTimeout(IN := FALSE);
                initRetryCounter := 0;
                nUnitVal := WORD_TO_UINT(SHL(BYTE_TO_WORD(Bus.RxData[3]), 8) OR BYTE_TO_WORD(Bus.RxData[2]));
                IF nUnitVal = 0 THEN
                    Data.MeasurementUnit_CH1 := 'ppm';
                ELSIF nUnitVal = 1 THEN
                    Data.MeasurementUnit_CH1 := 'Vol.%';
                ELSE
                    Data.MeasurementUnit_CH1 := 'Raw';
                END_IF;
                subStep := 0;
                eState  := MF_STATE_READ_OP_HOURS;
            ELSIF tTimeout.Q THEN
                tTimeout(IN := FALSE);
                initRetryCounter := initRetryCounter + 1;
                IF initRetryCounter >= 3 THEN
                    initRetryCounter := 0;
                    Data.Connected := FALSE;
                    Data.Error     := TRUE;
                    Data.ErrorCode := MF_ERR_COMM_TIMEOUT;
                    Data.ErrorText := 'Timeout bei Abfrage Messeinheit';
                    subStep := 0;
                    eState  := MF_STATE_ERROR;
                ELSE
                    subStep := 0; (* Automatische Wiederholung *)
                END_IF;
            END_IF;
        END_IF;

    (* ------------------------------------------------------------------------ *)
    (* 6. Betriebsstunden abfragen (Cmd 16#43)                                  *)
    (* ------------------------------------------------------------------------ *)
    MF_STATE_READ_OP_HOURS:
        Data.StateText := 'Lese Betriebsstunden...';
        IF subStep = 0 THEN
            Bus.TxData[0] := 16#43; Bus.TxData[1] := 16#00; Bus.TxData[2] := 16#00; Bus.TxData[3] := 16#00;
            Bus.TxData[4] := 16#00; Bus.TxData[5] := 16#00; Bus.TxData[6] := 16#55; Bus.TxData[7] := 16#30;
            Bus.TxReq := TRUE;
            subStep   := 1;
        ELSIF subStep = 1 THEN
            tTimeout(IN := TRUE, PT := tTimeoutInit);
            IF Bus.RxNew AND Bus.RxData[0] = 16#43 THEN
                tTimeout(IN := FALSE);
                initRetryCounter := 0;
                Data.OperatingHours := WORD_TO_UINT(SHL(BYTE_TO_WORD(Bus.RxData[3]), 8) OR BYTE_TO_WORD(Bus.RxData[2]));
                
                (* Init erfolgreich abgeschlossen! *)
                Data.Connected := TRUE;
                Data.Error     := FALSE;
                Data.ErrorCode := MF_ERR_NONE;
                Data.ErrorText := 'OK';
                subStep        := 0;
                eState         := MF_STATE_READY;
            ELSIF tTimeout.Q THEN
                tTimeout(IN := FALSE);
                initRetryCounter := initRetryCounter + 1;
                IF initRetryCounter >= 3 THEN
                    initRetryCounter := 0;
                    Data.Connected := FALSE;
                    Data.Error     := TRUE;
                    Data.ErrorCode := MF_ERR_COMM_TIMEOUT;
                    Data.ErrorText := 'Timeout bei Abfrage Betriebsstunden';
                    subStep := 0;
                    eState  := MF_STATE_ERROR;
                ELSE
                    subStep := 0; (* Automatische Wiederholung *)
                END_IF;
            END_IF;
        END_IF;

    (* ------------------------------------------------------------------------ *)
    (* READY: Bereit & zyklisches Polling                                       *)
    (* ------------------------------------------------------------------------ *)
    MF_STATE_READY:
        Data.StateText := 'Bereit / Messung aktiv';
        subStep        := 0;
        tTimeout(IN := FALSE);
        
        tPollConc(IN := NOT tPollConc.Q, PT := PollInterval_Conc);
        tPollTemp(IN := NOT tPollTemp.Q, PT := PollInterval_Temp);
        
        IF tPollConc.Q THEN
            queryCH2Active := FALSE;
            eState := MF_STATE_POLL_CONC;
        ELSIF tPollTemp.Q THEN
            eState := MF_STATE_POLL_TEMP;
        END_IF;

    (* ------------------------------------------------------------------------ *)
    (* POLL_CONC: Gaskonzentration abfragen                                     *)
    (* ------------------------------------------------------------------------ *)
    MF_STATE_POLL_CONC:
        Data.StateText := 'Messe Konzentration...';
        IF subStep = 0 THEN
            Bus.TxData[0] := 16#17;
            IF queryCH2Active THEN
                Bus.TxData[1] := 16#01; (* CH2 *)
            ELSE
                Bus.TxData[1] := 16#00; (* CH1 *)
            END_IF;
            Bus.TxData[2] := 16#00; Bus.TxData[3] := 16#00; Bus.TxData[4] := 16#00; Bus.TxData[5] := 16#00;
            Bus.TxData[6] := 16#55; Bus.TxData[7] := 16#30;
            Bus.TxReq := TRUE;
            subStep   := 1;
            
        ELSIF subStep = 1 THEN
            tTimeout(IN := TRUE, PT := TimeoutTime);
            
            IF Bus.RxNew AND Bus.RxData[0] = 16#17 THEN
                tTimeout(IN := FALSE);
                timeoutCounter := 0;
                Data.Connected := TRUE;
                
                dwHelper := SHL(BYTE_TO_DWORD(Bus.RxData[5]), 24) OR SHL(BYTE_TO_DWORD(Bus.RxData[4]), 16) OR
                            SHL(BYTE_TO_DWORD(Bus.RxData[3]), 8)  OR BYTE_TO_DWORD(Bus.RxData[2]);
                pRealHelper := ADR(dwHelper);
                
                IF Bus.RxData[1] = 16#00 THEN
                    Data.Concentration_CH1 := pRealHelper^;
                    IF ReadCH2 THEN
                        queryCH2Active := TRUE;
                        subStep        := 0; (* Direkt Kanal 2 abfragen *)
                    ELSE
                        eState         := MF_STATE_READY;
                    END_IF;
                ELSIF Bus.RxData[1] = 16#01 THEN
                    Data.Concentration_CH2 := pRealHelper^;
                    eState                 := MF_STATE_READY;
                END_IF;
                
            ELSIF tTimeout.Q THEN
                tTimeout(IN := FALSE);
                timeoutCounter := timeoutCounter + 1;
                IF timeoutCounter >= 3 THEN
                    Data.Connected := FALSE;
                    Data.Error     := TRUE;
                    Data.ErrorCode := MF_ERR_COMM_TIMEOUT;
                    Data.ErrorText := 'Kommunikations-Timeout (Keine Antwort)';
                    eState         := MF_STATE_ERROR;
                ELSE
                    eState := MF_STATE_READY;
                END_IF;
            END_IF;
        END_IF;

    (* ------------------------------------------------------------------------ *)
    (* POLL_TEMP: Detektortemperatur abfragen                                   *)
    (* ------------------------------------------------------------------------ *)
    MF_STATE_POLL_TEMP:
        Data.StateText := 'Messe Temperatur...';
        IF subStep = 0 THEN
            Bus.TxData[0] := 16#18; Bus.TxData[1] := 16#00; Bus.TxData[2] := 16#00; Bus.TxData[3] := 16#00;
            Bus.TxData[4] := 16#00; Bus.TxData[5] := 16#00; Bus.TxData[6] := 16#55; Bus.TxData[7] := 16#30;
            Bus.TxReq := TRUE;
            subStep   := 1;
            
        ELSIF subStep = 1 THEN
            tTimeout(IN := TRUE, PT := TimeoutTime);
            
            IF Bus.RxNew AND Bus.RxData[0] = 16#18 THEN
                tTimeout(IN := FALSE);
                timeoutCounter := 0;
                
                dwHelper := SHL(BYTE_TO_DWORD(Bus.RxData[5]), 24) OR SHL(BYTE_TO_DWORD(Bus.RxData[4]), 16) OR
                            SHL(BYTE_TO_DWORD(Bus.RxData[3]), 8)  OR BYTE_TO_DWORD(Bus.RxData[2]);
                pRealHelper := ADR(dwHelper);
                Data.Temperature_CH1 := pRealHelper^;
                eState := MF_STATE_READY;
                
            ELSIF tTimeout.Q THEN
                tTimeout(IN := FALSE);
                timeoutCounter := timeoutCounter + 1;
                IF timeoutCounter >= 3 THEN
                    Data.Connected := FALSE;
                    Data.Error     := TRUE;
                    Data.ErrorCode := MF_ERR_COMM_TIMEOUT;
                    Data.ErrorText := 'Kommunikations-Timeout (Keine Antwort)';
                    eState         := MF_STATE_ERROR;
                ELSE
                    eState := MF_STATE_READY;
                END_IF;
            END_IF;
        END_IF;

    (* ------------------------------------------------------------------------ *)
    (* ZERO_CALIB: Nullpunkt-Kalibrierung auslösen                              *)
    (* ------------------------------------------------------------------------ *)
    MF_STATE_ZERO_CALIB:
        Data.StateText := 'Nullpunkt-Kalibrierung...';
        IF subStep = 0 THEN
            Bus.TxData[0] := 16#11; Bus.TxData[1] := 16#00; Bus.TxData[2] := 16#00; Bus.TxData[3] := 16#00;
            Bus.TxData[4] := 16#00; Bus.TxData[5] := 16#00; Bus.TxData[6] := 16#55; Bus.TxData[7] := 16#30;
            Bus.TxReq := TRUE;
            subStep   := 1;
        ELSIF subStep = 1 THEN
            tTimeout(IN := TRUE, PT := T#2s);
            IF Bus.RxNew AND Bus.RxData[0] = 16#11 THEN
                tTimeout(IN := FALSE);
                subStep := 0;
                eState  := MF_STATE_READY;
            ELSIF tTimeout.Q THEN
                tTimeout(IN := FALSE);
                subStep := 0;
                eState  := MF_STATE_READY;
            END_IF;
        END_IF;

    (* ------------------------------------------------------------------------ *)
    (* RESET_DEVICE: Sensor per Software neu starten                            *)
    (* ------------------------------------------------------------------------ *)
    MF_STATE_RESET_DEVICE:
        Data.StateText := 'Sensor wird neu gestartet...';
        IF subStep = 0 THEN
            Bus.TxData[0] := 16#04; Bus.TxData[1] := 16#00; Bus.TxData[2] := 16#00; Bus.TxData[3] := 16#00;
            Bus.TxData[4] := 16#00; Bus.TxData[5] := 16#00; Bus.TxData[6] := 16#55; Bus.TxData[7] := 16#30;
            Bus.TxReq := TRUE;
            subStep   := 1;
        ELSIF subStep = 1 THEN
            tTimeout(IN := TRUE, PT := T#1s);
            IF Bus.RxNew OR tTimeout.Q THEN
                tTimeout(IN := FALSE);
                subStep := 0;
                eState  := MF_STATE_INIT_START; (* Nach Reset komplett neu identifizieren *)
            END_IF;
        END_IF;

    (* ------------------------------------------------------------------------ *)
    (* ERROR                                                                    *)
    (* ------------------------------------------------------------------------ *)
    MF_STATE_ERROR:
        Data.StateText := 'Fehler';
        Data.Error     := TRUE;
        Bus.TxReq      := FALSE;
        IF Reset THEN
            Data.Error     := FALSE;
            Data.ErrorCode := MF_ERR_NONE;
            Data.ErrorText := 'OK';
            timeoutCounter := 0;
            subStep        := 0;
            eState         := MF_STATE_INIT_START;
        END_IF;

END_CASE;

END_FUNCTION_BLOCK
