{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit Websockets;

{$warn 5023 off : no warning about unused units}
interface

uses
  WebSocketServer, wsutils, wsmessages, wsstream, LazarusPackageIntf;

implementation

procedure Register;
begin
end;

initialization
  RegisterPackage('Websockets', @Register);
end.
