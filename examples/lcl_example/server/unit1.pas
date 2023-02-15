unit Unit1;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ssockets, Forms, Controls, Graphics, Dialogs, ExtCtrls,
  StdCtrls, eventserver, wsstream, wsmessages;

type

  { TForm1 }

  TForm1 = class(TForm)
    ClientsBox: TListBox;
    MessagesMemo: TMemo;
    Splitter1: TSplitter;
    TargetSelectorBox: TComboBox;
    HostnameEdit: TEdit;
    Panel1: TPanel;
    Panel2: TPanel;
    PortEdit: TEdit;
    MessageEdit: TEdit;
    StartStopButton: TButton;
    SendButton: TButton;
    procedure ClientsBoxDblClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure MessageEditChange(Sender: TObject);
    procedure SendButtonClick(Sender: TObject);
    procedure StartStopButtonClick(Sender: TObject);
  private
    FServer: TServerThread;
    procedure ClientConnected(AConnection: TWebsocketCommunicator);
    procedure ClientDisconnected(AConnection: TWebsocketCommunicator);
    procedure ClientMessage(AConnection: TWebsocketCommunicator);
  public

  end;

var
  Form1: TForm1;

implementation

{$R *.lfm}

{ TForm1 }

procedure TForm1.StartStopButtonClick(Sender: TObject);
begin
  if Assigned(FServer) then
  begin // Stop
    FServer.Terminate;
    FServer := nil;
    StartStopButton.Caption := 'Start';
    MessagesMemo.Lines.Add('Stopping Server...');
    Exit;
  end;
  // start
  MessagesMemo.Lines.Add('Starting Server on %s:%s'.Format([HostnameEdit.Text, PortEdit.Text]));
  FServer := TServerThread.Create(HostnameEdit.Text, StrToInt(PortEdit.Text));
  FServer.FreeOnTerminate := True;
  FServer.OnConnect := @ClientConnected;
  FServer.OnDisconnect :=@ClientDisconnected;
  FServer.OnMessage :=@ClientMessage;
  StartStopButton.Caption := 'Stop';
end;

procedure TForm1.FormCreate(Sender: TObject);
begin
  FServer := nil;
end;

procedure TForm1.ClientsBoxDblClick(Sender: TObject);
begin
  TargetSelectorBox.ItemIndex:=ClientsBox.ItemIndex + 1;
end;

procedure TForm1.FormDestroy(Sender: TObject);
var
  i: Integer;
begin
  if Assigned(FServer) then
  begin
    // To avoid any callbacks
    FServer.OnConnect:=nil;
    FServer.OnDisconnect:=nil;
    FServer.OnMessage:=nil;
    FServer.Terminate;
    // Allow for events that might be fired during this freeing to be handled before closing
    for i:=0 to 20 do
    begin
      Application.ProcessMessages;
      Sleep(10);
    end;
  end;
end;

procedure TForm1.MessageEditChange(Sender: TObject);
begin
  SendButton.Enabled := Assigned(FServer) and (Length(MessageEdit.Text) > 0);
end;

procedure TForm1.SendButtonClick(Sender: TObject);
var
  Target: TWebsocketCommunicator;
  i: Integer;
begin
  if TargetSelectorBox.ItemIndex > 0 then
  begin // Unicast
    Target := TargetSelectorBox.Items.Objects[TargetSelectorBox.ItemIndex] as TWebsocketCommunicator;
    Target.WriteStringMessage(MessageEdit.Text);
    MessagesMemo.Lines.Add('Message to %s: %s', [TargetSelectorBox.Items[TargetSelectorBox.ItemIndex], MessageEdit.Text]);
  end
  else
  begin // broadcast
    for i:=0 to ClientsBox.Count - 1 do
      (ClientsBox.Items.Objects[i] as TWebsocketCommunicator).WriteStringMessage(MessageEdit.Text); 
    MessagesMemo.Lines.Add('Broadcast: %s', [TargetSelectorBox.Items[TargetSelectorBox.ItemIndex], MessageEdit.Text]);
  end;
  MessageEdit.Clear;
end;

procedure TForm1.ClientConnected(AConnection: TWebsocketCommunicator);
var
  ClientName: String;
begin
  ClientName := '%s:%d'.Format([AConnection.SocketStream.RemoteAddress.Address,
                                AConnection.SocketStream.RemoteAddress.Port]);
  ClientsBox.Items.AddObject(ClientName, AConnection); 
  TargetSelectorBox.Items.AddObject(ClientName, AConnection);
  MessagesMemo.Lines.Add('Connection from ' + ClientName);
end;

procedure TForm1.ClientDisconnected(AConnection: TWebsocketCommunicator);
var
  ClientName: String;
  ToDelete: Integer;
begin
  ClientName := '%s:%d'.Format([AConnection.SocketStream.RemoteAddress.Address,
                                AConnection.SocketStream.RemoteAddress.Port]);
  ToDelete := ClientsBox.Items.IndexOf(ClientName);
  ClientsBox.Items.Delete(ToDelete);
  TargetSelectorBox.Items.Delete(ToDelete + 1);
  MessagesMemo.Lines.Add(ClientName + ' disconnected');
end;

procedure TForm1.ClientMessage(AConnection: TWebsocketCommunicator);
var
  MessageList: TWebsocketMessageOwnerList;
  Message: TWebsocketMessage;
  ClientName: String;
begin
  ClientName := '%s:%d'.Format([AConnection.SocketStream.RemoteAddress.Address,
                                AConnection.SocketStream.RemoteAddress.Port]);
  MessageList := TWebsocketMessageOwnerList.Create;
  try
    AConnection.GetUnprocessedMessages(MessageList);
    for Message in MessageList do
      if Message is TWebsocketStringMessage then
        MessagesMemo.Lines.Add('Message from ' + ClientName + ': ' + TWebsocketStringMessage(Message).Data);
  finally
    MessageList.Free;
  end;
end;

end.

