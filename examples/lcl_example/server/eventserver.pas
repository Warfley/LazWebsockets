unit eventserver;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, WebSocketServer, wsstream, Forms;

type

  TCommunicatorEvent = procedure(AConnection: TWebsocketCommunicator) of object;

  { TServerThread }

  TServerThread = class(TThread)
  private
    FServer: TWebSocketServer;
    FConnections: TThreadedConnectionList;

    FOnConnect: TCommunicatorEvent;
    FOnDisconnect: TCommunicatorEvent;
    FOnMessage: TCommunicatorEvent;

    procedure CommunicatorReceivedMessage(Sender: TObject);
    procedure CommunicatorDisconnected(Sender: TObject);
    procedure DisconnectedHandler(Data: IntPtr);
  protected
    procedure Execute; override;
    procedure TerminatedSet; override;

    procedure CommunicatorConnected(Communicator: TWebsocketCommunicator);

  public
    constructor Create(const HostName: String; Port: Integer);
    destructor Destroy; override;

    property OnConnect: TCommunicatorEvent read FOnConnect write FOnConnect;
    property OnMessage: TCommunicatorEvent read FOnMessage write FOnMessage;
    property OnDisconnect: TCommunicatorEvent read FOnDisconnect write FOnDisconnect;
  end;   

  { TNonSerialWebsocketHandler }

  TNonSerialWebsocketHandler = class(TWebsocketHandler)
  private
    FServerThread: TServerThread;
  public
    constructor Create(AServerThread: TServerThread);
    procedure HandleCommunication(ACommunicator: TWebsocketCommunicator);
      override;
  end;

implementation

{ TServerThread }

procedure TServerThread.CommunicatorReceivedMessage(Sender: TObject);
begin
  if Assigned(FOnMessage) then
    Application.QueueAsyncCall(TDataEvent(FOnMessage), IntPtr(Sender));
end;

procedure TServerThread.CommunicatorDisconnected(Sender: TObject);
begin
  Application.QueueAsyncCall(@DisconnectedHandler, IntPtr(Sender));
end;

procedure TServerThread.DisconnectedHandler(Data: IntPtr);
var
  Conn: TWebsocketCommunicator;
  ConnectionList: TConnectionList;
begin
  Conn := TWebsocketCommunicator(Data); 
  // Unlike OnDisconnect this is executed on the mainthread so we cann call the event
  if Assigned(FOnDisconnect) then
    FOnDisconnect(Conn);
  // Stop receiving
  Conn.StopReceiveMessageThread;
  // After event finished, remove from connection list
  // This will also free the connection
  ConnectionList := FConnections.Lock;
  try
    ConnectionList.Remove(Conn);
  finally
    FConnections.Unlock;
  end;
end;

procedure TServerThread.Execute;
begin
  FServer.Start;
end;

procedure TServerThread.TerminatedSet;
begin
  FServer.Stop(True);
  inherited TerminatedSet;
end;

procedure TServerThread.CommunicatorConnected(
  Communicator: TWebsocketCommunicator);
var
  ConnectionList: TConnectionList;
begin
  ConnectionList := FConnections.Lock;
  try
    ConnectionList.Add(Communicator);
  finally
    FConnections.Unlock;
  end;

  Communicator.OnReceiveMessage := @CommunicatorReceivedMessage;
  Communicator.OnClose := @CommunicatorDisconnected;

  if Assigned(FOnConnect) then
    Application.QueueAsyncCall(TDataEvent(FOnConnect), IntPtr(Communicator));
end;

constructor TServerThread.Create(const HostName: String; Port: Integer);
begin
  FServer := TWebSocketServer.Create(HostName, Port, nil);
  FServer.RegisterHandler('*', '*', TNonSerialWebsocketHandler.Create(self), True, True);
  FConnections := TThreadedConnectionList.Create(TConnectionList.Create);
  inherited Create(False);
end;

destructor TServerThread.Destroy;
var
  Connections: TConnectionList;
  FirstConnection: TWebsocketCommunicator;
begin
  // When the connection is closed, it will be removed from the connection list
  // THis requires locking the connection list
  // So to avoid a deadlock we need to get the first connection of the list
  // Unlock the list, so it can be locked by the closing of that connection
  repeat
    FirstConnection := nil;
    Connections := FConnections.Lock;
    try
      if Connections.Count > 0 then
        FirstConnection := Connections.First;
    finally
      FConnections.Unlock;
    end;
    if Assigned(FirstConnection) then
      FirstConnection.Close;
    Sleep(20);
  until not Assigned(FirstConnection);
  FConnections.Free;
  FServer.Free;
  inherited Destroy;
end;

{ TNonSerialWebsocketHandler }

constructor TNonSerialWebsocketHandler.Create(AServerThread: TServerThread);
begin
  inherited Create;
  FServerThread := AServerThread;
end;

procedure TNonSerialWebsocketHandler.HandleCommunication(
  ACommunicator: TWebsocketCommunicator);
begin
  FServerThread.CommunicatorConnected(ACommunicator);
  ACommunicator.StartReceiveMessageThread;
end;

end.

