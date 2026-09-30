FUNCTION TrimCRLF : STRING
VAR_INPUT
    str : STRING;
END_VAR
VAR
    tmp : STRING;
    L   : INT;
    firstChar, lastChar : STRING;
    CR, LF : STRING;
END_VAR

CR := Util_Chr(BYTE#13);
LF := Util_Chr(BYTE#10);
tmp := str;

(* Leading trim (CR, LF, Space, Tab optional) *)
WHILE LEN(tmp) > 0 DO
    firstChar := LEFT(tmp, 1);
    IF (firstChar = CR) OR (firstChar = LF) OR (firstChar = ' ') OR (firstChar = Util_Chr(Chr := 16#09)) THEN
        tmp := MID(tmp, 2, LEN(tmp) - 1);
    ELSE
        EXIT;
    END_IF;
END_WHILE;

(*  Trailing trim (CR, LF, Space, Tab optional) *)
L := LEN(tmp);
WHILE L > 0 DO
    lastChar := RIGHT(tmp, 1);
    IF (lastChar = CR) OR (lastChar = LF) OR (lastChar = ' ') OR (lastChar = Util_Chr(Chr := 16#09)) THEN
        tmp := LEFT(tmp, L - 1);
        L := L - 1;
    ELSE
        EXIT;
    END_IF;
END_WHILE;

TrimCRLF := tmp;

END_FUNCTION
