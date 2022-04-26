unit wsstream;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ssockets, wsmessages, wsutils, Sockets, base64, sha1;

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

  EUnsupportedMessageTypeException = class(Exception);

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

  TWebsocketCommunicator = class;

  { TWebsocketMessageStream }

  TWebsocketMessageStream = class(TStream)
  private
    FCommunicator: TWebsocketCommunicator;
    FMaxFrameSize: int64;
    FMessageType: TWebsocketMessageType;
    FBuffer: TBytes;
    FCurrentLen: int64;
    FFirstWrite: boolean;
    FDoMask: Boolean;

    function GenerateMask: Cardinal;
    procedure WriteDataFrame(Finished: boolean = False);
  public
    constructor Create(const ACommunicator: TWebsocketCommunicator;
      AMessageType: TWebsocketMessageType; AMaxFrameLen: int64;
  ADoMask: Boolean);
    destructor Destroy; override;
    function Seek(Offset: longint; Origin: word): longint; override;
    function Read(var Buffer; Count: longint): longint; override;
    function Write(const Buffer; Count: longint): longint; override;
  end;

  TLockedEvent = specialize TThreadedData<TNotifyEvent>;

  { TWebsocketCommunicator }

  TWebsocketCommunicator = class
  private
    FStream: TLockedSocketStream;
    FMessages: TLockedWebsocketMessageList;
    FMaskMessages: boolean;
    FAssumeMaskedMessages: boolean;
    FOnReceiveMessage: TLockedEvent;
    FOnClose: TLockedEvent;
    FExpectClose: boolean;
    FReceiveMessageThread: TThread;
    FCustomReceiveMessageThread: Boolean;
    function GetOnClose: TNotifyEvent;
    function GetOnReceiveMessage: TNotifyEvent;
    function GetOpen: boolean;
    procedure SetOnClose(AValue: TNotifyEvent);
    procedure SetOnReceiveMessage(AValue: TNotifyEvent);
  public
    procedure AddMessageToList(Message: TWebsocketMessage);
    constructor Create(AStream: TLockedSocketStream; AMaskMessage: boolean;
      AssumeMaskedMessages: boolean);
    destructor Destroy; override;

    procedure Close(ForceClose: boolean = False); virtual;

    function ReceiveMessage: TWebsocketMessage;
    function SetCustomReceiveMessageThread(CustomReceiveMessageThread: TThread): Boolean; inline;
    procedure StartReceiveMessageThread;
    procedure StopReceiveMessageThread; inline;
    function ReceiveMessageThreadRunning: Boolean; inline;
    function InReceiveMessageThread: Boolean; inline;
    function HasMessages: Boolean;
    function GetUnprocessedMessages(const MsgList: TWebsocketMessageOwnerList): integer;
    function WaitForMessage(MessageTypes: TWebsocketMessageTypes=[wmtString, wmtBinary, wmtPong]
      ): TWebsocketMessage;
    function WaitForStringMessage: TWebsocketStringMessage; inline;
    function WaitForBinaryMessage: TWebsocketBinaryMessage; inline;
    function WaitForPongMessage: TWebsocketPongMessage; inline;

    function WriteMessage(MessageType: TWebsocketMessageType = wmtString;
      MaxFrameLength: int64 = Word.MaxValue): TWebsocketMessageStream;
    procedure WriteRawMessage(const AMessage; ALength: SizeInt;
      AMessageType: TWebsocketMessageType = wmtString); inline;
    procedure WriteStringMessage(const AMessage: String); inline;
    procedure WriteBinaryMessage(const AMessage: TBytes); inline;

    property OnReceiveMessage: TNotifyEvent read GetOnReceiveMessage
      write SetOnReceiveMessage;
    property OnClose: TNotifyEvent read GetOnClose write SetOnClose;
    property SocketStream: TLockedSocketStream read FStream;
    property Open: boolean read GetOpen;
  end;

  { TReceiveMessageThread }

  TReceiveMessageThread = class(TThread)
  private
    FCommunicator: TWebsocketCommunicator;
  protected
    procedure Execute; override;
  public
    constructor Create(Communicator: TWebsocketCommunicator);
  end;
  
function GenerateAcceptingKey(const Key: string): string; inline;
implementation
const
  // Fixme check if it is really 0 on unix
  ConnectionRestCode = {$IfDef UNIX}0{$ELSE}10054{$ENDIF};
  ConnectionIsDeadCode = {$IfDef UNIX}0{$ELSE}10053{$ENDIF};

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

function ntohll(net: int64): int64; inline;
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
      False: (Key: Cardinal);
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

{ TReceiveMessageThread }

procedure TReceiveMessageThread.Execute;
var
  msg: TWebsocketMessage;
begin
  while not Terminated and FCommunicator.Open do
  begin
    msg := FCommunicator.ReceiveMessage;
    if Assigned(msg) then
      FCommunicator.AddMessageToList(msg);
    sleep(10);
  end;
  FCommunicator.FReceiveMessageThread := nil;
end;

constructor TReceiveMessageThread.Create(Communicator: TWebsocketCommunicator);
begin
  inherited Create(True);
  FCommunicator := Communicator;
  FreeOnTerminate := True;
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
  FRemoteAddress.Port := AStream.RemoteAddress.sin_port;
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

{ TWebsocketCommunicator }

function TWebsocketCommunicator.GetOpen: boolean;
begin
  Result := FStream.Open;
end;

function TWebsocketCommunicator.GetOnClose: TNotifyEvent;
begin
  try
    Result := FOnClose.Lock^;
  finally
    FOnClose.Unlock;
  end;
end;

function TWebsocketCommunicator.GetOnReceiveMessage: TNotifyEvent;
begin
  try
    Result := FOnReceiveMessage.Lock^;
  finally
    FOnReceiveMessage.Unlock;
  end;
end;

procedure TWebsocketCommunicator.SetOnClose(AValue: TNotifyEvent);
begin
  try
    FOnClose.Lock^ := AValue;
  finally
    FOnClose.Unlock;
  end;
end;

procedure TWebsocketCommunicator.SetOnReceiveMessage(AValue: TNotifyEvent);
begin
  try
    FOnReceiveMessage.Lock^ := AValue;
  finally
    FOnReceiveMessage.Unlock;
  end;
end;

procedure TWebsocketCommunicator.AddMessageToList(Message: TWebsocketMessage);
var
  lst: TWebsocketMessageList;
  OnReceiveMessageEvent: TNotifyEvent;
begin
  if Assigned(Message) then
  begin
    lst := FMessages.Lock;
    try
      lst.Add(Message);
    finally
      FMessages.Unlock;
    end;
    OnReceiveMessageEvent := OnReceiveMessage;
    if Assigned(OnReceiveMessageEvent) then
    begin
      OnReceiveMessageEvent(Self);
    end;
  end;
end;

constructor TWebsocketCommunicator.Create(AStream: TLockedSocketStream;
  AMaskMessage: boolean; AssumeMaskedMessages: boolean);
begin
  FStream := AStream;
  FMaskMessages := AMaskMessage;
  FAssumeMaskedMessages := AssumeMaskedMessages;
  FMessages := TLockedWebsocketMessageList.Create(TWebsocketMessageList.Create);
  FOnReceiveMessage.Init(nil);
  FOnClose.Init(nil);
  FExpectClose := False;
end;

destructor TWebsocketCommunicator.Destroy;
begin
  // Ending communication => Close stream
  Close(True);
  FStream.Free;
  FMessages.Free;
  FOnReceiveMessage.Done;
  FOnClose.Done;
  inherited Destroy;
end;

procedure TWebsocketCommunicator.Close(ForceClose: boolean);
var
  OnCloseEvent: TNotifyEvent;
begin
  if not Open then
    Exit;
  if not ForceClose then
  begin
    WriteMessage(wmtClose).Free;
    FExpectClose := True;
    Exit;
  end;
  OnCloseEvent := OnClose;
  if Assigned(OnCloseEvent) then
    OnCloseEvent(Self);
  FStream.CloseStream;
end;

function TWebsocketCommunicator.ReceiveMessage: TWebsocketMessage;

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
            if (Stream.LastError <> IOTimeoutError) and (Stream.LastError <> 0) then
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
        // Close the stream (true to not send a message)
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
  outputStream: TMemoryStream;
  messageType: TWebsocketMessageType;
  msgType: TWebsocketMessageType;
  str: UTF8String;
  w: word;
begin
  Result := nil;
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
          Result := TWebsocketStringMessage.Create(str);
        end;
        wmtBinary:
        begin
          SetLength(buffer, outputStream.Size);
          outputStream.ReadBuffer(buffer[0], outputStream.Size);
          Result := TWebsocketBinaryMessage.Create(buffer);
        end;
      end;
    finally
      outputStream.Free;
    end;
  except
    On e: EWebsocketReadError do
    begin
      if (e.Code = 0) or (e.Code = ConnectionIsDeadCode) or
         (e.Code = ConnectionRestCode) then
      begin
        // Stream has been closed
        Close(True);
      end;
    end;
  end;
end;

function TWebsocketCommunicator.SetCustomReceiveMessageThread(
  CustomReceiveMessageThread: TThread): Boolean;
begin
  Result := not (Assigned(FReceiveMessageThread) and Assigned(CustomReceiveMessageThread));
  FCustomReceiveMessageThread := True;
  if Result then
    FReceiveMessageThread := CustomReceiveMessageThread;
end;

procedure TWebsocketCommunicator.StartReceiveMessageThread;
begin
  if not Assigned(FReceiveMessageThread) then
  begin
    FCustomReceiveMessageThread := False;;
    FReceiveMessageThread := TReceiveMessageThread.Create(Self);
    FReceiveMessageThread.Start;
  end;
end;

procedure TWebsocketCommunicator.StopReceiveMessageThread;
begin
  if Assigned(FReceiveMessageThread) then
  begin
    if FCustomReceiveMessageThread then
      raise EInvalidOperation.Create('Can''t stop a custom receive message thread. Stop it yourself!');
    FReceiveMessageThread.Terminate;
  end;
end;

function TWebsocketCommunicator.ReceiveMessageThreadRunning: Boolean;
begin
  Result := Assigned(FReceiveMessageThread);
end;

function TWebsocketCommunicator.InReceiveMessageThread: Boolean;
begin
  Result := ReceiveMessageThreadRunning and (TThread.CurrentThread.ThreadID = FReceiveMessageThread.ThreadID);
end;

function TWebsocketCommunicator.HasMessages: Boolean;
begin
  try
    Result := FMessages.Lock.Count > 0;
  finally
    FMessages.Unlock;
  end;
end;

function TWebsocketCommunicator.WriteMessage(MessageType: TWebsocketMessageType;
  MaxFrameLength: int64): TWebsocketMessageStream;
begin
  Result := TWebsocketMessageStream.Create(Self, MessageType,
    MaxFrameLength, FMaskMessages);
end;

procedure TWebsocketCommunicator.WriteRawMessage(const AMessage;
  ALength: SizeInt; AMessageType: TWebsocketMessageType);
begin
  with WriteMessage(AMessageType, ALength) do
  try
    Write(AMessage, ALength);
  finally
    Free;
  end;
end;

procedure TWebsocketCommunicator.WriteStringMessage(const AMessage: String);
begin
  WriteRawMessage(AMessage[1], AMessage.Length);
end;

procedure TWebsocketCommunicator.WriteBinaryMessage(const AMessage: TBytes);
begin
  WriteRawMessage(AMessage[0], Length(AMessage), wmtBinary);
end;

function TWebsocketCommunicator.GetUnprocessedMessages(
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

function TWebsocketCommunicator.WaitForMessage(
  MessageTypes: TWebsocketMessageTypes): TWebsocketMessage;
var
  oldEvent: TNotifyEvent;
  msg: TWebsocketMessage;
  MsgList: TWebsocketMessageList;
  i: SizeInt;
  MessageType: TWebsocketMessageType;
begin
  for MessageType in MessageTypes do
    if not (MessageType in [wmtString, wmtBinary, wmtPong]) then
      raise EUnsupportedMessageTypeException.Create('Can only wait for String, Binary or Pong messages');
  Result := nil;
  oldEvent := OnReceiveMessage;
  OnReceiveMessage := nil;
  try
    while Open and not Assigned(Result) do
    begin
      if ReceiveMessageThreadRunning then
        Sleep(100) // wait for messages on different thread
      else
      begin // else receive message
        msg := ReceiveMessage;
        if Assigned(msg) then
          AddMessageToList(msg);
      end;
      // now check message queue
      MsgList := FMessages.Lock;
      try
        for i:=0 to MsgList.Count-1 do
        begin
          msg := MsgList[i];
          if msg.MessageType in MessageTypes then
          begin
            MsgList.Delete(i);
            Result := msg;
          end;
        end;
      finally
        FMessages.Unlock;
      end;
    end;
  finally
    OnReceiveMessage := oldEvent; 
    // if other messages where received, call the event
    // note there is a slim chance that between these lines, a message was received,
    // so the event will be fired twice. But handling this with critical sections
    // may introduce deadlocks when trying to receive messages within the handler
    // so it seems more reasonable to have the user ignore empty events
    if HasMessages and Assigned(oldEvent) then
      oldEvent(Self);
  end;
end;

function TWebsocketCommunicator.WaitForStringMessage: TWebsocketStringMessage;
begin
  Result := WaitForMessage([wmtString]) as TWebsocketStringMessage;
end;

function TWebsocketCommunicator.WaitForBinaryMessage: TWebsocketBinaryMessage;
begin
  Result := WaitForMessage([wmtBinary]) as TWebsocketBinaryMessage;
end;

function TWebsocketCommunicator.WaitForPongMessage: TWebsocketPongMessage;
begin
  Result := WaitForMessage([wmtPong]) as TWebsocketPongMessage;
end;

{ TWebsocketMessageStream }

function TWebsocketMessageStream.GenerateMask: Cardinal;
begin
  Result := Random(Cardinal.MaxValue + 1);
end;

procedure TWebsocketMessageStream.WriteDataFrame(Finished: boolean);
var
  Header: TWebsocketFrameHeader;
  i: int64;
  MaskRec: TMaskRec;
  Stream: TSocketStream;
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
        Header.Mask := FDoMask;
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
          MaskRec.Key := generateMask;
          // First: Transmit mask Key
          Stream.WriteBuffer(MaskRec.Key, SizeOf(MaskRec.Key));
          // 2. Encode Message
          // As this is 64 bit, to be 32 bit compatible we can't use a for loop
          i := 0;
          while i < FCurrentLen do
          begin
            FBuffer[i] := FBuffer[i] xor MaskRec.Bytes[i mod 4];
            Inc(i);
          end;
        end;
        if FCurrentLen > 0 then
        begin
          // Write Message payload
          Stream.WriteBuffer(FBuffer[0], FCurrentLen);
        end;
        // Reset state for next data
        FCurrentLen := 0;
      except
        on E: EWriteError do
          raise EWebsocketWriteError.Create(e.Message, Stream.LastError);
      end;
    finally
      FCommunicator.SocketStream.UnlockWrite;
    end;
    if Finished and (FMessageType = wmtClose) then
      FCommunicator.FExpectClose := True;
  except
    on E: EWebsocketWriteError do
    begin
      if (e.Code = 0) or (e.Code = ConnectionIsDeadCode) or
         (e.Code = ConnectionRestCode) then
        FCommunicator.Close(True);
      raise;
    end;
  end;
end;

constructor TWebsocketMessageStream.Create(
  const ACommunicator: TWebsocketCommunicator;
  AMessageType: TWebsocketMessageType; AMaxFrameLen: int64; ADoMask: Boolean);
begin
  FCommunicator := ACommunicator;
  FMaxFrameSize := AMaxFrameLen;
  FMessageType := AMessageType;
  SetLength(FBuffer, AMaxFrameLen);
  FCurrentLen := 0;
  FFirstWrite := True;
  FDoMask := ADoMask;
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
  // FIXME: Result is longint but FMaxFrameSize is int64, so technically this
  // function does not fully support 64 bit messages
  Result := 0;
  while FCurrentLen + Count > FMaxFrameSize do
  begin
    // Doesn't fit into one dataframe
    // So we split it up into multiple
    ToWrite := FMaxFrameSize - FCurrentLen;
    Move(PByte(@Buffer)[Result], FBuffer[FCurrentLen], ToWrite);
    FCurrentLen := FMaxFrameSize;
    WriteDataFrame(False);
    // Now FCurrentLen should be 0 again
    // Only decrese the count
    Dec(Count, ToWrite);
    Inc(Result, ToWrite);
  end;
  Move(PByte(@Buffer)[Result], FBuffer[FCurrentLen], Count);
  FCurrentLen += Count;
  Inc(Result, Count);
end;

function GenerateAcceptingKey(const Key: string): string; inline;
var
  concatKey: string;
  keyHash: TSHA1Digest;
  OutputStream: TStringStream;
  b64Encoder: TBase64EncodingStream;
const
  WebsocketMagicString = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
begin
  // Key = Base64(SHA1(Key + MagicString))
  concatKey := Key + WebsocketMagicString;
  keyHash := SHA1String(concatKey);
  OutputStream := TStringStream.Create('');
  try
    b64Encoder := TBase64EncodingStream.Create(OutputStream);
    try
      b64Encoder.WriteBuffer(keyHash[low(keyHash)], Length(keyHash));
      b64Encoder.Flush;
      Result := OutputStream.DataString;
    finally
      b64Encoder.Free;
    end;
  finally
    OutputStream.Free;
  end;
end;

initialization
  Randomize;

end.

