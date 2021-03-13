unit WebsocketsClient;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ssockets, wsstream, wsutils, base64;

type
  EWebsocketClientError = class(Exception);

  TResponseData = record
    StatusCode: Integer;
    StatusMessage: String;
    Headers: THttpHeader;
    Content: String;
  end;

  TWebsocketHandshakeResponseEvent = procedure(Sender: TObject; const Data: TResponseData) of object;

  { TWebsocketClient }

  TWebsocketClient = class
  private
    FHost: String;
    FPort: Integer;
    FPath: String;
    FCustomHeaders: TStrings;
    FOnHandshakeSuccess: TWebsocketHandshakeResponseEvent;
    FOnHandshakeFailure: TWebsocketHandshakeResponseEvent;

    function GenerateKey: String;
    function DoHandshake(ASocket: TInetSocket): Boolean;
    procedure SetCustomHeaders(AValue: TStrings);
  public
    constructor Create(const AHost: String; const APort: Integer = 80; const APath: String = '/');
    destructor Destroy; override;

    function Connect(AHandler: TSocketHandler = nil): TWebsocketCommunicator;

    property Host: String read FHost write FHost;
    property Port: Integer read FPort write FPort;
    property Path: String read FPath write FPath;
    property CustomHeaders: TStrings read FCustomHeaders write SetCustomHeaders;
    property OnHandshakeSuccess: TWebsocketHandshakeResponseEvent read FOnHandshakeSuccess write FOnHandshakeSuccess;
    property OnHandshakeFailure: TWebsocketHandshakeResponseEvent read FOnHandshakeFailure write FOnHandshakeFailure;
  end;

implementation

function TWebsocketClient.GenerateKey: String;
var
  GenKey: AnsiString;
  i: Integer;
begin
  SetLength(GenKey, 16);
  for i:=1 to 16 do
    GenKey[i] := Chr(Random(256));
  Result := EncodeStringBase64(GenKey);
end;

function TWebsocketClient.DoHandshake(ASocket: TInetSocket): Boolean;

function B64Trim(const B64String: String): String; inline;
var
  len: SizeInt;
begin
  len := Length(B64String);
  while (len > 0) and (B64String[len] = '=') do
    Dec(len);
  Result := B64String.Substring(0, len);
end;

var
  Key, proto, StatusCodeStr, HeaderStr, ExpectedResponseKey: String;
  RequestContent: TStringList;
  i: Integer;
  ResponseData: TResponseData;
  conn, upg, respKey, cLenStr: String;
  cLen: Longint;
begin
  Result := False;
  Key := GenerateKey;
  ASocket.Connect;
  RequestContent := TStringList.Create;
  try
    RequestContent.TextLineBreakStyle:=tlbsCRLF;
    RequestContent.Add('GET %s HTTP/1.1'.Format([FPath]));   
    RequestContent.Add('Host: %s:%d'.Format([FHost, FPort]));
    RequestContent.Add('Connection: Upgrade');
    RequestContent.Add('Upgrade: websocket');
    RequestContent.Add('Sec-WebSocket-Key: %s'.Format([Key]));
    RequestContent.Add('Sec-WebSocket-Version: 13');
    for i := 0 to FCustomHeaders.Count-1 do
      RequestContent.Add('%s: %s'.Format([FCustomHeaders.Names[i], FCustomHeaders.ValueFromIndex[i]]));
    RequestContent.Add('');
    ASocket.WriteRaw(RequestContent.Text);
  finally
    RequestContent.Free;
  end;
  ExpectedResponseKey := GenerateAcceptingKey(Key);
  ASocket.ReadTo('HTTP/1.1 ', proto, 9);
  if proto <> 'HTTP/1.1 ' then
  begin
    // Unsupported protocol
    Exit;
  end;
  StatusCodeStr := ASocket.ReadRaw(4).TrimRight;
  if not TryStrToInt(StatusCodeStr, ResponseData.StatusCode) then
  begin
    // cant read statuscode
    Exit;
  end;
  ASocket.ReadTo(#13#10, ResponseData.StatusMessage, 32);
  ResponseData.StatusMessage:= ResponseData.StatusMessage.TrimRight;
  ASocket.ReadTo(#13#10#13#10, HeaderStr, 2048);
  ResponseData.Headers := THttpHeader.Create;
  try
    ResponseData.Headers.Parse(HeaderStr.TrimRight);
    if not ((ResponseData.StatusCode = 101)
      and ResponseData.Headers.TryGetData('Connection', conn)
      and ResponseData.Headers.TryGetData('Upgrade', upg)
      and ResponseData.Headers.TryGetData('Sec-WebSocket-Accept', respKey)
      and (conn.ToLower = 'upgrade') and (upg = 'websocket')
      and (B64Trim(respKey) = B64Trim(ExpectedResponseKey))) then
    begin
      // Read content if possible
      if (ResponseData.StatusCode > 199)
        and (ResponseData.StatusCode <> 204)
        and (ResponseData.StatusCode <> 304)
        and ResponseData.Headers.TryGetData('Content-Length', cLenStr)
        and TryStrToInt(cLenStr, cLen) then
      begin
        ResponseData.Content:=ASocket.ReadRaw(cLen);
      end;
      if Assigned(FOnHandshakeFailure) then
        FOnHandshakeFailure(Self, ResponseData);
      Exit;
    end;
    if Assigned(FOnHandshakeSuccess) then
      FOnHandshakeSuccess(Self, ResponseData);
  finally
    ResponseData.Headers.Free;
  end;   
  Result := True;
end;

procedure TWebsocketClient.SetCustomHeaders(AValue: TStrings);
begin
  if FCustomHeaders=AValue then Exit;
  FCustomHeaders.Assign(AValue);
end;

constructor TWebsocketClient.Create(const AHost: String; const APort: Integer;
  const APath: String);
begin
  FHost:=AHost;
  FPort:= APort;
  FPath:=APath;
  FCustomHeaders := TStringList.Create;
  FCustomHeaders.NameValueSeparator:=':';
end;

destructor TWebsocketClient.Destroy;
begin
  FCustomHeaders.Free;
  inherited Destroy;
end;

function TWebsocketClient.Connect(AHandler: TSocketHandler): TWebsocketCommunicator;
var
  Socket: TInetSocket;
begin      
  Result := nil;
  Socket := TInetSocket.Create(FHost, FPort, AHandler);
  try
    if not DoHandshake(Socket) then
    begin
      Socket.Free;
      Exit;
    end;
  except
    Socket.Free;
    raise;
  end;
  Result := TWebsocketCommunicator.Create(TLockedSocketStream.Create(Socket), True, False);
end;

initialization
  Randomize;
end.

