# LazWebsockets
This provides a small Websocket server and client implementation written for the FPC and Lazarus. 
It is fully based upon the fcl `ssockets` unit and therefore independent from any additional dependencies except from the FCL.
It can thereby easiely built only using fpc without Lazarus or complicated makefiles.

## Installation
There is a Lazarus package file (`websockets.lpk`) in this repository that can be used for Lazarus projects. An other option is to simply add the `src` directory to your unit search path.

## Usage & Functionality
For a simple example server see the `chatServer.pas` and `chatClient.pas` in the examples directory.
### Setting up the Server
To create a `TWebSocketServer` the constructor mirrors the constructor of `ssockets.TInetServer` and can be called with either only a port, or an address, port and optionally a `ssockets.TSocketHandler` (e.g. to provide TLS support).
So in order to create a simple WebSocket listener on port 8080 we can simply use:
```pascal
  Server := TWebSocketServer.Create(8080);
```
The next step is to add Handlers for incoming connections. A Handler is an instance of a class inheriting from
```pascal
  TWebsocketHandler = class
  private
    FConnections: TThreadedConnectionList;
  public
    constructor Create;
    destructor Destroy; override;

    function Accept(const ARequest: TRequestData;
      const ResponseHeaders: TStrings): boolean; virtual;
    procedure HandleCommunication(ACommunicator: TWebsocketCommunincator); virtual;
    procedure PrepareCommunication(ACommunicator: TWebsocketCommunincator); virtual;
    procedure DoHandleCommunication(ACommunicator: TWebsocketCommunincator); virtual;
    procedure FinalizeCommunication(ACommunicator: TWebsocketCommunincator); virtual;

    property Connections: TThreadedConnectionList read FConnections;
  end;
```
overriding at least the the virtual functions `Accept` and `DoHandleCommunications`. `Accept` checks whether the given request shall be accepted, e.g. by checking the `Authorization` header transmitted via the HTTP request. It can also set header fields for the response, e.g. cookies.

After the Websocket stream is established, `HandleCommunication` will be called, which in turn will simply call `PrepareCommunication` `DoHandleCommunication` and `FinalizeCommunication` with a `TWebsocketCommunincator` as argument. The `TWebsocketCommunicator` class contains all the functionality nessecary to recieve and transmit data. More about that later.

`TWebsocketHandler` automatically manages the `TWebsocketCommunicator` objects. All active connections are located in the `Connections` property, a thread safe list. `PrepareCommunication` will add the objects to that list and `FinalizeCommunication` will remove them, close them if this was not already done and free the instances. Therefore it is mandatory to call these functions in any inherited class.

In most cases it is completely sufficient to only override `DoHandleCommunication` and/or `Accept` (if any acceptance criteria exists). If you override `PrepareCommunication`, `FinalizeCommunication` or `HandleCommunication` be sure you fully understand what you are doing.

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

For this reason, as well as the fact that Websockets are best utilized using multiple threads, to be able to asynchronous read and write data, the `websockets` unit also provides the class `TThreadedWebsocketHandler`. This class spawns two new threads, a reciever thread, which in a loop tries to fetch new messages, as well as a handler thread, which calls `DoHandleCommunication`. To use this class, simply let your handler inherit from it instead of `TWebsocketHandler`.

The last step now is to simply start our server with
```
  Server.Start;
```
It will then start accepting clients on this thread until `Server.Stop` is called.

### Setting up the Client
To establish a client connection the class `TWebsocketClient` is provided. Its constructor takes three parameters, the `Host` and optionally `Port` and `Path`. If these are not given the default (port 80 and path /) will be used. These can be changed afterwards through their respective properties.

To establish the connection then simply call
```
function Connect(AHandler: TSocketHandler = nil): TWebsocketCommunincator;
```

Besides those the class also provides a few properties:
```
property CustomHeaders: TStrings;
property OnHandshakeSuccess: TWebsocketHandshakeResponseEvent;
property OnHandshakeFailure: TWebsocketHandshakeResponseEvent;
```
`CustomHeaders` can be used to add headers to the HTTP handshake, e.g. an authorization header. The two events are triggered after the handshake, on success or failure respectively. The events get some information about the server response passed, this includes the headers (e.g. for recieving cookies), but also the content and statuscode, in case of a failure (e.g. to check against 404 or 403).

### Recieving and Sending Messages
All the communication is done via the `TWebsocketCommunincator` class. For recieving messages it contains the following methods:
```pascal
    function RecieveMessage: TWebsocketMessage;
    procedure StartRecieveMessageThread;
    procedure StopRecieveMessageThread;
    function RecieveMessageThreadRunning: Boolean;
    function InRecieveMessageThread: Boolean;
    function HasMessages: Boolean;
    function GetUnprocessedMessages(const MsgList: TWebsocketMessageOwnerList): integer;
    function WaitForMessage(MessageTypes: TWebsocketMessageTypes=[wmtString, wmtBinary, wmtPong]
      ): TWebsocketMessage;
    function WaitForStringMessage: TWebsocketStringMessage; inline;
    function WaitForBinaryMessage: TWebsocketBinaryMessage; inline;
    function WaitForPongMessage: TWebsocketPongMessage; inline;
```
`RecieveMessage` will block until a message was recieved. If the message was a binary or string message, it will be returned. If the message was a Pong message, the message will be added the internal message queue. It will also handle all control frames like pings or close frames transparently. Only use this method if you know what you are doing.
To simply handle all incoming messages, you can use `StartRecieveMessageThread` to start a new thread that will continously check for incoming messages and add them to the internal message queue.

Messages from that queue can be retrieved via the method `GetUnprocessedMessage` and than be processed. This is implemented thread safe, meaning the message queue is internally locked, so RecieveMessages and GetUnprocessedMessages can be called from different threads. This thread can be stopped via `StopRecieveMessageThread` (will take effect after the next message was read) and can be checked if it is running using `RecieveMessageThreadRunning`.

The internal message queue is a thread safe list object, that can be emptied via `GetUnprocessedMessages`. Whenever a new element is added to the queue, it will trigger the `OnRecieveMessage` event. This event is triggered from within the thread that has recieved the message. if you want to interact with other threads, e.g. the GUI thread, potential synchronization is needed. To check if you are currently within the recieve message thread, you can use `InRecieveMessageThread`.

If you are expecting a message and want to wait for it, you can use `WaitForMessage`, `WaitForStringMessage`, `WaitForBinaryMessage` or `WaitForPongMessage`. Unlike RecieveMessage, these function also return Pong messages, but also work in the asynchronous mode (when a reciever thread is running) as well as in the synchronous mode (i.e. calling recievethread itself). If any other messages arrived during this process, that are not the type of message you are waiting for, it will call the `OnRecieveMessage` event from within the current thread.

For writing we have `WriteMessage` and the three helper functions `WriteRawMessage`, `WriteStringMessage` and `WriteBinaryMessage`:
```pascal
    function WriteMessage(MessageType: TWebsocketMessageType = wmtString;
      MaxFrameLength: int64 = Word.MaxValue): TWebsocketMessageStream;
    procedure WriteRawMessage(const AMessage; ALength: SizeInt;
      AMessageType: TWebsocketMessageType = wmtString); inline;
    procedure WriteStringMessage(const AMessage: String); inline;
    procedure WriteBinaryMessage(const AMessage: TBytes); inline;
```

`WriteMessage` creates a `TWebsocketMessageStream` for us to send messages to the client. These should be either string (`wmtString`), binary (`wmtBinary`) or ping (`wmtPing`) messages. After a ping, the responding pong will be recieved by RecieveMessages and can be processed by the user as any other message.
`WriteRawMessage` will take a buffer and will write that wholy into the stream and close the stream afterwards. `WriteStringMessage` and `WriteBinaryMessage` will open a stream, write data from a string/array into it and close the stream afterwards. These three helper functions can be used to avoid the boilerplate code of opening the stream and having to free it afterwards, but don't support fragmentation.

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
The `chatServer` and `broadcastServer` example can be built in multiple ways. Either by opening the Lazarus project (`examples/chatServer.lpi` and `examples/chatClient.lpi`, `examples/broadcastServer.lpi`) and building it with the IDE, or by using `make` in the examples directory, or by calling the fpc directly via:
```
$> fpc -Fu../src chatServer.pas
$> fpc -Fu../src chatClient.pas
$> fpc -Fu../src broadcastServer.pas
```
An alternative JavaScript based client for the server can be found in the html document `chatClient.html` and should be usable with any modern browser. The example is a simple chat that lets the user input text messages to send to the other party, and recieve their messages asynchronously. You can try to connect with multiple clients at once to the server as it uses a threaded handler, but isn't built for reading more than a message for one client at a time, so funny things might happen.
The `chatClient.pas` example can also send special codes: by typing `exit` the connection will be closed gracefully and with `ping message` a ping with `message` as content can be sent.

The `chatServer` simply allows clients to connect and can recive and send messages. The `broadcastServer` allows clients to connect and sends all messages sent to it to all currently connected clients.

## Thread Pooling
Creating threads is slow, which is why this library implements the ability for thread pooling. 
This means instead of destroying a thread once it is finished, it will be waiting in the background to be reused when necessary.
Thread pooling is enabled by default. In some situations it might be helpful to deactivate thread pooling, especially if you run into problems like deadlocks or memory issues.

To deactivate thread pooling simply call the constructor of `TThreadedWebsocketHandler` with the argument `pooling` set to `False`, i.e. `TMySocketHandler.Create(False)` or if your handler has it's own constructor, call `inherited Create(False);` from there.

The handshake is by default not threaded, see the `TWebsocketServer.AcceptingMethod` property for further information
