program broadcastServer;

{$mode objfpc}{$H+}

uses {$IFDEF UNIX}
  cthreads, {$ENDIF}
  sysutils,
  classes,
  wsutils,
  wsmessages,
  wsstream,
  websocketserver,
  Generics.Collections;

type

  { TNamedWebsocketCommunicator }

  TNamedWebsocketCommunicator = class(TWebsocketCommunicator)
  private
    FName: String;
  public
    constructor Create(AStream: TLockedSocketStream; AMaskMessage: boolean;
  AssumeMaskedMessages: boolean);

    function GetInfo: String;

    property Name: string read FName write FName;
  end;

  { TSocketHandler }

  TSocketHandler = class(TThreadedWebsocketHandler)
  private type
    TConnectionList = class(specialize TList<TNamedWebsocketCommunicator>);
    TLockedConnectionList = class(specialize TThreadedObject<TConnectionList>);
  private
    FConnections: TLockedConnectionList;

    procedure ConnectionClosed(Sender: TObject);
    procedure MessageReceived(Sender: TObject);
    procedure HandleMessage(const AMessage: String; ACommunicator: TNamedWebsocketCommunicator);

  protected
    procedure PrepareCommunication(ACommunicator: TWebsocketCommunicator); override;
    procedure DoHandleCommunication(ACommunication: TWebsocketCommunicator);
      override;
    procedure FinalizeCommunication(ACommunicator: TWebsocketCommunicator);
  override;

  public
    constructor Create(Pooling: Boolean=True);
    destructor Destroy; override;

    function CreateCommunicator(DataStream: TLockedSocketStream;
  AHeader: THttpHeader): TWebsocketCommunicator; override;
    procedure BroadcastMessage(message: String);
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

  { TNamedWebsocketCommunicator }

  constructor TNamedWebsocketCommunicator.Create(
      AStream: TLockedSocketStream; AMaskMessage: boolean;
      AssumeMaskedMessages: boolean);
  begin
    inherited Create(AStream, AMaskMessage, AssumeMaskedMessages);
    FName := 'Anonymous';
  end;

  function TNamedWebsocketCommunicator.GetInfo: String;
  begin
    Result := '%s at %s:%d'.Format([Name, SocketStream.RemoteAddress.Address, SocketStream.RemoteAddress.Port]);
  end;

  { TSocketHandler } 

  procedure TSocketHandler.ConnectionClosed(Sender: TObject);
  var
    Comm: TNamedWebsocketCommunicator;
  begin
    Comm := TNamedWebsocketCommunicator(Sender);
    BroadcastMessage('[%s] left the broadcast'.Format([Comm.GetInfo]));
  end;

  procedure TSocketHandler.MessageReceived(Sender: TObject);
  var
    Messages: TWebsocketMessageOwnerList;
    m: TWebsocketMessage;
    Comm: TNamedWebsocketCommunicator;
  begin
    Comm := TNamedWebsocketCommunicator(Sender);
    Messages := TWebsocketMessageOwnerList.Create(True);
    try
      Comm.GetUnprocessedMessages(Messages);
      for m in Messages do
        if m is TWebsocketStringMessage then
        begin
          HandleMessage(TWebsocketStringMessage(m).Data, Comm);
        end;
    finally
      Messages.Free;
    end;
  end;

  procedure TSocketHandler.HandleMessage(const AMessage: String;
    ACommunicator: TNamedWebsocketCommunicator);
  var
    NewName, Info: String;
  begin
    Info := ACommunicator.GetInfo;
    if AMessage.StartsWith('call me ') then
    begin
      // Renaming
      NewName := AMessage.Substring(8); // after "call me "
      ACommunicator.Name := NewName;
      BroadcastMessage('[%s] Changed their name to %s'.Format([Info, NewName]));
      Exit;
    end;
    BroadcastMessage('[%s] says: %s'.Format([Info, AMessage]));
  end;

  procedure TSocketHandler.PrepareCommunication(
    ACommunicator: TWebsocketCommunicator);
  var
    ConnectionList: TConnectionList;
  begin
    ConnectionList := FConnections.Lock;
    try
      ConnectionList.Add(TNamedWebsocketCommunicator(ACommunicator));
    finally
      FConnections.Unlock;
    end;
  end;

  procedure TSocketHandler.DoHandleCommunication(
    ACommunication: TWebsocketCommunicator);
  begin
    BroadcastMessage('[%s] joined the broadcast'.Format([TNamedWebsocketCommunicator(ACommunication).GetInfo]));
    ACommunication.OnReceiveMessage := @MessageReceived;
    ACommunication.OnClose := @ConnectionClosed;
    // Just keep the communication open
    while ACommunication.Open do
      Sleep(10);
  end;

  procedure TSocketHandler.FinalizeCommunication(
    ACommunicator: TWebsocketCommunicator);
  var
    ConnectionList: TConnectionList;
  begin
    ConnectionList := FConnections.Lock;
    try
      ConnectionList.Remove(TNamedWebsocketCommunicator(ACommunicator));
    finally
      FConnections.Unlock;
    end;
    inherited FinalizeCommunication(ACommunicator);
  end;

  constructor TSocketHandler.Create(Pooling: Boolean);
  begin
    inherited Create(Pooling);
    FConnections := TLockedConnectionList.Create(TConnectionList.Create);
  end;

  destructor TSocketHandler.Destroy;
  var
    ConnectionList: TConnectionList;
    Connection: TNamedWebsocketCommunicator;
  begin
    ConnectionList := FConnections.Lock;
    try
      for Connection in ConnectionList do
        Connection.Close(True);
    finally
      FConnections.Unlock;
    end;
    Sleep(100);
    FConnections.Free;
    inherited Destroy;
  end;

  function TSocketHandler.CreateCommunicator(DataStream: TLockedSocketStream;
    AHeader: THttpHeader): TWebsocketCommunicator;
  begin
    Result := TNamedWebsocketCommunicator.Create(DataStream, False, True);
  end;

  procedure TSocketHandler.BroadcastMessage(message: String);
  var
    ConnectionList: TConnectionList;
    Connection: TWebsocketCommunicator;
  begin
    WriteLn('Broadcasting: ', message);
    ConnectionList := FConnections.Lock;
    try
      for Connection in ConnectionList do
        Connection.WriteStringMessage(message);
    finally
      FConnections.Unlock;
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
        handler.BroadcastMessage('[Server] says: ' + cmdline.Substring(cmdpos));
    end;
  end;

begin
  socket := TWebSocketServer.Create(8080);
  try
    socket.FreeHandlers := True;
    handler := TSocketHandler.Create;
    socket.RegisterHandler('*', '/ws', handler, True, True);
    TCLIThread.Create;
    socket.Start;
  finally
    socket.Free;
  end;
end.
