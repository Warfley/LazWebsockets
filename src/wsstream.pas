unit wsstream;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ssockets, wsmessages, Sockets;

type

  { EWebsocketError }

  EWebsocketError = class(Exception)
  private
    FCode: integer;
  public
    constructor Create(const msg: string; ACode: integer);
    property Code: integer read FCode;
  end;

  EWebsocketWriteError = class(EWebsocketError);

  EWebsocketReadError = class(EWebsocketError);

  TNetAddress = record
    Address: string;
    Port: integer;
  end;

  { TLockedSocketStream }

  TLockedSocketStream = class
  private
    FLocalAddress: TNetAddress;
    FRemoteAddress: TNetAddress;
    FStream: TSocketStream;
    FReadLock: TRTLCriticalSection;
    FWriteLock: TRTLCriticalSection;
    function isOpen: boolean;
  public
    constructor Create(const AStream: TSocketStream);
    destructor Destroy; override;

    function LockRead: TSocketStream;
    procedure UnlockRead;
    function LockWrite: TSocketStream;
    procedure UnlockWrite;
    procedure CloseStream;
    property Open: boolean read isOpen;
    property RemoteAddress: TNetAddress read FRemoteAddress;
    property LocalAddress: TNetAddress read FLocalAddress;
  end;

  TWebsocketCommunincator = class;

  { TWebsocketMessageStream }

  TWebsocketMessageStream = class(TStream)
  private
    FCommunicator: TWebsocketCommunincator;
    FMaxFrameSize: int64;
    FMessageType: TWebsocketMessageType;
    FBuffer: TBytes;
    FCurrentLen: int64;
    FFirstWrite: boolean;
    FMaskKey: integer;

    procedure WriteDataFrame(Finished: boolean = False);
  public
    constructor Create(const ACommunicator: TWebsocketCommunincator;
      AMessageType: TWebsocketMessageType; AMaxFrameLen: int64;
  AMaskKey: integer);
    destructor Destroy; override;
    function Seek(Offset: longint; Origin: word): longint; override;
    function Read(var Buffer; Count: longint): longint; override;
    function Write(const Buffer; Count: longint): longint; override;
  end;

  { TWebsocketCommunincator }

  TWebsocketCommunincator = class
  private
    FStream: TLockedSocketStream;
    FMessages: TLockedWebsocketMessageList;
    FMaskMessages: boolean;
    FAssumeMaskedMessages: boolean;
    FOnRecieveMessage: TNotifyEvent;
    FOnClose: TNotifyEvent;
    FExpectClose: boolean;
    function GenerateMask: integer;
    function GetOpen: boolean;
  public
    constructor Create(AStream: TLockedSocketStream; AMaskMessage: boolean;
      AssumeMaskedMessages: boolean);
    destructor Destroy; override;

    procedure Close(ForceClose: boolean = False);

    procedure RecieveMessage;
    function GetUnprocessedMessages(const MsgList: TWebsocketMessageOwnerList): integer;

    function WriteMessage(MessageType: TWebsocketMessageType = wmtString;
      MaxFrameLength: int64 = 125): TWebsocketMessageStream;

    property OnRecieveMessage: TNotifyEvent read FOnRecieveMessage
      write FOnRecieveMessage;
    property OnClose: TNotifyEvent read FOnClose write FOnClose;
    property SocketStream: TLockedSocketStream read FStream;
    property Open: boolean read GetOpen;
  end;

implementation
{*------------------------------------------------------------------------------
 * extension of htons and htonl for qwords (ll: long long from C)
 *-----------------------------------------------------------------------------}
function htonll(host: QWord): QWord; inline;
begin
{$ifdef FPC_BIG_ENDIAN}
  Result := host;
{$else}
  Result := SwapEndian(host);
{$endif}
end;

function ntohll(net: QWord): QWord; inline;
begin
{$ifdef FPC_BIG_ENDIAN}
  Result := net;
{$else}
  Result := SwapEndian(net);
{$endif}
end;


type
  { Protocol specific types }
  TWebsocketFrameHeader = record
    Fin: boolean;
    OPCode: TWebsocketMessageType;
    Mask: boolean;
    PayloadLen: byte;
  end;
  TMaskRec = record
    case boolean of
      True: (Bytes: array[0..3] of byte);
      False: (Key: integer);
  end;
  TWordRec = record
    case boolean of
      True: (Bytes: array[0..1] of byte);
      False: (Value: word);
  end;

function WordToFrameHeader(Data: word): TWebsocketFrameHeader; inline;
var
  wordRec: TWordRec;
begin
  wordRec.Value := Data;
  Result.Fin := (wordRec.Bytes[0] and 128) = 128;
  Result.OPCode := TWebsocketMessageType(wordRec.Bytes[0] and %1111);
  Result.Mask := (wordRec.Bytes[1] and 128) = 128;
  Result.PayloadLen := wordRec.Bytes[1] and %1111111;
end;

function boolToBit(b: boolean; Bit: byte): byte; inline;
begin
  Result := 0;
  if b then
    Result := 1 shl Bit;
end;

function FrameHEaderToWord(const Header: TWebsocketFrameHeader): word; inline;
var
  wordRec: TWordRec;
begin
  wordRec.Bytes[0] := boolToBit(Header.Fin, 7) or (Ord(Header.OPCode) and %1111);
  wordRec.Bytes[1] := boolToBit(Header.Mask, 7) or (Header.PayloadLen and %1111111);
  Result := wordRec.Value;
end;

{ EWebsocketError }

constructor EWebsocketError.Create(const msg: string; ACode: integer);
begin
  inherited Create(msg);
  FCode := ACode;
end;

{ TLockedSocketStream }

function TLockedSocketStream.isOpen: boolean;
begin
  // Simply reading don't need locks
  // If you want to do anything afterwards you still need to lock and check if
  // the stream is assigned
  Result := Assigned(FStream);
end;

constructor TLockedSocketStream.Create(const AStream: TSocketStream);
begin
  FLocalAddress.Address := NetAddrToStr(AStream.LocalAddress.sin_addr);
  FLocalAddress.Port := AStream.LocalAddress.sin_port;
  FRemoteAddress.Address := NetAddrToStr(AStream.RemoteAddress.sin_addr);
  FRemoteAddress.Port := AStream.LocalAddress.sin_port;
  FStream := AStream;
  InitCriticalSection(FReadLock);
  InitCriticalSection(FWriteLock);
end;

destructor TLockedSocketStream.Destroy;
begin
  CloseStream;
  DoneCriticalsection(FWriteLock);
  DoneCriticalsection(FReadLock);
  inherited Destroy;
end;

function TLockedSocketStream.LockRead: TSocketStream;
begin
  EnterCriticalsection(FReadLock);
  Result := FStream;
end;

procedure TLockedSocketStream.UnlockRead;
begin
  LeaveCriticalsection(FReadLock);
end;     

function TLockedSocketStream.LockWrite: TSocketStream;
begin
  EnterCriticalsection(FWriteLock);
  Result := FStream;
end;

procedure TLockedSocketStream.UnlockWrite;
begin
  LeaveCriticalsection(FWriteLock);
end;

procedure TLockedSocketStream.CloseStream;
begin
  LockRead;
  try
    LockWrite;
    try
      FreeAndNil(FStream);
    finally
      UnlockWrite;
    end;
  finally
    UnlockRead;
  end;
end;

{ TWebsocketCommunincator }

function TWebsocketCommunincator.GenerateMask: integer;
begin
  Result := -1;
  if FMaskMessages then // Not really secure...
    Result := integer(Random(DWord.MaxValue));
end;

function TWebsocketCommunincator.GetOpen: boolean;
begin
  Result := FStream.Open;
end;

constructor TWebsocketCommunincator.Create(AStream: TLockedSocketStream;
  AMaskMessage: boolean; AssumeMaskedMessages: boolean);
begin
  FStream := AStream;
  FMaskMessages := AMaskMessage;
  FAssumeMaskedMessages := AssumeMaskedMessages;
  FMessages := TLockedWebsocketMessageList.Create(TWebsocketMessageList.Create);
  FExpectClose := False;
end;

destructor TWebsocketCommunincator.Destroy;
begin
  // Ending communication => Close stream
  Close(True);
  FStream.Free;
  FMessages.Free;
  inherited Destroy;
end;

procedure TWebsocketCommunincator.Close(ForceClose: boolean);
begin
  if not Open then
    Exit;
  if not ForceClose then
  begin
    WriteMessage(wmtClose).Free;
    FExpectClose := True;
    Exit;
  end;
  if Assigned(FOnClose) then
    FOnClose(Self);
  FStream.CloseStream;
end;

procedure TWebsocketCommunincator.RecieveMessage;

  procedure ReadData(var buffer; const len: int64);
  var
    ToRead: longint;
    Read: longint;
    LeftToRead: int64;
    TotalRead: int64;
    oldTO: integer;
    Stream: TSocketStream;
  const
    IOTimeoutError = {$IFDEF UNIX}11{$ELSE}10060{$EndIf};
    WaitingTime = 10;
  begin
    TotalRead := 0;
    repeat
      // how much we are trying to read at a time
      LeftToRead := len - TotalRead;
      if LeftToRead > ToRead.MaxValue then
        ToRead := ToRead.MaxValue
      else
        ToRead := LeftToRead;
      // Reading

      Stream := FStream.LockRead;
      try
        if not Assigned(Stream) then
        begin
          raise EWebsocketReadError.Create('Socket already closed', 0);
        end;
        oldTO := Stream.IOTimeout;
        Stream.IOTimeout := 1;
        try
          Read := Stream.Read(PByte(@buffer)[TotalRead], ToRead);
          if Read < 0 then
          begin
            // on Error
            if Stream.LastError <> IOTimeoutError then
              raise EWebsocketReadError.Create('error reading from stream',
                Stream.LastError);
          end
          else
          begin
            // Increase the amount to read
            TotalRead += Read;
          end;
        finally
          Stream.IOTimeout := oldTO;
        end;
      finally
        FStream.UnlockRead;
      end;
      if (TotalRead < len) and (Read <> ToRead) then // not finished, wait for some data
        Sleep(WaitingTime);
    until TotalRead >= len;
  end;

  procedure AddMessageToList(Message: TWebsocketMessage);
  var
    lst: TWebsocketMessageList;
  begin
    if Assigned(Message) then
    begin
      lst := FMessages.Lock;
      try
        lst.Add(Message);
      finally
        FMessages.Unlock;
      end;
      if Assigned(FOnRecieveMessage) then
      begin
        FOnRecieveMessage(Self);
      end;
    end;
  end;

  function ProcessSpecialMessages(messageType: TWebsocketMessageType;
  var buffer; const buffLen: int64): boolean;
  var
    str: UTF8String;
  begin
    Result := True;
    case messageType of
      wmtClose:
      begin
        // If we didn't send the original close, return the message
        if not FExpectClose then
          WriteMessage(wmtClose).Free;
        // Close the stream (true to not send a message
        Close(True);
      end;
      wmtPing:
      begin
        // On ping send pong, with same content
        with WriteMessage(wmtPong) do
          try
            if buffLen > 0 then
              Write(PByte(@buffer)[0], buffLen);
          finally
            Free;
          end;
      end;
      wmtPong:
      begin
        // lift pong message to message queue, so user can handle it
        SetLength(str, buffLen);
        if buffLen > 0 then
          Move(buffer, str[1], buffLen);
        AddMessageToList(TWebsocketPongMessage.Create(str));
      end
      else
        Result := False;
    end;
  end;

var
  Header: TWebsocketFrameHeader;
  len64: int64;
  len16: word;
  len: int64;
  MaskRec: TMaskRec;
  buffer: TBytes;
  i: int64;
  Message: TWebsocketMessage;
  outputStream: TMemoryStream;
  messageType: TWebsocketMessageType;
  msgType: TWebsocketMessageType;
  str: UTF8String;
  w: word;
begin
  Message := nil;
  outputStream := TMemoryStream.Create;
  msgType:=wmtContinue;
  try
    try
      repeat
        if not Open then
          Exit;
        ReadData(w, 2);
        Header := WordToFrameHeader(w);
        if Header.OPCode <> wmtContinue then
          messageType := TWebsocketMessageType(Header.OPCode);
        if Header.PayloadLen < 126 then
          len := Header.PayloadLen
        else if Header.PayloadLen = 126 then
        begin
          ReadData(len16, SizeOf(len16));
          len := NToHs(len16);
        end
        else
        begin
          ReadData(len64, SizeOf(len64));
          len := ntohll(len64);
        end;
        if Header.Mask then
        begin
          ReadData(MaskRec.Key, SizeOf(MaskRec.Key));
        end
        else if FAssumeMaskedMessages then
        begin
          Close(True);
          Exit;
        end;
        // Read payload
        SetLength(buffer, len);
        if len > 0 then
        begin
          ReadData(buffer[0], len);
          if Header.Mask then
          begin
            // As this is 64 bit, to be 32 bit compatible we can't use a for loop
            i := 0;
            while i < len do
            begin
              buffer[i] := buffer[i] xor MaskRec.Bytes[i mod 4];
              Inc(i);
            end;
          end;
        end;
        // Handling special messages
        if ProcessSpecialMessages(messageType, PByte(buffer)^, len) then
        begin
          // am i in the middle of a communication?
          // If so dont use the fin in the end
          if msgType <> wmtContinue then Continue;
        end
        else
        begin
          if messageType <> wmtContinue then
            msgType:=messageType;
          // This is a dataframe, so save data for concatination of fragments
          if len > 0 then
            outputStream.WriteBuffer(buffer[0], len);
        end;
      until Header.Fin;
      // Read whole message
      outputStream.Seek(0, soBeginning);
      case msgType of
        wmtString:
        begin
          SetLength(str, outputStream.Size);
          outputStream.ReadBuffer(str[1], outputStream.Size);
          Message := TWebsocketStringMessage.Create(str);
        end;
        wmtBinary:
        begin
          SetLength(buffer, outputStream.Size);
          outputStream.ReadBuffer(buffer[0], outputStream.Size);
          Message := TWebsocketBinaryMessage.Create(buffer);
        end;
      end;
      AddMessageToList(Message);
    finally
      outputStream.Free;
    end;
  except
    On e: EWebsocketReadError do
    begin
      if e.Code = 0 then
      begin
        // Stream has been closed
        Close(True);
      end;
    end;
  end;
end;

function TWebsocketCommunincator.WriteMessage(MessageType: TWebsocketMessageType;
  MaxFrameLength: int64): TWebsocketMessageStream;
begin
  Result := TWebsocketMessageStream.Create(Self, MessageType,
    MaxFrameLength, generateMask);
end;

function TWebsocketCommunincator.GetUnprocessedMessages(
  const MsgList: TWebsocketMessageOwnerList): integer;
var
  lst: TWebsocketMessageList;
  m: TWebsocketMessage;
begin
  lst := FMessages.Lock;
  try
    Result := lst.Count;
    for m in lst do
      MsgList.Add(m);
    lst.Clear;
  finally
    FMessages.Unlock;
  end;
end;

{ TWebsocketMessageStream }

procedure TWebsocketMessageStream.WriteDataFrame(Finished: boolean);
var
  Header: TWebsocketFrameHeader;
  i: int64;
  MaskRec: TMaskRec;
  Stream: TSocketStream;
const
  // FIXME: check if this is the real unix code
  ConnectionIsDeadCode = {$IfDef UNIX}0{$ELSE}10053{$ENDIF};
begin
  try
    Stream := FCommunicator.SocketStream.LockWrite;
    try
      if not Assigned(Stream) then
      begin
        raise EWebsocketWriteError.Create('Stream already closed', 0);
      end;
      try
        Header.Fin := Finished;
        Header.Mask := (FMaskKey <> -1);
        if FFirstWrite then
          Header.OPCode := FMessageType
        else
          Header.OPCode := wmtContinue;
        // Compute size
        if FCurrentLen < 126 then
          Header.PayloadLen := FCurrentLen
        else if FCurrentLen <= word.MaxValue then
          Header.PayloadLen := 126
        else
          Header.PayloadLen := 127;
        // Write header
        Stream.WriteWord(FrameHEaderToWord(Header));
        // Write size if it exceeds 125
        if (FCurrentLen > 125) then
        begin
          if (FCurrentLen <= word.MaxValue) then
            Stream.WriteWord(htons(word(FCurrentLen)))
          else
            Stream.WriteQWord(htonll(QWord(FCurrentLen)));
        end;
        if Header.Mask then
        begin
          // If we use a mask
          MaskRec.Key := FMaskKey;
          // First: Transmit mask Key
          Stream.WriteBuffer(MaskRec.Bytes[0], 4);
          // 2. Encode Message
          // As this is 64 bit, to be 32 bit compatible we can't use a for loop
          i := 0;
          while i < FCurrentLen do
          begin
            FBuffer[i] := FBuffer[i] xor MaskRec.Bytes[i mod 4];
            Inc(i);
          end;
        end;
        // Write Message payload
        Stream.WriteBuffer(FBuffer[0], FCurrentLen);
        // Reset state for next data
        FCurrentLen := 0;
      except
        on E: EWriteError do
          raise EWebsocketWriteError.Create(e.Message, Stream.LastError);
      end;
    finally
      FCommunicator.SocketStream.UnlockWrite;
    end;
  except
    on E: EWebsocketWriteError do
    begin
      if E.Code = ConnectionIsDeadCode then
        FCommunicator.Close(True);
      raise;
    end;
  end;
end;

constructor TWebsocketMessageStream.Create(const ACommunicator: TWebsocketCommunincator;
  AMessageType: TWebsocketMessageType; AMaxFrameLen: int64; AMaskKey: integer);
begin
  FCommunicator := ACommunicator;
  FMaxFrameSize := AMaxFrameLen;
  FMessageType := AMessageType;
  SetLength(FBuffer, AMaxFrameLen);
  FCurrentLen := 0;
  FFirstWrite := True;
  FMaskKey := AMaskKey;
end;

destructor TWebsocketMessageStream.Destroy;
begin
  WriteDataFrame(True);
  inherited Destroy;
end;

function TWebsocketMessageStream.Seek(Offset: longint; Origin: word): longint;
begin
  // We cant seek
  Result := 0;
end;

function TWebsocketMessageStream.Read(var Buffer; Count: longint): longint;
begin
  // Write only stream
  Result := 0;
end;

function TWebsocketMessageStream.Write(const Buffer; Count: longint): longint;
var
  ToWrite: integer;
begin
  while FCurrentLen + Count > FMaxFrameSize do
  begin
    // Doesn't fit into one dataframe
    // So we split it up into multiple
    ToWrite := FMaxFrameSize - FCurrentLen;
    Move(Buffer, FBuffer[FCurrentLen], ToWrite);
    FCurrentLen := FMaxFrameSize;
    WriteDataFrame(False);
    // Now FCurrentLen should be 0 again
    // Only decrese the count
    Dec(Count, ToWrite);
  end;
  Move(Buffer, FBuffer[FCurrentLen], Count);
  FCurrentLen += Count;
  Result := Count;
end;


end.

