unit WebSocket;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ssockets, fgl, sha1, base64, utilities, Sockets;

type
  { TRequestHeaders }

  TRequestHeaders = class(specialize TFPGMap<string, string>)
  public
    procedure Parse(const HeaderString: string);
    constructor Create;
  end;

  TRequestData = record
    Host: string;
    Path: string;
    Key: string;
    Headers: TRequestHeaders;
  end;

  // Represent opcodes
  TWebsocketMessageType = (wmtContinue = 0, wmtString = 1, wmtBinary =
    2, wmtClose = 8, wmtPing = 9, wmtPong = 10);

  { TWebsocketMessage }

  TWebsocketMessage = class
  private
    FMessageType: TWebsocketMessageType;
  public
    constructor Create(const AMessageType: TWebsocketMessageType);
    property MessageType: TWebsocketMessageType read FMessageType;
  end;

  { TWebsocketStringMessage }

  TWebsocketStringMessage = class(TWebsocketMessage)
  private
    FData: UTF8String;
  public
    constructor Create(const AData: UTF8String);
    property Data: UTF8String read FData;
  end;

  { TWebsocketStringMessage }

  { TWebsocketPongMessage }

  TWebsocketPongMessage = class(TWebsocketMessage)
  private
    FData: UTF8String;
  public
    constructor Create(const AData: UTF8String);
    property Data: UTF8String read FData;
  end;

  { TWebsocketBinaryMessage }

  TWebsocketBinaryMessage = class(TWebsocketMessage)
  private
    FData: TBytes;
  public
    constructor Create(const AData: TBytes);
    property Data: TBytes read FData;
  end;

  TWebsocketMessageList = class(specialize TFPGList<TWebsocketMessage>);
  TWebsocketMessageOwnerList = class(specialize TFPGObjectList<TWebsocketMessage>);
  TLockedWebsocketMessageList = class(specialize TThreadedObject<TWebsocketMessageList>);

  { TWebsocketMessageStream }

  TWebsocketMessageStream = class(TStream)
  private
    FDataStream: TSocketStream;
    FMaxFrameSize: int64;
    FMessageType: TWebsocketMessageType;
    FBuffer: TBytes;
    FCurrentLen: int64;
    FFirstWrite: boolean;
    FMaskKey: integer;

    procedure WriteDataFrame(Finished: boolean = False);
  public
    constructor Create(const ADataStream: TSocketStream;
      AMessageType: TWebsocketMessageType = wmtString;
      AMaxFrameLen: int64 = 125; AMaskKey: integer = -1);
    destructor Destroy; override;
    function Seek(Offset: longint; Origin: word): longint; override;
    function Read(var Buffer; Count: longint): longint; override;
    function Write(const Buffer; Count: longint): longint; override;
  end;

  { TWebsocketCommunincator }

  TWebsocketCommunincator = class
  private
    FStream: TSocketStream;
    FMessages: TLockedWebsocketMessageList;
    FMaskMessages: boolean;
    FAssumeMaskedMessages: boolean;
    FOnRecieveMessage: TNotifyEvent;
    FOnClose: TNotifyEvent;
    FOpen: boolean;
    FExpectClose: boolean;
    function GenerateMask: integer;
  public
    constructor Create(AStream: TSocketStream; AMaskMessage: boolean;
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
    property SocketStream: TSocketStream read FStream;
    property Open: boolean read FOpen;
  end;

  { TWebsocketHandler }

  TWebsocketHandler = class
  public
    function Accept(const ARequest: TRequestData;
      const ResponseHeaders: TStrings): boolean; virtual;
    procedure HandleCommunication(ACommunicator: TWebsocketCommunincator); virtual;
  end;

  TThreadedWebsocketHandler = class(TWebsocketHandler)
  public
    procedure HandleCommunication(ACommunicator: TWebsocketCommunincator); override;
    procedure DoHandleCommunication(ACommunication: TWebsocketCommunincator); virtual;
  end;


  { THostHandler }

  THostHandler = class(specialize TStringObjectMap<TWebsocketHandler>)
  private
    FHost: string;
  public
    constructor Create(const AHost: string; FreeObjects: boolean);
    property Host: string read FHost;
  end;

  { THostMap }

  THostMap = class(specialize TStringObjectMap<THostHandler>)
  public
    constructor Create;
    procedure AddHost(const AHost: THostHandler);
  end;

  { TLockedHostMap }

  TLockedHostMap = class(specialize TThreadedObject<THostMap>)
  public
    constructor Create;
  end;

  TServerAcceptingMethod = (samDefault, samThreaded, samThreadPool);

  { TWebSocketServer }

  TWebSocketServer = class
  private
    FSocket: TInetServer;
    FHostMap: TLockedHostMap;
    FFreeHandlers: boolean;
    FAcceptingMethod: TServerAcceptingMethod;

    procedure DoCreate;
    procedure HandleConnect(Sender: TObject; Data: TSocketStream);
  public
    procedure Start;
    procedure Stop(DoAbort: boolean = False);

    procedure RegisterHandler(const AHost: string; const APath: string;
      AHandler: TWebsocketHandler; DefaultHost: boolean = False;
      DefaultPath: boolean = False);

    destructor Destroy; override;
    constructor Create(const AHost: string; const APort: word;
      AHandler: TSocketHandler);
    constructor Create(const APort: word);
    property Socket: TInetServer read FSocket;
    property FreeHandlers: boolean read FFreeHandlers write FFreeHandlers;
    property AcceptingMethod: TServerAcceptingMethod
      read FAcceptingMethod write FAcceptingMethod;
  end;

const
  MalformedRequestMessage =
    'HTTP/1.1 400 Bad Request'#13#10#13#10'Not a Websocket Request';
  ForbiddenRequestMessage =
    'HTTP/1.1 403 Forbidden'#13#10#13#10'Request not accepted by Handler';
  HandlerNotFoundMessage = 'HTTP/1.1 404 Not Found'#13#10#13#10'No Handler registered for this request';


implementation

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

type

  {Thread Types}
  { TWebsocketHandlerThread }

  TWebsocketHandlerThread = class(TPoolableThread)
  private
    FCommunicator: TWebsocketCommunincator;
    FHandler: TThreadedWebsocketHandler;
  protected
    procedure DoExecute; override;
    property Handler: TThreadedWebsocketHandler read FHandler write FHandler;
    property Communicator: TWebsocketCommunincator
      read FCommunicator write FCommunicator;
  end;

  THandlerThreadFactory = specialize TPoolableThreadFactory<TWebsocketHandlerThread>;
  THandlerThreadPool = specialize TObjectPool<TWebsocketHandlerThread,
    THandlerThreadFactory, THandlerThreadFactory>;
  TLockedHandlerThreadPool = specialize TThreadedObject<THandlerThreadPool>;

  { TWebsocketRecieverThread }

  TWebsocketRecieverThread = class(TPoolableThread)
  private
    FCommunicator: TWebsocketCommunincator;
    FStopped: boolean;
  protected
    procedure DoExecute; override;
    procedure Kill;
    property Communicator: TWebsocketCommunincator
      read FCommunicator write FCommunicator;
  end;

  TRecieverThreadFactory = specialize TPoolableThreadFactory<TWebsocketRecieverThread>;
  TRecieverThreadPool = specialize TObjectPool<TWebsocketRecieverThread,
    TRecieverThreadFactory, TRecieverThreadFactory>;
  TLockedRecieverThreadPool = specialize TThreadedObject<TRecieverThreadPool>;

  { TWebsocketHandshakeHandler }

  TWebsocketHandshakeHandler = class
  private
    FStream: TSocketStream;
    FHostMap: TLockedHostMap;
    function ReadRequest(var RequestData: TRequestData): boolean;
    function GenerateAcceptingKey(const Key: string): string;
  public
    procedure PerformHandshake;
    constructor Create(AStream: TSocketStream; AHostMap: TLockedHostMap);
  end;

  { TAcceptingThread }

  TAcceptingThread = class(TPoolableThread)
  private
    FHandshakeHandler: TWebsocketHandshakeHandler;
  protected
    procedure DoExecute; override;

    property HandshakeHandler: TWebsocketHandshakeHandler
      read FHandshakeHandler write FHandshakeHandler;
  end;

  TAcceptingThreadFactory = specialize TPoolableThreadFactory<TAcceptingThread>;
  TAcceptingThreadPool = specialize TObjectPool<TAcceptingThread,
    TAcceptingThreadFactory, TAcceptingThreadFactory>;
  TLockedAcceptingThreadPool = specialize TThreadedObject<TAcceptingThreadPool>;

var
  RecieverThreadPool: TLockedRecieverThreadPool;
  HandlerThreadPool: TLockedHandlerThreadPool;
  AcceptingThreadPool: TLockedAcceptingThreadPool;

function CreateAcceptingThread(const AHandshakeHandler: TWebsocketHandshakeHandler):
TAcceptingThread; inline;
var
  pool: TAcceptingThreadPool;
begin
  pool := AcceptingThreadPool.Lock;
  try
    Result := pool.GetObject;
    Result.HandshakeHandler := AHandshakeHandler;
    Result.Restart;
  finally
    AcceptingThreadPool.Unlock;
  end;
end;

function CreateHandlerThread(const ACommunicator: TWebsocketCommunincator;
  const AHandler: TThreadedWebsocketHandler): TWebsocketHandlerThread; inline;
var
  pool: THandlerThreadPool;
begin
  pool := HandlerThreadPool.Lock;
  try
    Result := pool.GetObject;
    Result.Communicator := ACommunicator;
    Result.Handler := AHandler;
    Result.Restart;
  finally
    HandlerThreadPool.Unlock;
  end;
end;

function CreateRecieverThread(
  const ACommunicator: TWebsocketCommunincator): TWebsocketRecieverThread; inline;
var
  pool: TRecieverThreadPool;
begin
  pool := RecieverThreadPool.Lock;
  try
    Result := pool.GetObject;
    Result.Communicator := ACommunicator;
    Result.Restart;
  finally
    RecieverThreadPool.Unlock;
  end;
end;

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

{ TRequestHeaders }

function DoHeaderKeyCompare(const Key1, Key2: string): integer;
begin
  // Headers are case insensetive
  Result := CompareStr(Key1.ToLower, Key2.ToLower);
end;

procedure TAcceptingThread.DoExecute;
begin
  FHandshakeHandler.PerformHandshake;
end;

{ TWebsocketHandlerThread }

procedure TWebsocketHandlerThread.DoExecute;
var
  Recv: TWebsocketRecieverThread;
begin
  Recv := CreateRecieverThread(FCommunicator);
  try
    try
      FHandler.DoHandleCommunication(FCommunicator);
    finally
      FCommunicator.Close;
      FCommunicator.Free;
    end;
  finally
    Recv.Kill;
  end;
end;

{ TWebsocketRecieverThread }

procedure TWebsocketRecieverThread.DoExecute;
begin
  FStopped := False;
  while not Terminated and not FStopped and FCommunicator.Open do
  begin
    FCommunicator.RecieveMessage;
    Yield;
  end;
end;

procedure TWebsocketRecieverThread.Kill;
begin
  FStopped := True;
end;

{ TWebsocketCommunincator }

function TWebsocketCommunincator.GenerateMask: integer;
begin
  Result := -1;
  if FMaskMessages then // Not really secure...
    Result := integer(Random(DWord.MaxValue));
end;

constructor TWebsocketCommunincator.Create(AStream: TSocketStream;
  AMaskMessage: boolean; AssumeMaskedMessages: boolean);
begin
  FStream := AStream;
  FMaskMessages := AMaskMessage;
  FAssumeMaskedMessages := AssumeMaskedMessages;
  FMessages := TLockedWebsocketMessageList.Create(TWebsocketMessageList.Create);
  FOpen := True;
  FExpectClose := False;
end;

destructor TWebsocketCommunincator.Destroy;
begin
  // Ending communication => Close stream
  Close(True);
  FMessages.Free;
  inherited Destroy;
end;

procedure TWebsocketCommunincator.Close(ForceClose: boolean);
begin
  if not FOpen then
    Exit;
  if not ForceClose then
  begin
    WriteMessage(wmtClose).Free;
    FExpectClose := True;
    Exit;
  end;
  FOpen := False;
  if Assigned(FOnClose) then
    FOnClose(Self);
  FStream.Free;
end;

procedure TWebsocketCommunincator.RecieveMessage;

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

var
  Header: TWebsocketFrameHeader;
  len: int64;
  MaskRec: TMaskRec;
  buffer: TBytes;
  i: int64;
  Message: TWebsocketMessage;
  outputStream: TMemoryStream;
  messageType: TWebsocketMessageType;
  str: UTF8String;
begin
  Message := nil;
  outputStream := TMemoryStream.Create;
  try
    try
      repeat
        if not Open then
          Exit;
        Header := WordToFrameHeader(FStream.ReadWord);
        if Header.OPCode <> wmtContinue then
          messageType := TWebsocketMessageType(Header.OPCode);
        if Header.PayloadLen < 126 then
          len := Header.PayloadLen
        else if Header.PayloadLen = 126 then
          len := NToHs(FStream.ReadWord)
        else
          len := ntohll(FStream.ReadQWord);
        if Header.Mask then
        begin
          MaskRec.Key := integer(FStream.ReadDWord);
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
          FStream.ReadBuffer(buffer[0], len);
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
                if len > 0 then
                  Write(buffer[0], len);
              finally
                Free;
              end;
          end;
          wmtPong:
          begin
            // lift pong message to message queue, so user can handle it
            SetLength(str, len);
            if len > 0 then
              Move(buffer[0], str[1], len);
            AddMessageToList(TWebsocketPongMessage.Create(str));
          end;
          else
          begin
            // This is a dataframe, so save data for concatination of fragments
            if len > 0 then
              outputStream.WriteBuffer(buffer[0], len);
          end;
        end;
      until Header.Fin;
      // Read whole message
      outputStream.Seek(0, soBeginning);
      case messageType of
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
    On e: EReadError do
    begin
      // Stream has been closed
      // FIXME: Some way to verify that?
      Close(True);
    end;
  end;
end;

function TWebsocketCommunincator.WriteMessage(MessageType: TWebsocketMessageType;
  MaxFrameLength: int64): TWebsocketMessageStream;
begin
  Result := TWebsocketMessageStream.Create(FStream, MessageType,
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
begin
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
  FDataStream.WriteWord(FrameHEaderToWord(Header));
  // Write size if it exceeds 125
  if (FCurrentLen > 125) then
  begin
    if (FCurrentLen <= word.MaxValue) then
      FDataStream.WriteWord(htons(word(FCurrentLen)))
    else
      FDataStream.WriteQWord(htonll(QWord(FCurrentLen)));
  end;
  if Header.Mask then
  begin
    // If we use a mask
    MaskRec.Key := FMaskKey;
    // First: Transmit mask Key
    FDataStream.WriteBuffer(MaskRec.Bytes[0], 4);
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
  FDataStream.WriteBuffer(FBuffer[0], FCurrentLen);
  // Reset state for next data
  FCurrentLen := 0;
end;

constructor TWebsocketMessageStream.Create(const ADataStream: TSocketStream;
  AMessageType: TWebsocketMessageType; AMaxFrameLen: int64; AMaskKey: integer);
begin
  FDataStream := ADataStream;
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

{ TWebsocketMessage }

constructor TWebsocketMessage.Create(const AMessageType: TWebsocketMessageType);
begin
  FMessageType := AMessageType;
end;

{ TWebsocketStringMessage }

constructor TWebsocketStringMessage.Create(const AData: UTF8String);
begin
  inherited Create(wmtString);
  FData := AData;
  SetLength(FData, Length(FData));
end;

{ TWebsocketPongMessage }

constructor TWebsocketPongMessage.Create(const AData: UTF8String);
begin
  inherited Create(wmtPong);
  FData := AData;
  SetLength(FData, Length(FData));
end;

{ TWebsocketBinaryMessage }

constructor TWebsocketBinaryMessage.Create(const AData: TBytes);
begin
  inherited Create(wmtBinary);
  FData := AData;
  SetLength(FData, Length(FData));
end;

{ THostHandler }

constructor THostHandler.Create(const AHost: string; FreeObjects: boolean);
begin
  FHost := AHost;
  inherited Create(FreeObjects);
end;

{ TWebsocketHandler }

function TWebsocketHandler.Accept(const ARequest: TRequestData;
  const ResponseHeaders: TStrings): boolean;
begin
  Result := True;
end;

procedure TWebsocketHandler.HandleCommunication(
  ACommunicator: TWebsocketCommunincator);
begin
  // No implementation; To be overriden
end;

procedure TThreadedWebsocketHandler.HandleCommunication(
  ACommunicator: TWebsocketCommunincator);
begin
  CreateHandlerThread(ACommunicator, Self);
end;

procedure TThreadedWebsocketHandler.DoHandleCommunication(
  ACommunication: TWebsocketCommunincator);
begin
  // No implementation; To be overriden
end;

{ THostMap }

constructor THostMap.Create;
begin
  inherited Create(True);
end;

procedure THostMap.AddHost(const AHost: THostHandler);
begin
  Objects[AHost.FHost] := AHost;
end;

{ TLockedHostMap }

constructor TLockedHostMap.Create;
begin
  inherited Create(THostMap.Create);
end;

procedure TRequestHeaders.Parse(const HeaderString: string);
var
  sl: TStringList;
  s: string;
  p: integer;
begin
  sl := TStringList.Create;
  try
    sl.TextLineBreakStyle := tlbsCRLF;
    sl.Text := HeaderString;
    for s in sl do
    begin
      // Use sl.Values instead?
      p := s.IndexOf(':');
      if p > 0 then
        Self.KeyData[s.Substring(0, p).ToLower] := s.Substring(p + 1).Trim;
    end;
  finally
    sl.Free;
  end;
end;

constructor TRequestHeaders.Create;
begin
  inherited Create;
  Self.OnKeyCompare := @DoHeaderKeyCompare;
  // Binary search => faster access
  Self.Sorted := True;
end;

{ TWebsocketHandshakeHandler }

function TWebsocketHandshakeHandler.ReadRequest(var RequestData: TRequestData): boolean;
var
  method: string;
  proto: string;
  headerstr: string;
  upg: string;
  conn: string;
  version: string;
begin
  Result := False;
  // Check if this is HTTP by checking the first line
  // Method GET is required
  SetLength(method, 4);
  FStream.ReadBuffer(method[1], 4);
  if method <> 'GET ' then
  begin
    // Not GET
    Exit;
  end;
  // Read path and HTTP version
  FStream.ReadTo(' ', RequestData.Path);
  FStream.ReadTo(#13#10, proto, 10);
  RequestData.Path := RequestData.Path.TrimRight;
  proto := proto.TrimRight.ToLower;
  if not proto.StartsWith('http/') then
  begin
    // Only accept http/1.1
    Exit;
  end;
  if not proto.EndsWith('1.1') then
  begin
    // non 1.1 version: return forbidden
    Exit;
  end;
  // Headers are separated by 2 newlines (CR+LF)
  FStream.ReadTo(#13#10#13#10, headerstr, 2048);
  RequestData.Headers.Parse(headerstr.Trim);
  if not (RequestData.Headers.TryGetData('Upgrade', upg) and
    RequestData.Headers.TryGetData('Connection', conn) and
    RequestData.Headers.TryGetData('Sec-WebSocket-Key', RequestData.Key) and
    (upg = 'websocket') and (conn.Contains('Upgrade'))) then
  begin
    // Seems to be a normal HTTP request, we only handle websockets
    Exit;
  end;
  // How to handle this?
  if not RequestData.Headers.TryGetData('Sec-WebSocket-Version', version) then
    version := '';
  if not RequestData.Headers.TryGetData('Host', RequestData.Host) then
    RequestData.Host := '';
  Result := True;
end;

function TWebsocketHandshakeHandler.GenerateAcceptingKey(const Key: string): string;
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

procedure TWebsocketHandshakeHandler.PerformHandshake;
var
  RequestData: TRequestData;
  hm: THostMap;
  hh: THostHandler;
  sh: TWebsocketHandler;
  ResponseHeaders: TStringList;
  i: integer;
  HandsakeResponse: TStringList;
  Comm: TWebsocketCommunincator;
begin
  try
    RequestData.Headers := TRequestHeaders.Create;
    try
      // Reqding request
      try
        if not ReadRequest(RequestData) then
        begin
          FStream.WriteRaw(MalformedRequestMessage);
          FStream.Free;
          Exit;
        end;
      except
        on E: EReadError do
        begin
          FStream.WriteRaw(MalformedRequestMessage);
          FStream.Free;
          Exit;
        end;
      end;
      // Getting responsible handler
      hm := FHostMap.Lock;
      try
        hh := hm.Objects[RequestData.Host];
        if not Assigned(hh) then
        begin
          FStream.WriteRaw(HandlerNotFoundMessage);
          FStream.Free;
          Exit;
        end;
        sh := hh.Objects[RequestData.Path];
        if not Assigned(sh) then
        begin
          FStream.WriteRaw(HandlerNotFoundMessage);
          FStream.Free;
          Exit;
        end;
      finally
        FHostMap.Unlock;
      end;
      // Checking if handler wants to accept
      ResponseHeaders := TStringList.Create;
      try
        ResponseHeaders.NameValueSeparator := ':';
        if not sh.Accept(RequestData, ResponseHeaders) then
        begin
          FStream.WriteRaw(ForbiddenRequestMessage);
          FStream.Free;
          Exit;
        end;
        // Neseccary headers
        ResponseHeaders.Values['Connection'] := 'Upgrade';
        ResponseHeaders.Values['Upgrade'] := 'websocket';
        ResponseHeaders.Values['Sec-WebSocket-Accept'] :=
          GenerateAcceptingKey(RequestData.Key);
        // Generating response
        HandsakeResponse := TStringList.Create;
        try
          HandsakeResponse.TextLineBreakStyle := tlbsCRLF;
          HandsakeResponse.Add('HTTP/1.1 101 Switching Protocols');
          for i := 0 to ResponseHeaders.Count - 1 do
            HandsakeResponse.Add('%s: %s'.Format([ResponseHeaders.Names[i],
              ResponseHeaders.ValueFromIndex[i]]));
          HandsakeResponse.Add('');

          FStream.WriteRaw(HandsakeResponse.Text);
        finally
          HandsakeResponse.Free;
        end;
      finally
        ResponseHeaders.Free;
      end;
    finally
      RequestData.Headers.Free;
    end;
    Comm := TWebsocketCommunincator.Create(FStream, False, True);
  finally
    // Not needed anymore, we can now die in piece.
    // All information requier for the rest is now on the stack
    Self.Free;
  end;
  sh.HandleCommunication(Comm);
end;

constructor TWebsocketHandshakeHandler.Create(AStream: TSocketStream;
  AHostMap: TLockedHostMap);
begin
  FHostMap := AHostMap;
  FStream := AStream;
end;

{ TWebSocketServer }

procedure TWebSocketServer.DoCreate;
begin
  FSocket.OnConnect := @HandleConnect;
  FHostMap := TLockedHostMap.Create;
  FFreeHandlers := True;
  FAcceptingMethod := samDefault;
end;

procedure TWebSocketServer.HandleConnect(Sender: TObject; Data: TSocketStream);
var
  HandshakeHandler: TWebsocketHandshakeHandler;
  t: TAcceptingThread;
begin
  HandshakeHandler := TWebsocketHandshakeHandler.Create(Data, FHostMap);
  case AcceptingMethod of
    samDefault:
      HandshakeHandler.PerformHandshake;
    samThreaded:
    begin
      t := TAcceptingThread.Create(True);
      t.DoTerminate := True;
      t.FreeOnTerminate := True;
      t.HandshakeHandler := HandshakeHandler;
      t.Restart;
    end;
    samThreadPool:
      CreateAcceptingThread(HandshakeHandler);
  end;
end;

procedure TWebSocketServer.Start;
begin
  FSocket.StartAccepting;
end;

procedure TWebSocketServer.Stop(DoAbort: boolean);
begin
  FSocket.StopAccepting(DoAbort);
end;

procedure TWebSocketServer.RegisterHandler(const AHost: string;
  const APath: string; AHandler: TWebsocketHandler; DefaultHost: boolean;
  DefaultPath: boolean);
var
  map: THostMap;
  hh: THostHandler;
begin
  map := FHostMap.Lock;
  try
    if not map.TryGetObject(AHost, hh) then
    begin
      hh := THostHandler.Create(AHost, FFreeHandlers);
      map.AddHost(hh);
    end;
    if DefaultHost then
      map.DefaultObject := hh;
    hh[APath] := AHandler;
    if DefaultPath then
      hh.DefaultObject := AHandler;
  finally
    FHostMap.Unlock;
  end;
end;

destructor TWebSocketServer.Destroy;
begin
  Stop(True);
  FSocket.Free;
  FHostMap.Free;
  inherited Destroy;
end;

constructor TWebSocketServer.Create(const AHost: string; const APort: word;
  AHandler: TSocketHandler);
begin
  FSocket := TInetServer.Create(AHost, APort, AHandler);
  DoCreate;
end;

constructor TWebSocketServer.Create(const APort: word);
begin
  FSocket := TInetServer.Create(APort);
  DoCreate;
end;

initialization
  AcceptingThreadPool := TLockedAcceptingThreadPool.Create(TAcceptingThreadPool.Create);
  HandlerThreadPool := TLockedHandlerThreadPool.Create(THandlerThreadPool.Create);
  RecieverThreadPool := TLockedRecieverThreadPool.Create(TRecieverThreadPool.Create);

finalization
  AcceptingThreadPool.Free;
  RecieverThreadPool.Free;
  HandlerThreadPool.Free;

end.
