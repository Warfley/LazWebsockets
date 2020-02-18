program example;

{$mode objfpc}{$H+}

uses {$IFDEF UNIX} {$IFDEF UseCThreads}
  cthreads, {$ENDIF} {$ENDIF}
  Classes,
  SysUtils,
  WebSocket,
  utilities,
  Sockets { you can add units after this };

type

  { TSocketHandler }

  TSocketHandler = class(TThreadedWebsocketHandler)
    function Accept(const ARequest: TRequestData;
      const ResponseHeaders: TStrings): boolean; override;
    procedure DoHandleCommunication(ACommunication: TWebsocketCommunincator);
      override;
  private
    procedure ConnectionClosed(Sender: TObject);
    procedure MessageRecieved(Sender: TObject);
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
    WriteLn('Connected to ', NetAddrToStr(
      ACommunication.SocketStream.RemoteAddress.sin_addr));
    ACommunication.OnRecieveMessage := @MessageRecieved;
    ACommunication.OnClose := @ConnectionClosed;
    while ACommunication.Open do
    begin
      ReadLn(str);
      if not ACommunication.Open then
        Break; // could be closed by the time ReadLn takes
      with ACommunication.WriteMessage do
        try
          WriteRaw(str);
        finally
          Free;
        end;
      WriteLn('Message sent to ',
        NetAddrToStr(ACommunication.SocketStream.RemoteAddress.sin_addr), ': ', str);
    end;
    socket.Stop(True);
  end;

  procedure TSocketHandler.ConnectionClosed(Sender: TObject);
  var
    Comm: TWebsocketCommunincator;
  begin
    Comm := TWebsocketCommunincator(Sender);
    WriteLn('Connection to ', NetAddrToStr(Comm.SocketStream.RemoteAddress.sin_addr),
      ' closed');
  end;

  procedure TSocketHandler.MessageRecieved(Sender: TObject);
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
          WriteLn('Message from ',
            NetAddrToStr(Comm.SocketStream.RemoteAddress.sin_addr),
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
    socket.RegisterHandler('*', '*', TSocketHandler.Create, True, True);
    socket.Start;
  finally
    socket.Free;
  end;
end.
