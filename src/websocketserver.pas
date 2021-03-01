unit WebSocketServer;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ssockets, fgl, wsutils, wsstream;

type

  TRequestData = record
    Host: string;
    Path: string;
    Key: string;
    Headers: THttpHeader;
  end;

  TConnectionList = class(specialize TFPGObjectList<TWebsocketCommunincator>);
  TThreadedConnectionList = class(specialize TThreadedObject<TConnectionList>);

  { TWebsocketHandler }

  TWebsocketHandler = class
  private
    FConnections: TThreadedConnectionList;
  public
    constructor Create;
    destructor Destroy; override;

    function Accept(const ARequest: TRequestData;
      const ResponseHeaders: TStrings): boolean; virtual;
    procedure HandleCommunication(ACommunicator: TWebsocketCommunincator); virtual;
    procedure PrepareCommunication(ACommunicator: TWebsocketCommunincator); virtual;
    procedure DoHandleCommunication(ACommunicator: TWebsocketCommunincator); virtual;
    procedure FinalizeCommunication(ACommunicator: TWebsocketCommunincator); virtual;

    property Connections: TThreadedConnectionList read FConnections;
  end;

  TThreadedWebsocketHandler = class(TWebsocketHandler)
  public
    procedure HandleCommunication(ACommunicator: TWebsocketCommunincator); override;
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

function CreateAcceptingThread(
  const AHandshakeHandler: TWebsocketHandshakeHandler): TAcceptingThread; inline;
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

function CreateRecieverThread(const ACommunicator: TWebsocketCommunincator):
TWebsocketRecieverThread; inline;
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

{ TWebsocketHandlerThread }

procedure TWebsocketHandlerThread.DoExecute;
var
  Recv: TWebsocketRecieverThread;
begin
  Recv := CreateRecieverThread(FCommunicator);
  try
    try
      FHandler.PrepareCommunication(FCommunicator);
      FHandler.DoHandleCommunication(FCommunicator);
    finally
      FHandler.FinalizeCommunication(FCommunicator);
    end;
  finally
    Recv.Kill;
  end;
end;

procedure TAcceptingThread.DoExecute;
begin
  FHandshakeHandler.PerformHandshake;
end;

{ TWebsocketRecieverThread }

procedure TWebsocketRecieverThread.DoExecute;
begin
  FStopped := False;
  while not Terminated and not FStopped and FCommunicator.Open do
  begin
    FCommunicator.RecieveMessage;
    Sleep(10);
  end;
end;

procedure TWebsocketRecieverThread.Kill;
begin
  FStopped := True;
end;

{ THostHandler }

constructor THostHandler.Create(const AHost: string; FreeObjects: boolean);
begin
  FHost := AHost;
  inherited Create(FreeObjects);
end;

{ TWebsocketHandler }

constructor TWebsocketHandler.Create;
begin
  FConnections := TThreadedConnectionList.Create(TConnectionList.Create);
end;

destructor TWebsocketHandler.Destroy;
var
  ConnectionList: TConnectionList;
  Connection: TWebsocketCommunincator;
begin
  ConnectionList := FConnections.Lock;
  try
    for Connection in ConnectionList do
      Connection.Close(True);
  finally
    FConnections.Unlock;
  end;
  // wait for all connections to close
  sleep(100);
  FConnections.Free;
  inherited Destroy;
end;

function TWebsocketHandler.Accept(const ARequest: TRequestData;
  const ResponseHeaders: TStrings): boolean;
begin
  Result := True;
end;

procedure TWebsocketHandler.PrepareCommunication(
  ACommunicator: TWebsocketCommunincator);
var
  lst: TConnectionList;
begin
  lst := FConnections.Lock;
  try
    lst.Add(ACommunicator);
  finally
    FConnections.Unlock;
  end;
end;

procedure TWebsocketHandler.DoHandleCommunication(
  ACommunicator: TWebsocketCommunincator);
begin
  // No implementation; To be overriden
end;

procedure TWebsocketHandler.FinalizeCommunication(
  ACommunicator: TWebsocketCommunincator);
var
  lst: TConnectionList;
begin
  ACommunicator.Close;
  lst := FConnections.Lock;
  try
    lst.Remove(ACommunicator);
  finally
    FConnections.Unlock;
  end;
end;

procedure TWebsocketHandler.HandleCommunication(
  ACommunicator: TWebsocketCommunincator);
begin
  PrepareCommunication(ACommunicator);
  DoHandleCommunication(ACommunicator);
  FinalizeCommunication(ACommunicator);
end;

procedure TThreadedWebsocketHandler.HandleCommunication(
  ACommunicator: TWebsocketCommunincator);
begin
  CreateHandlerThread(ACommunicator, Self);
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
    Comm := TWebsocketCommunincator.Create(TLockedSocketStream.Create(FStream),
      False, True);
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
