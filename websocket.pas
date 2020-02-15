unit WebSocket;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ssockets, fgl, sha1, base64, utilities;

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

  { TWebsocketHandler }

  TWebsocketHandler = class
  public
    function Accept(const ARequest: TRequestData;
      const ResponseHeaders: TStrings): boolean;
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

  { TAcceptingThread }

  TAcceptingThread = class(TPoolableThread)
  private
    FStream: TSocketStream;
    FHostMap: TLockedHostMap;
    function ReadRequest(var RequestData: TRequestData): boolean;
    function GenerateAcceptingKey(const Key: string): string;
  protected
    procedure DoExecute; override;
    property Stream: TSocketStream read FStream write FStream;
    property HostMap: TLockedHostMap read FHostMap write FHostMap;
  end;

  TAcceptingThreadFactory = specialize TPoolableThreadFactory<TAcceptingThread>;

  TAcceptingThreadPool = specialize TObjectPool<TAcceptingThread,
    TAcceptingThreadFactory, TAcceptingThreadFactory>;

  { TWebSocketServer }

  TWebSocketServer = class
  private
    FSocket: TInetServer;
    FHostMap: TLockedHostMap;

    procedure DoCreate;
    procedure HandleConnect(Sender: TObject; Data: TSocketStream);
  public
    procedure Start;
    procedure Stop(DoAbort: boolean = False);

    destructor Destroy; override;
    constructor Create(const AHost: string; const APort: word;
      AHandler: TSocketHandler);
    constructor Create(const APort: word);
    property Socket: TInetServer read FSocket;
  end;

const
  MalformedRequestMessage = 'HTTP/1.1 400 Bad Request'#13#10#13#10;
  ForbiddenRequestMessage = 'HTTP/1.1 403 Forbidden'#13#10#13#10;
  HandlerNotFoundMessage = 'HTTP/1.1 404 Not Found'#13#10#13#10;

var
  AcceptingThreadPool: TAcceptingThreadPool;

implementation

{ TRequestHeaders }

function DoHeaderKeyCompare(const Key1, Key2: string): integer;
begin
  // Headers are case insensetive
  Result := CompareStr(Key1.ToLower, Key2.ToLower);
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

{ TAcceptingThread }

function TAcceptingThread.ReadRequest(var RequestData: TRequestData): boolean;
var
  method: string;
  proto: string;
  headerstr: string;
  upg: string;
  conn: string;
  key: string;
  version: string;
begin
  Result := False;
  // Check if this is HTTP by checking the first line
  // Method GET is required
  SetLength(method, 4);
  Stream.Read(method[1], 4);
  if method <> 'GET ' then
  begin
    // Not GET
    Exit;
  end;
  // Read path and HTTP version
  Stream.ReadTo(' ', RequestData.Path);
  Stream.ReadTo(#13#10, proto, 10);
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
  Stream.ReadTo(#13#10#13#10, headerstr, 2048);
  RequestData.Headers.Parse(headerstr);
  if not (RequestData.Headers.TryGetData('Upgrade', upg) and
    RequestData.Headers.TryGetData('Connection', conn) and
    RequestData.Headers.TryGetData('Sec-WebSocket-Key', Key) and
    (upg = 'websocket') and (conn = 'Upgrade')) then
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

function TAcceptingThread.GenerateAcceptingKey(const Key: string): string;
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
      b64Encoder.Write(keyHash[low(keyHash)], Length(keyHash));
      Result := OutputStream.DataString;
    finally
      b64Encoder.Free;
    end;
  finally
    OutputStream.Free;
  end;
end;

procedure TAcceptingThread.DoExecute;
var
  RequestData: TRequestData;
  hm: THostMap;
  hh: THostHandler;
  sh: TWebsocketHandler;
  ResponseHeaders: TStringList;
  i: integer;
  HandsakeResponse: TStringList;
begin
  RequestData.Headers := TRequestHeaders.Create;
  try
    // Reqding request
    try
      if not ReadRequest(RequestData) then
      begin
        Stream.WriteRaw(MalformedRequestMessage);
        Stream.Free;
        Exit;
      end;
    except
      on E: EReadError do
      begin
        Stream.WriteRaw(MalformedRequestMessage);
        Stream.Free;
        Exit;
      end;
    end;
    // Getting responsible handler
    hm := FHostMap.Lock;
    try
      hh := hm.Objects[RequestData.Host];
      if not Assigned(hh) then
      begin
        Stream.WriteRaw(HandlerNotFoundMessage);
        Stream.Free;
        Exit;
      end;
      sh := hh.Objects[RequestData.Path];
      if not Assigned(sh) then
      begin
        Stream.WriteRaw(HandlerNotFoundMessage);
        Stream.Free;
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
        Stream.WriteRaw(ForbiddenRequestMessage);
        Stream.Free;
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

        Stream.WriteRaw(HandsakeResponse.Text);
      finally
        HandsakeResponse.Free;
      end;
    finally
      ResponseHeaders.Free;
    end;
  finally
    RequestData.Headers.Free;
  end;
end;

{ TWebSocketServer }

procedure TWebSocketServer.DoCreate;
begin
  FSocket.OnConnect := @HandleConnect;
  FHostMap := TLockedHostMap.Create;
end;

procedure TWebSocketServer.HandleConnect(Sender: TObject; Data: TSocketStream);
var
  acceptingThread: TAcceptingThread;
begin
  acceptingThread := AcceptingThreadPool.GetObject;
  acceptingThread.Stream := Data;
  acceptingThread.HostMap := FHostMap;
  acceptingThread.Restart;
end;

procedure TWebSocketServer.Start;
begin
  FSocket.StartAccepting;
end;

procedure TWebSocketServer.Stop(DoAbort: boolean);
begin
  FSocket.StopAccepting(DoAbort);
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
  AcceptingThreadPool := TAcceptingThreadPool.Create;

finalization
  AcceptingThreadPool.Free;

end.
