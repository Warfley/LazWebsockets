program example;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}
  Classes, sysutils, WebSocket, utilities
  { you can add units after this };


var
  socket: TWebSocketServer;
begin
  socket := TWebSocketServer.Create(8070);
  socket.Start;
end.

