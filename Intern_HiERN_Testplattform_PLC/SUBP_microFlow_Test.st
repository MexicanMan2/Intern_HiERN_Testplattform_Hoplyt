(********************************************************************************
 * PROGRAM: SUBP_microFlow_Test
 * 
 * Beschreibung:
 *   Testprogramm für die modulare microFlow Sensor-Architektur an Bachmann MX207:
 *     1. Zentraler Hardware-Broker (FB_CAN_Broker):
 *        - Kapselt CUL_PLC, leert die RX-Queue zyklisch, Round-Robin TX
 *     2. Modulare Sensor-Bausteine (3x FB_microFlow_Device):
 *        - Identische Bausteine, parametriert nur über CAN-IDs
 *        - Vollautomatische Identifikation beim Booten (SN, Firmware, Gastyp, 
 *          Messbereich, Einheit)
 *        - Zustandsmaschine mit Diagnose- und Fehlerübernahme direkt aus dem Gerät!
 ********************************************************************************)
PROGRAM SUBP_microFlow_Test
VAR
    (* Zentraler Hardware CAN-Broker *)
    fbBroker            : FB_CAN_Broker;
    
    (* Modulare Sensor-Treiber (1 Instanz pro Sensor) *)
    fbSensor1           : FB_microFlow_Device;
    fbSensor2           : FB_microFlow_Device;
    fbSensor3           : FB_microFlow_Device;
    
    (* Verbindungskanäle zwischen Broker und Sensoren *)
    chan1               : ST_CAN_Broker_Channel;
    chan2               : ST_CAN_Broker_Channel;
    chan3               : ST_CAN_Broker_Channel;
    
    (* Globale Steuerung *)
    bEnable             : BOOL := TRUE;
    bReset              : BOOL := FALSE;
    nNetNb              : DINT := 1;            (* CAN NetNumber (Standard: 1) *)
    nCardNb             : DINT := 2;            (* CPU-Slot (CardNb 2) *)
    nChan               : UDINT := 0;           (* CAN-Kanal (0 = CAN A) *)
    
    (* Abtastraten *)
    tPollConc           : TIME := T#100ms;      (* Konzentration: 100ms (10 Hz) *)
    tPollTemp           : TIME := T#5s;         (* Temperatur: 5s *)
    tTimeout            : TIME := T#150ms;      (* CAN-Timeout *)
    
    (* Konfiguration Sensor 1 (aktiv am Bus) *)
    bSensor1_Enable     : BOOL := TRUE;
    nSensor1_TxId       : UDINT := 16#300;      (* Sende-ID an Sensor 1 *)
    nSensor1_RxId       : UDINT := 16#208;      (* Antwort-ID von Sensor 1 *)
    
    (* Konfiguration Sensor 2 (vorbereitet) *)
    bSensor2_Enable     : BOOL := FALSE;        (* Auf TRUE setzen, sobald Sensor 2 am Bus ist *)
    nSensor2_TxId       : UDINT := 16#301;      (* Sende-ID an Sensor 2 *)
    nSensor2_RxId       : UDINT := 16#209;      (* Antwort-ID von Sensor 2 *)
    
    (* Konfiguration Sensor 3 (vorbereitet) *)
    bSensor3_Enable     : BOOL := FALSE;        (* Auf TRUE setzen, sobald Sensor 3 am Bus ist *)
    nSensor3_TxId       : UDINT := 16#302;      (* Sende-ID an Sensor 3 *)
    nSensor3_RxId       : UDINT := 16#20A;      (* Antwort-ID von Sensor 3 *)
    
    (* Broker Status *)
    bBrokerReady        : BOOL;
    bBrokerError        : BOOL;
    nBrokerErrorID      : DINT;
    
    (* Sensor-Datenstrukturen zur Beobachtung im SolutionCenter *)
    Data_Sensor1        : ST_microFlow_Data;
    Data_Sensor2        : ST_microFlow_Data;
    Data_Sensor3        : ST_microFlow_Data;
    
    (* Gesamt-Status *)
    bAllConnected       : BOOL;
    bAnyError           : BOOL;
END_VAR

(* ============================================================================ *)
(* 1. Zentraler CAN-Broker: Hardware-Treiber & Queue-Management                 *)
(* ============================================================================ *)
fbBroker(
    Enable              := bEnable,
    Reset               := bReset,
    NetNb               := nNetNb,
    CardNb              := nCardNb,
    Chan                := nChan,
    Channel1            := chan1,
    Channel2            := chan2,
    Channel3            := chan3,
    Ready               => bBrokerReady,
    Error               => bBrokerError,
    ErrorID             => nBrokerErrorID
);

(* ============================================================================ *)
(* 2. Sensor 1 Baustein (z. B. 0-50 Vol% CO)                                    *)
(* ============================================================================ *)
fbSensor1(
    Enable              := bEnable AND bSensor1_Enable,
    Reset               := bReset,
    Tx_CobId            := nSensor1_TxId,
    Rx_CobId            := nSensor1_RxId,
    PollInterval_Conc   := tPollConc,
    PollInterval_Temp   := tPollTemp,
    TimeoutTime         := tTimeout,
    ReadCH2             := FALSE,
    Bus                 := chan1,
    Data                => Data_Sensor1
);

(* ============================================================================ *)
(* 3. Sensor 2 Baustein (z. B. 0-500 ppm CO2)                                   *)
(* ============================================================================ *)
fbSensor2(
    Enable              := bEnable AND bSensor2_Enable,
    Reset               := bReset,
    Tx_CobId            := nSensor2_TxId,
    Rx_CobId            := nSensor2_RxId,
    PollInterval_Conc   := tPollConc,
    PollInterval_Temp   := tPollTemp,
    TimeoutTime         := tTimeout,
    ReadCH2             := FALSE,
    Bus                 := chan2,
    Data                => Data_Sensor2
);

(* ============================================================================ *)
(* 4. Sensor 3 Baustein (z. B. 0-50 Vol% CO2)                                   *)
(* ============================================================================ *)
fbSensor3(
    Enable              := bEnable AND bSensor3_Enable,
    Reset               := bReset,
    Tx_CobId            := nSensor3_TxId,
    Rx_CobId            := nSensor3_RxId,
    PollInterval_Conc   := tPollConc,
    PollInterval_Temp   := tPollTemp,
    TimeoutTime         := tTimeout,
    ReadCH2             := FALSE,
    Bus                 := chan3,
    Data                => Data_Sensor3
);

(* ============================================================================ *)
(* 5. Sammel-Status für die Gesamtanlage                                        *)
(* ============================================================================ *)
bAllConnected := (NOT bSensor1_Enable OR Data_Sensor1.Connected) AND
                 (NOT bSensor2_Enable OR Data_Sensor2.Connected) AND
                 (NOT bSensor3_Enable OR Data_Sensor3.Connected);

bAnyError     := bBrokerError OR
                 (bSensor1_Enable AND Data_Sensor1.Error) OR
                 (bSensor2_Enable AND Data_Sensor2.Error) OR
                 (bSensor3_Enable AND Data_Sensor3.Error);

END_PROGRAM
