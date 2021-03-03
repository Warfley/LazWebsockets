unit wsmessages;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl, wsutils;

type
  // Represent opcodes
  TWebsocketMessageType = (wmtContinue = 0, wmtString = 1, wmtBinary =
    2, wmtClose = 8, wmtPing = 9, wmtPong = 10);
  TWebsocketMessageTypes = set of TWebsocketMessageType;

  { TWebsocketMessage }

  TWebsocketMessage = class
  private
    FMessageType: TWebsocketMessageType;
  public
    constructor Create(const AMessageType: TWebsocketMessageType);
    property MessageType: TWebsocketMessageType read FMessageType;
  end;

  { TWebsocketStringMessage }

  TWebsocketStringMessage = class(TWebsocketMessage)
  private
    FData: UTF8String;
  public
    constructor Create(const AData: UTF8String);
    property Data: UTF8String read FData;
  end;

  { TWebsocketPongMessage }

  TWebsocketPongMessage = class(TWebsocketMessage)
  private
    FData: UTF8String;
  public
    constructor Create(const AData: UTF8String);
    property Data: UTF8String read FData;
  end;

  { TWebsocketBinaryMessage }

  TWebsocketBinaryMessage = class(TWebsocketMessage)
  private
    FData: TBytes;
  public
    constructor Create(const AData: TBytes);
    property Data: TBytes read FData;
  end;

  TWebsocketMessageList = class(specialize TFPGList<TWebsocketMessage>);
  TWebsocketMessageOwnerList = class(specialize TFPGObjectList<TWebsocketMessage>);
  TLockedWebsocketMessageList = class(specialize TThreadedObject<TWebsocketMessageList>);

implementation


{ TWebsocketMessage }

constructor TWebsocketMessage.Create(const AMessageType: TWebsocketMessageType);
begin
  FMessageType := AMessageType;
end;

{ TWebsocketStringMessage }

constructor TWebsocketStringMessage.Create(const AData: UTF8String);
begin
  inherited Create(wmtString);
  FData := AData;
  SetLength(FData, Length(FData));
end;

{ TWebsocketPongMessage }

constructor TWebsocketPongMessage.Create(const AData: UTF8String);
begin
  inherited Create(wmtPong);
  FData := AData;
  SetLength(FData, Length(FData));
end;

{ TWebsocketBinaryMessage }

constructor TWebsocketBinaryMessage.Create(const AData: TBytes);
begin
  inherited Create(wmtBinary);
  FData := AData;
  SetLength(FData, Length(FData));
end;

end.

