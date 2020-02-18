# LazWebsocketsServer
This provides a small Websocket server implementation written for the FPC and Lazarus. 
It is fully based upon the fcl `ssockets` unit and therefore independent from any additional dependencies except from the FCL.
It can thereby easiely built only using fpc without Lazarus or complicated makefiles.

## Installation
There is a Lazarus package file (`websockets.lpk`) in this repository that can be used for Lazarus projects. An other option is to simply add the `src` directory to your unit search path.

## Usage & Functionality
For a simple example server see the `chatServer.pas` in the examples directory.
### Setting up the Server
To create a `TWebSocketServer` the constructor mirrors the constructor of `ssockets.TInetServer` and can be called with either only a port, or an address, port and optionally a `ssockets.TSocketHandler` (e.g. to provide TLS support).
So in order to create a simple WebSocket listener on port 8080 we can simply use:
```
  Server := TWebSocketServer.Create(8080);
```
The next step is to add Handlers for incoming connections. A Handler is an instance of a class inheriting from
```
TWebsocketHandler = class
public
  function Accept(const ARequest: TRequestData;
    const ResponseHeaders: TStrings): boolean; virtual;
  procedure HandleCommunication(ACommunicator: TWebsocketCommunincator); virtual;
end;
```
overriding both the virtual functions. `Accept` checks whether the given request shall be accepted, e.g. by checking the `Authorization` header transmitted via the HTTP request. It can also set header fields for the response, e.g. cookies.

`HandleCommunication` is then called after the Websocket stream is established. The `TWebsocketCommunincator` class contains all the functionality nessecary to recieve and transmit data. More about that later.

The handshake starts of with a simple HTTP request. Therefore a websocket handshake request contains usually an information about the host address as well as the path used.
E.g. when establishing a connection at myhost.com/websocket the host is `myhost.com` and the path is `/websocket` (note the slash at the beginning, this is important).
Similar to the FCL-Web webmodules, an handler for our WebsocketServer can be registered for a given host and path.

For doing so we provide the method:
```
procedure TWebSocketServer.RegisterHandler(const AHost: string; const APath: string;
    AHandler: TWebsocketHandler; DefaultHost: boolean = False;
    DefaultPath: boolean = False);
```
If `DefaultHost` is set to `True`, if the hostname of any request does not match any of the hosts, this hostname will be assumed. Similar the DefaultPath sets this handler as the default Handler for unrecognized paths on this host.

For our simple example we simply want to add one handler. As we make it the only handler, we make it the default for any host and path, meaning it doesn't matter what host or path we choose:
```
  Server.FreeHandlers := True;
  Server.RegisterHandler('*', '*', TSocketHandler.Create, True, True);
```
Note that neither host `*` nor path `*` have any special meaning, they acutally can't be matched to any valid host or path, but we don't care as we set it to the default it will be matched anyway.

The last configuration we can perform is to choose an accepting method via the property `TWebSocketServer.AcceptingMethod` which can take either the value `samDefault` which performs the Handshake in the same thread as the server is started, `samThreaded`, which spawns a new thread for the handshake and `samThreadPool`, which executes the handshake in a seperate thread, from a threadpool to save up on time for creating and destroying new threads.
The method chosen does not only impact the performance of the server handling requests, but also which thread the methods of the registered handler will be called. If `samDefault` is chosen, and the handler does not spawn new threads for the `HandleCommunication` method, no additional connection can be established until HandleCommunication is finished (i.e. the communication is done), making the server single threaded.

For this reason, as well as the fact that Websockets are best utilized using multiple threads, to be able to asynchronous read and write data, the `websockets` unit also provides the class `TThreadedWebsocketHandler`. This class spawns two new threads, a reciever thread, which in a loop tries to fetch new messages, as well as a handler thread, which calls `DoHandleCommunication`. To use this class, simply let your handler inherit from it and override `DoHandleCommunication` rather than `HandleCommunication`.

The last step now is to simply start our server with
```
  Server.Start;
```
It will then start accepting clients on this thread until `Server.Stop` is called.

### Recieving and Sending Messages
All the communication is done via the `TWebsocketCommunincator` class. It provides three basic methods for communication:
```
procedure RecieveMessage;
function GetUnprocessedMessages(const MsgList: TWebsocketMessageOwnerList): integer; 
function WriteMessage(MessageType: TWebsocketMessageType = wmtString;
  MaxFrameLength: int64 = 125): TWebsocketMessageStream;
```
`RecieveMessages` will recieve any incomming message. If it's a ping message, it will answer directly with a respective pong message. If the incoming message is a close request, it will answer with the respecitive close request and then close the connection. Any other message (String, Binary or Pong Message) will be added the internal message queue. Messages from that queue can be retrieved via the method `GetUnprocessedMessage` and than be processed. This is implemented thread safe, meaning the message queue is internally locked, so RecieveMessages and GetUnprocessedMessages can be called from different threads.

Lastly we have `WriteMessage` which creates a `TWebsocketMessageStream` for us to send messages to the client. These should be either string (`wmtString`), binary (`wmtBinary`) or ping (`wmtPing`) messages. After a ping, the responding pong will be recieved by RecieveMessages and can be processed by the user as any other message.

While `RecieveMessage` is blocking until at least one message is read. But it is implemented thread safe, meaning you can send messages while reading, without problems. This is archived by locking, while in general not nessecary as reading and writing can technically be done in parallel, but to avoid complications we lock stream access

Besides those the `TWebsocketCommunincator` class also provides two properties:
```
property SocketStream: TLockedSocketStream;
property Open: boolean;
```
`SocketStream` grants access to the raw underlying connection and `Open` can be used to check whether the stream is still open.

Lastly the communicator provides two events:
```
property OnRecieveMessage: TNotifyEvent;
property OnClose: TNotifyEvent; 
```
`OnRecieveMessage` is triggered when `RecieveMessages` adds a new message to the message queue and `OnClose` will be triggered when the stream closes, either due to an abrupt disconnect of the underlying TCP stream (detected by a stream reding error while recieving Messages) or after sending the close message. It will be called before the `TSocketStream` object will be destroyed, so you still have access to it, e.g. to its `RemoteAddress` attribute to identify the client. Both of these events are fired in the context of the thread discovering them, most likely the thread calling `RecieveMessages`. Any cross thread accesses need to be secured by the user, either using `TThread.Queue`, `TThread.Synchronize`, `critical sections` or any other method of handling inter-thread communications.

## Example
The `chatServer` example can be built in multiple ways. Either by opening the Lazarus project (`examples/chatServer.lpi`) and building it with the IDE, or by using make in the examples directory, or by using the fpc directly via:
```
$> fpc -Fu ../src chatServer.pas
```
The client for this is the html document `chatClient.html` and should be usable with any modern browser. The example is a simple chat that lets the user input text messages to send to the other party, and recieve their messages asynchronously. You can try to connect with multiple clients at once to the server as it uses a threaded handler, but isn't built for reading more than a message for one client at a time, so funny things might happen.
