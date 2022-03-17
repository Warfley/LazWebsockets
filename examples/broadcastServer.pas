program broadcastServer;

{$mode objfpc}{$H+}

uses {$IFDEF UNIX}
  cthreads, {$ENDIF}
  sysutils,
  classes,
  wsutils,
  wsmessages,
  wsstream,
  websocketserver;

type

  { TSocketHandler }

  TSocketHandler = class(TThreadedWebsocketHandler)
  public
    procedure DoHandleCommunication(ACommunication: TWebsocketCommunicator);
      override;
    procedure BroadcastMessage(message: String);
  private
    procedure ConnectionClosed(Sender: TObject);
    procedure MessageReceived(Sender: TObject);
  end;

  { TCLIThread }

  TCLIThread = class(TThread)
  public
    constructor Create;
  protected
    procedure Execute; override;
  end;

var
  socket: TWebSocketServer;
  handler: TSocketHandler;

  { TSocketHandler }


  procedure TSocketHandler.DoHandleCommunication(
    ACommunication: TWebsocketCommunicator);
  begin
    BroadcastMessage(ACommunication.SocketStream.RemoteAddress.Address + ':' + ACommunication.SocketStream.RemoteAddress.Port.ToString + ' joined the broadcast');
    ACommunication.OnReceiveMessage := @MessageReceived;
    ACommunication.OnClose := @ConnectionClosed;
    // Just keep the communication open
    while ACommunication.Open do
      Sleep(10);
  end;

  procedure TSocketHandler.BroadcastMessage(message: String);
  var
    ConnectionList: TConnectionList;
    Connection: TWebsocketCommunicator;
  begin
    WriteLn('Broadcasting: ', message);
    ConnectionList := Connections.Lock;
    try
      for Connection in ConnectionList do
        Connection.WriteStringMessage(message);
    finally
      Connections.Unlock;
    end;
  end;

  procedure TSocketHandler.ConnectionClosed(Sender: TObject);
  var
    Comm: TWebsocketCommunicator;
  begin
    Comm := TWebsocketCommunicator(Sender);
    BroadcastMessage(Comm.SocketStream.RemoteAddress.Address + ' left the broadcast');
  end;

  procedure TSocketHandler.MessageReceived(Sender: TObject);
  var
    Messages: TWebsocketMessageOwnerList;
    m: TWebsocketMessage;
    Comm: TWebsocketCommunicator;
  begin
    Comm := TWebsocketCommunicator(Sender);
    Messages := TWebsocketMessageOwnerList.Create(True);
    try
      Comm.GetUnprocessedMessages(Messages);
      for m in Messages do
        if m is TWebsocketStringMessage then
        begin
          BroadcastMessage('Message from ' + Comm.SocketStream.RemoteAddress.Address +
            ': ' + TWebsocketStringMessage(m).Data);
        end;
    finally
      Messages.Free;
    end;
  end;


  { TCLIThread }

  constructor TCLIThread.Create;
  begin
    inherited Create(False);
    FreeOnTerminate:=True;
  end;

  procedure TCLIThread.Execute;
  var
    cmdline, cmd: String;
    cmdpos: Integer;
  begin
    while True do
    begin
      ReadLn(cmdline);
      cmdpos := cmdline.IndexOf(' ');
      if (cmdpos < 0) then
        cmd := cmdline
      else
        cmd := cmdline.Substring(0, cmdpos);
      if cmd = 'exit' then
      begin
        socket.Stop;
        Break;
      end
      else if cmd = 'send' then
        handler.BroadcastMessage('Message from server: ' + cmdline.Substring(cmdpos));
    end;
  end;

begin
  socket := TWebSocketServer.Create(8080);
  try
    socket.FreeHandlers := True;
    handler := TSocketHandler.Create;
    socket.RegisterHandler('*', '*', handler, True, True);
    TCLIThread.Create;
    socket.Start;
  finally
    socket.Free;
  end;
end.
