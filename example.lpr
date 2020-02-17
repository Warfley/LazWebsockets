program example;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}
  Classes, sysutils, WebSocket, utilities
  { you can add units after this };

type

  { TSocketHandler }

  TSocketHandler = class(TWebsocketHandler)
  function Accept(const ARequest: TRequestData; const ResponseHeaders: TStrings
  ): boolean; override;
  procedure DoHandleCommunication(ACommunication: TWebsocketCommunincator);
  override;
  end;

var
  socket: TWebSocketServer;

{ TSocketHandler }

function TSocketHandler.Accept(const ARequest: TRequestData;
  const ResponseHeaders: TStrings): boolean;
begin
  Result:=True;
end;

procedure TSocketHandler.DoHandleCommunication(
  ACommunication: TWebsocketCommunincator);
var
  msgList: TMessageOwnerList;
  m: TWebsocketMessage;
begin    
  msgList := TMessageOwnerList.Create(True);
  With ACommunication.WriteMessage do
  try
    WriteRaw('Hallo Welt!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!');
  finally
    Free;
  end;
  while True do
  begin
    msgList.Clear;
    ACommunication.GetUnprocessedMessages(msgList);
    for m in msgList do
      if m is TWebsocketStringMessage then
        WriteLn(TWebsocketStringMessage(m).Data);
    TThread.Yield;
  end;
end;

begin
  socket := TWebSocketServer.Create(80);
  socket.RegisterHandler('*', '*', TSocketHandler.Create, True, True);
  socket.Start;
end.

