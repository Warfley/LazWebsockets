unit WebSocket;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ssockets, gvector, fgl;

type

  { TObjectPool }

  generic TObjectPool<T, Factory, Checker> = class
  private
    type
    TPool = class(specialize TVector<T>);
  private
    FWorking: TPool;
    FIdle: TPool;
    procedure CleanUp;
  public
    constructor Create;
    destructor Destroy; override;

    function GetObject: T;
  end;

  { TAcceptingThread }

  TAcceptingThread = class(TThread)
  public
    class function Produce: TAcceptingThread;
    class procedure Clear(const AThread: TAcceptingThread);
    class procedure DoDestroy(const AThread: TAcceptingThread);
    class function IsIdle(const AThread: TAcceptingThread): boolean;
  private
    FFree: boolean;
    FDoHandleConnection: TConnectEvent;
    FStream: TSocketStream;
  protected
    procedure Execute; override;
  public
    property isFree: boolean read FFree;
    property DoHandleConnection: TConnectEvent
      read FDoHandleConnection write FDoHandleConnection;
    property Stream: TSocketStream read FStream write FStream;
  end;

  TAcceptingThreadPool = class(specialize TObjectPool<TAcceptingThread,
    TAcceptingThread, TAcceptingThread>);

  TAcceptingMethod = (amSingle, amThreaded, amThreadPool);

  { TWebSocketServer }

  TWebSocketServer = class
  private
    FAcceptingMethod: TAcceptingMethod;
    FThreadPool: TAcceptingThreadPool;
    FSocket: TInetServer;

    procedure DoCreate;
    procedure DoHandleConnection(Sender: TObject; Data: TSocketStream);
    procedure HandleConnect(Sender: TObject; Data: TSocketStream);
  public
    procedure Start;
    procedure Stop(DoAbort: boolean = False);

    destructor Destroy; override;
    constructor Create(const AHost: string; const APort: word;
      AHandler: TSocketHandler);
    constructor Create(const APort: word);
    property AcceptingMethod: TAcceptingMethod
      read FAcceptingMethod write FAcceptingMethod;
    property Socket: TInetServer read FSocket;
  end;

  { TStreamHelper }

  TStreamHelper = class helper for TStream
  public
    procedure ReadTo(const pattern: string; out Result: string; MaxLen: integer = 1024);
    function WriteRaw(const Data: string): longint;
  end;

implementation

type

  { TRequestHeaders }

  TRequestHeaders = class(specialize TFPGMap<string, string>)
  public
    procedure Parse(const HeaderString: string);
    constructor Create;
  end;

{ TRequestHeaders }

function DoHeaderKeyCompare(const Key1, Key2: string): integer;
begin
  // Headers are case insensetive
  Result := CompareStr(Key1.ToLower, Key2.ToLower);
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

{ TStreamHelper }

{* -----------------------------------------------------------------------------
 * Reads a stream until a pattern is found, maxlen is reached or an exception
 * is thrown.
 * On exception the result will still be a valid string. Can be used to read
 * until End of Stream
 * ----------------------------------------------------------------------------}
procedure TStreamHelper.ReadTo(const pattern: string; out Result: string;
  MaxLen: integer);
var
  c: char;
  len: integer;
  pLen: integer;
  backtrack: integer;
begin
  SetLength(Result, 128);
  len := 0;
  plen := 0;
  backtrack := 0;
  try
    while len < MaxLen do
    begin
      c := char(Self.ReadByte);
      Result[len + 1] := c;
      Inc(len);
      if len = Result.Length then
        SetLength(Result, Result.Length * 2);
      if pattern[pLen + 1] = c then
      begin
        if plen = 0 then
        begin
          backtrack := len;
        end;
        Inc(pLen);
        if pLen = pattern.Length then
          Break;
      end
      else if plen > 0 then
      begin
        pLen := 0;
        while backtrack + pLen < len do
        begin
          if pattern[pLen] = Result[backtrack + pLen] then
            Inc(pLen)
          else
          begin
            pLen := 0;
            Inc(backtrack);
          end;
        end;
      end;
    end;
  finally
    SetLength(Result, len);
  end;
end;

{* -----------------------------------------------------------------------------
 * HTTP writes plaintext, so this is a wrapper for .Write for ommiting the
 * Count parameter
 * ----------------------------------------------------------------------------}
function TStreamHelper.WriteRaw(const Data: string): longint;
begin
  Result := self.Write(Data[1], Data.Length);
end;

{ TAcceptingThread }

class function TAcceptingThread.Produce: TAcceptingThread;
begin
  Result := TAcceptingThread.Create(True);
end;

class procedure TAcceptingThread.Clear(const AThread: TAcceptingThread);
begin
  AThread.FFree := False;
end;

class procedure TAcceptingThread.DoDestroy(const AThread: TAcceptingThread);
begin
  AThread.Free;
end;

class function TAcceptingThread.isIdle(const AThread: TAcceptingThread): boolean;
begin
  Result := AThread.Finished and AThread.isFree;
end;

procedure TAcceptingThread.Execute;
begin
  FFree := True;
  if Assigned(DoHandleConnection) then
    DoHandleConnection(self, FStream);
end;

{ TObjectPool }
{* -----------------------------------------------------------------------------
 * Searches the whole list, checks if some of the objects can be transfered from
 * working to idle
 * ----------------------------------------------------------------------------}
procedure TObjectPool.CleanUp;
var
  i: SizeUInt;
  len: SizeUInt;
begin
  i := 0;
  len := FWorking.Size;
  while i < len do
  begin
    if Checker.isIdle(FWorking[i]) then
    begin
      // If idle than put into idle list
      FIdle.PushBack(FWorking[i]);
      // swap delete, so in the end we only need to reduce the size
      FWorking[i] := FWorking[len - 1];
      Dec(len);
    end
    else
    begin
      Inc(i);
    end;
  end;
  // "Remove" the deleted objects
  FWorking.Resize(len);
  (* Maybe this is usefull?
  if FIdle.Size > FWorking.Size + 1 then
  begin
    for i := FWorking.Size + 1 to FIdle.Size - 1 do
      Factory.DoDestroy(FIdle[i]);
    FIdle.Resize(FWorking.Size + 1);
  end;
  *)
end;

constructor TObjectPool.Create;
begin
  FWorking := TPool.Create;
  FIdle := TPool.Create;
end;

destructor TObjectPool.Destroy;
var
  obj: T;
begin
  for obj in FWorking do
    Factory.DoDestroy(obj);
  FWorking.Free;
  for obj in FIdle do
    Factory.DoDestroy(obj);
  FIdle.Free;
  inherited Destroy;
end;

{* -----------------------------------------------------------------------------
 * Returns an object. If Idle ones are available they are reused, otherwise
 * new ones will be created
 * ----------------------------------------------------------------------------}
function TObjectPool.GetObject: T;
var
  i: SizeUInt;
begin
  CleanUp;
  // If we have objects cached return one of them
  if FIdle.Size > 0 then
  begin
    Result := FIdle.Back;
    FIdle.PopBack;
    Factory.Clear(Result);
    FWorking.PushBack(Result);
  end
  // if this isn't the first object, create as many idle ones as there are working ones
  else if FWorking.Size > 0 then
  begin
    FIdle.Reserve(FWorking.Size);
    for i := 0 to FWorking.Size do
      FIdle.PushBack(Factory.Produce);
    Result := FIdle.Back;
    FIdle.PopBack;
    Factory.Clear(Result);
    FWorking.PushBack(Result);
  end
  else // otherwise create only one
  begin
    Result := Factory.Produce;
    Factory.Clear(Result);
    FWorking.PushBack(Result);
  end;
end;

{ TWebSocketServer }

procedure TWebSocketServer.DoCreate;
begin
  FAcceptingMethod := amSingle;
  FThreadPool := TAcceptingThreadPool.Create;
  FSocket.OnConnect := @HandleConnect;
end;

procedure TWebSocketServer.DoHandleConnection(Sender: TObject; Data: TSocketStream);
var
  method: string;
  path: string;
  proto: string;
  headerstr: string;
  Headers: TRequestHeaders;
  upg: string;
  conn: string;
  key: string;
  version: string;
const
  MalformedRequestReturn = 'HTTP/1.1 403 Forbidden'#13#10#13#10;
begin
  // Check if this is HTTP by checking the first line
  try
    // Method GET is required
    Data.ReadTo('GET ', method, 4);
  except // Not HTTP: kill socket
    on E: EReadError do
    begin
      Data.Free;
      Exit;
    end;
  end;
  method := method.TrimRight;
  if method.Length <> 3 then // Not GET: kill socket
  begin
    Data.Free;
    Exit;
  end;
  try  // Read path and HTTP version
    Data.ReadTo(' ', path);
    Data.ReadTo(#13#10, proto);
  except
    on E: EReadError do // Malformed or unexpected error: Kill stream
    begin
      Data.Free;
      Exit;
    end;
  end;
  path := path.TrimRight;
  proto := proto.TrimRight.ToLower;
  if not proto.StartsWith('http/') then // Only accept http/1.1
  begin
    Data.Free;
    Exit;
  end;
  if not proto.EndsWith('1.1') then
  begin // non 1.1 version: return forbidden
    Data.WriteRaw(MalformedRequestReturn);
    Data.Free;
    exit;
  end;
  // Headers are separated by 2 newlines (CR+LF)
  try
    Data.ReadTo(#13#10#13#10, headerstr, 2048);
  except
    on E: EReadError do
    begin
      Data.Free;
      Exit;
    end;
  end;
  Headers := TRequestHeaders.Create;
  try
    // Check required headers for handshake
    Headers.Parse(headerstr);
    if not (headers.TryGetData('Upgrade', upg)
        and Headers.TryGetData('Connection', conn)
        and Headers.TryGetData('Sec-WebSocket-Key', key)
        and (upg = 'websocket')
        and (conn = 'Upgrade')) then
    begin
      Data.WriteRaw(MalformedRequestReturn);
      Data.Free;
      exit;
    end;
    // How to handle this?
    if not Headers.TryGetData('Sec-WebSocket-Version', version) then
      version := '';
  finally
    Headers.Free;
  end;
  // TODO: perform handshake
end;

procedure TWebSocketServer.HandleConnect(Sender: TObject; Data: TSocketStream);
var
  at: TAcceptingThread;
begin
  // We take the extra step of adding a function DoHandleConnection, so we have
  // a common interface for threaded and not threaded usage
  case FAcceptingMethod of
    amSingle:
      DoHandleConnection(Sender, Data);
    amThreaded:
    begin
      at := TAcceptingThread.Produce;
      at.FreeOnTerminate := True;
      at.Stream := Data;
      at.DoHandleConnection := @DoHandleConnection;
      at.Start;
    end;
    amThreadPool:
    begin
      at := FThreadPool.GetObject;
      at.Stream := Data;
      at.DoHandleConnection := @DoHandleConnection;
      at.Start;
    end;
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

destructor TWebSocketServer.Destroy;
begin
  Stop(True);
  FSocket.Free;
  FThreadPool.Free;
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

end.
