program chatClient;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,{$ENDIF}
  Classes,
  sysutils,
  wsutils,
  wsmessages,
  wsstream,
  ssockets,
  WebsocketsClient;

type

  { TSimpleChat }

  TSimpleChat = class
  private
    FCommunicator: TWebsocketCommunicator;
    procedure ReceiveMessage(Sender: TObject);
    procedure StreamClosed(Sender: TObject);
  public            
    procedure Execute;
    constructor Create(ACommunicator: TWebsocketCommunicator);
    destructor Destroy; override;
  end;

{ TSimpleChat }

procedure TSimpleChat.StreamClosed(Sender: TObject);
begin
  WriteLn('Connection to ', FCommunicator.SocketStream.RemoteAddress.Address, ' closed');
end;

procedure TSimpleChat.ReceiveMessage(Sender: TObject);
var
  MsgList: TWebsocketMessageOwnerList;
  m: TWebsocketMessage;
begin
  MsgList := TWebsocketMessageOwnerList.Create(True);
  try
    FCommunicator.GetUnprocessedMessages(MsgList);
    for m in MsgList do
      if m is TWebsocketStringMessage then
        WriteLn('Message from ', FCommunicator.SocketStream.RemoteAddress.Address, ': ', TWebsocketStringMessage(m).Data)
      else if m is TWebsocketPongMessage then
        WriteLn('Pong from ', FCommunicator.SocketStream.RemoteAddress.Address, ': ', TWebsocketPongMessage(m).Data);
  finally
    MsgList.Free;
  end;
end;

procedure TSimpleChat.Execute;
var
  str: String;
begin
  while FCommunicator.Open do
  begin
    ReadLn(str);
    if not FCommunicator.Open then
      Exit;
    if str = 'exit' then
    begin
      FCommunicator.WriteMessage(wmtClose).Free;
      while FCommunicator.Open do
        Sleep(100);
    end
    else if str.StartsWith('ping') then
      with FCommunicator.WriteMessage(wmtPing) do
      try
        WriteRaw(str.Substring(5));
      finally
        Free;
      end
    else
      FCommunicator.WriteStringMessage(str);
  end;
end;

constructor TSimpleChat.Create(ACommunicator: TWebsocketCommunicator);
begin
  FCommunicator := ACommunicator;
  FCommunicator.OnClose:=@StreamClosed;
  FCommunicator.OnReceiveMessage:=@ReceiveMessage;
  FCommunicator.StartReceiveMessageThread;
end;

destructor TSimpleChat.Destroy;
begin
  FCommunicator.StopReceiveMessageThread;
  while FCommunicator.ReceiveMessageThreadRunning do
    Sleep(10);
  FCommunicator.Free;
  inherited Destroy;
end;

var
  client: TWebsocketClient;
  chat: TSimpleChat;
begin
  client := TWebsocketClient.Create('127.0.0.1', 8080);
  try
    chat := TSimpleChat.Create(client.Connect(TSocketHandler.Create));
    try
      chat.Execute;
    finally
      chat.Free;
    end;
  finally
    client.Free;
  end;
end.

