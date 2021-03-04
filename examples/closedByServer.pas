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
    procedure DoHandleCommunication(ACommunication: TWebsocketCommunincator);
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
    ACommunication: TWebsocketCommunincator);
  var
    str: string;
  begin
    WriteLn('Connected to ', ACommunication.SocketStream.RemoteAddress.Address);
    ACommunication.OnReceiveMessage := @MessageReceived;
    ACommunication.OnClose := @ConnectionClosed;
    ACommunication.WriteStringMessage('Bye bye');
  end;

  procedure TSocketHandler.ConnectionClosed(Sender: TObject);
  var
    Comm: TWebsocketCommunincator;
  begin
    Comm := TWebsocketCommunincator(Sender);
    WriteLn('Connection to ', Comm.SocketStream.RemoteAddress.Address, ' closed');
  end;

  procedure TSocketHandler.MessageReceived(Sender: TObject);
  var
    Messages: TWebsocketMessageOwnerList;
    m: TWebsocketMessage;
    Comm: TWebsocketCommunincator;
  begin
    Comm := TWebsocketCommunincator(Sender);
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
