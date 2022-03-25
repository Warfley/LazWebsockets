unit WebSocketServer;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ssockets, fgl, wsutils, wsstream, wsmessages;

type

  TRequestData = record
    Host: string;
    Path: string;
    Key: string;
    Headers: THttpHeader;
  end;

  TConnectionList = class(specialize TFPGObjectList<TWebsocketCommunicator>);
  TThreadedConnectionList = class(specialize TThreadedObject<TConnectionList>);

  { TWebsocketHandler }

  TWebsocketHandler = class
  protected
    procedure PrepareCommunication(ACommunicator: TWebsocketCommunicator); virtual;
    procedure DoHandleCommunication(ACommunicator: TWebsocketCommunicator); virtual;
    procedure FinalizeCommunication(ACommunicator: TWebsocketCommunicator); virtual;
  public
    function Accept(const ARequest: TRequestData;
      const ResponseHeaders: TStrings): boolean; virtual;
    function CreateCommunicator(DataStream: TLockedSocketStream; AHeader: THttpHeader): TWebsocketCommunicator; virtual;
    procedure HandleCommunication(ACommunicator: TWebsocketCommunicator); virtual;
  end;

  { TThreadedWebsocketHandler }

  TThreadedWebsocketHandler = class(TWebsocketHandler)
  private
    FPooling: Boolean;
  public
    constructor Create(Pooling: Boolean = True);
    procedure HandleCommunication(ACommunicator: TWebsocketCommunicator); override;
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
  TWebsocketHandlerArgs = record
    Communicator: TWebsocketCommunicator;
    Handler: TThreadedWebsocketHandler;
    Pooling: Boolean;
  end;

  {Thread Types}
  { TWebsocketHandlerThread }

  TWebsocketHandlerThread = class(specialize TPoolableThread<TWebsocketHandlerArgs>)
  protected
    procedure ExecuteTask(constref Arg: TWebsocketHandlerArgs); override;
  end;

  THandlerThreadPool = specialize TThreadPool<TWebsocketHandlerThread>;
  TLockedHandlerThreadPool = specialize TThreadedObject<THandlerThreadPool>;

  { TWebsocketReceiverThread }

  TWebsocketReceiverThread = class(specialize TPoolableThread<TWebsocketCommunicator>)
  protected
    procedure ExecuteTask(constref Arg: TWebsocketCommunicator); override;
  end;

  TReceiverThreadPool = specialize TThreadPool<TWebsocketReceiverThread>;
  TLockedReceiverThreadPool = specialize TThreadedObject<TReceiverThreadPool>;

  { TWebsocketHandshakeHandler }

  TWebsocketHandshakeHandler = class
  private
    FStream: TSocketStream;
    FHostMap: TLockedHostMap;
    function ReadRequest(var RequestData: TRequestData): boolean;
  public
    procedure PerformHandshake;
    constructor Create(AStream: TSocketStream; AHostMap: TLockedHostMap);
  end;

  { TAcceptingThread }

  TAcceptingThread = class(specialize TPoolableThread<TWebsocketHandshakeHandler>)
  protected
    procedure ExecuteTask(constref Arg: TWebsocketHandshakeHandler); override;
  end;

  TAcceptingThreadPool = specialize TThreadPool<TAcceptingThread>;
  TLockedAcceptingThreadPool = specialize TThreadedObject<TAcceptingThreadPool>;

var
  ReceiverThreadPool: TLockedReceiverThreadPool;
  HandlerThreadPool: TLockedHandlerThreadPool;
  AcceptingThreadPool: TLockedAcceptingThreadPool;

function CreateAcceptingThread(
  const AHandshakeHandler: TWebsocketHandshakeHandler; Pooling: Boolean): TAcceptingThread; inline;
var
  pool: TAcceptingThreadPool;
begin
  if Pooling then
  begin
    pool := AcceptingThreadPool.Lock;
    try
      Result := pool.GetThread;
      Result.Start(AHandshakeHandler);
    finally
      AcceptingThreadPool.Unlock;
    end;
  end
  else
  begin
    Result := TAcceptingThread.Create(False);
    Result.FreeOnTerminate := True;
    Result.Start(AHandshakeHandler);
  end;
end;

function CreateHandlerThread(const ACommunicator: TWebsocketCommunicator;
  const AHandler: TThreadedWebsocketHandler; Pooling: Boolean): TWebsocketHandlerThread; inline;
var
  pool: THandlerThreadPool;
  args: TWebsocketHandlerArgs;
begin
  Args.Communicator := ACommunicator;
  Args.Handler := AHandler;
  Args.Pooling := Pooling;
  if Pooling then
  begin
    pool := HandlerThreadPool.Lock;
    try
      Result := pool.GetThread;
      Result.Start(args);
    finally
      HandlerThreadPool.Unlock;
    end;
  end
  else
  begin
    Result := TWebsocketHandlerThread.Create(False);
    Result.FreeOnTerminate := True;
    Result.Start(Args);
  end;
end;

function CreateReceiverThread(const ACommunicator: TWebsocketCommunicator; Pooling: Boolean):
TWebsocketReceiverThread; inline;
var
  pool: TReceiverThreadPool;
begin
  if Pooling then
  begin
    pool := ReceiverThreadPool.Lock;
    try
      Result := pool.GetThread;
      Result.Start(ACommunicator);
    finally
      ReceiverThreadPool.Unlock;
    end;
  end
  else
  begin
    Result := TWebsocketReceiverThread.Create(False);
    Result.FreeOnTerminate := True;
    Result.Start(ACommunicator);
  end;
end;

{ TWebsocketHandlerThread }

procedure TWebsocketHandlerThread.ExecuteTask(constref
  Arg: TWebsocketHandlerArgs);
var
  Recv: TWebsocketReceiverThread;
begin
  try
    Recv := CreateReceiverThread(arg.Communicator, Arg.Pooling);
    try
      Arg.Communicator.SetCustomReceiveMessageThread(Recv);
      Arg.Handler.PrepareCommunication(arg.Communicator);
      Arg.Handler.DoHandleCommunication(arg.Communicator);
    finally
      Recv.Stop;
    end;
    Sleep(20);
  finally
    Arg.Handler.FinalizeCommunication(arg.Communicator);
  end;
end;

procedure TAcceptingThread.ExecuteTask(constref Arg: TWebsocketHandshakeHandler
  );
begin
  Arg.PerformHandshake;
end;

{ TWebsocketReceiverThread }

procedure TWebsocketReceiverThread.ExecuteTask(constref
  Arg: TWebsocketCommunicator);
var
  msg: TWebsocketMessage;
begin
  while not Terminated and not Stopped and Arg.Open do
  begin
    msg := Arg.ReceiveMessage;
    if Assigned(msg) then
      Arg.AddMessageToList(msg);
    Sleep(10);
  end;
  Arg.SetCustomReceiveMessageThread(Nil);
end;

{ THostHandler }

constructor THostHandler.Create(const AHost: string; FreeObjects: boolean);
begin
  FHost := AHost;
  inherited Create(FreeObjects);
end;

{ TWebsocketHandler }

procedure TWebsocketHandler.PrepareCommunication(
  ACommunicator: TWebsocketCommunicator);
var
  lst: TConnectionList;
begin
  // No implementation; To be overriden
end;

procedure TWebsocketHandler.DoHandleCommunication(
  ACommunicator: TWebsocketCommunicator);
begin
  // No implementation; To be overriden
end;

procedure TWebsocketHandler.FinalizeCommunication(
  ACommunicator: TWebsocketCommunicator);
begin
  ACommunicator.Close;
  Sleep(20);
  ACommunicator.Free;
end;

function TWebsocketHandler.Accept(const ARequest: TRequestData;
  const ResponseHeaders: TStrings): boolean;
begin
  Result := True;
end;

function TWebsocketHandler.CreateCommunicator(DataStream: TLockedSocketStream;
  AHeader: THttpHeader): TWebsocketCommunicator;
begin
  Result := TWebsocketCommunicator.Create(DataStream, False, True);
end;

procedure TWebsocketHandler.HandleCommunication(
  ACommunicator: TWebsocketCommunicator);
begin
  PrepareCommunication(ACommunicator);
  DoHandleCommunication(ACommunicator);
  FinalizeCommunication(ACommunicator);
end;

constructor TThreadedWebsocketHandler.Create(Pooling: Boolean);
begin
  FPooling := Pooling;
  inherited Create;
end;

procedure TThreadedWebsocketHandler.HandleCommunication(
  ACommunicator: TWebsocketCommunicator);
begin
  CreateHandlerThread(ACommunicator, Self, FPooling);
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
  RequestData.Headers.Parse(headerstr.TrimRight);
  if not (RequestData.Headers.TryGetData('Upgrade', upg) and
    RequestData.Headers.TryGetData('Connection', conn) and
    RequestData.Headers.TryGetData('Sec-WebSocket-Key', RequestData.Key) and
    (upg.ToLower = 'websocket') and (conn.ToLower.Contains('upgrade'))) then
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

procedure TWebsocketHandshakeHandler.PerformHandshake;
var
  RequestData: TRequestData;
  hm: THostMap;
  hh: THostHandler;
  sh: TWebsocketHandler;
  ResponseHeaders: TStringList;
  i: integer;
  HandsakeResponse: TStringList;
  Comm: TWebsocketCommunicator;
begin
  try
    RequestData.Headers := THttpHeader.Create;
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
    Comm := sh.CreateCommunicator(TLockedSocketStream.Create(FStream), RequestData.Headers);
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
  if AcceptingMethod = samDefault then
    HandshakeHandler.PerformHandshake
  else
    CreateAcceptingThread(HandshakeHandler, AcceptingMethod = samThreadPool);
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
  // Wait a bit for stop to take effect
  Sleep(100);
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
  AcceptingThreadPool := TLockedAcceptingThreadPool.Create(TAcceptingThreadPool.Create(True));
  HandlerThreadPool := TLockedHandlerThreadPool.Create(THandlerThreadPool.Create(True));
  ReceiverThreadPool := TLockedReceiverThreadPool.Create(TReceiverThreadPool.Create(True));

finalization
  AcceptingThreadPool.Free;
  ReceiverThreadPool.Free;
  HandlerThreadPool.Free;

end.
