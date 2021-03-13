program chatServer;

{$mode objfpc}{$H+}

uses {$IFDEF UNIX}
  cthreads, {$ENDIF}
  classes,
  wsutils,
  wsmessages,
  wsstream,
  websocketserver;

type

  { TSocketHandler }

  TSocketHandler = class(TThreadedWebsocketHandler)
  private
    procedure ConnectionClosed(Sender: TObject);
    procedure MessageReceived(Sender: TObject);
  public
    function Accept(const ARequest: TRequestData;
      const ResponseHeaders: TStrings): boolean; override;
    procedure DoHandleCommunication(ACommunication: TWebsocketCommunicator);
      override;
  end;

var
  socket: TWebSocketServer;

  { TSocketHandler }

  function TSocketHandler.Accept(const ARequest: TRequestData;
  const ResponseHeaders: TStrings): boolean;
  begin
    Result := True;
  end;

  procedure TSocketHandler.DoHandleCommunication(
    ACommunication: TWebsocketCommunicator);
  var
    str: string;
  begin
    WriteLn('Connected to ', ACommunication.SocketStream.RemoteAddress.Address);
    ACommunication.OnReceiveMessage := @MessageReceived;
    ACommunication.OnClose := @ConnectionClosed;
    while ACommunication.Open do
    begin
      ReadLn(str);
      if not ACommunication.Open then
        Break; // could be closed by the time ReadLn takes
      ACommunication.WriteStringMessage(str);
      WriteLn('Message to ', ACommunication.SocketStream.RemoteAddress.Address,
        ': ', str);
    end;
    socket.Stop(True);
  end;

  procedure TSocketHandler.ConnectionClosed(Sender: TObject);
  var
    Comm: TWebsocketCommunicator;
  begin
    Comm := TWebsocketCommunicator(Sender);
    WriteLn('Connection to ', Comm.SocketStream.RemoteAddress.Address, ' closed');
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
          WriteLn('Message from ', Comm.SocketStream.RemoteAddress.Address,
            ': ', TWebsocketStringMessage(m).Data);
        end;
    finally
      Messages.Free;
    end;
  end;

begin
  socket := TWebSocketServer.Create(8080);
  try
    socket.FreeHandlers := True;
    //socket.AcceptingMethod:=samThreadPool;
    socket.RegisterHandler('*', '*', TSocketHandler.Create, True, True);
    socket.Start;
  finally
    socket.Free;
  end;
end.
