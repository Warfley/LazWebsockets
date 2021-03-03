unit wsutils;

{$mode objfpc}{$H+}
{$ModeSwitch advancedrecords}

interface

uses
  Classes, SysUtils, gvector, fgl, {$IfDef WINDOWS}windows{$Else}unixtype, pthreads{$EndIf};

type    

  { THttpHeader }

  THttpHeader = class(specialize TFPGMap<string, string>)
  public
    procedure Parse(const HeaderString: string);
    constructor Create;
  end;

  { TThreadedData }

  generic TThreadedData<T> = record
  public type PT = ^T;
  private
    FData: T;
    FLock: TRTLCriticalSection;
  public
    procedure Init(const AValue: T);
    procedure Done;
    function Lock: PT;
    procedure Unlock;
  end;

  { TThreadedObject }

  generic TThreadedObject<T> = class
  private
    FObject: T;
    FLock: TRTLCriticalSection;
  public
    constructor Create(const AObject: T);
    destructor Destroy; override;

    function Lock: T;
    procedure Unlock;
  end;

  { TMutex }

  TMutex = record
  private
    {$IfDef WINDOWS}
    semaphore: HANDLE;
    {$Else}
    mutex: pthread_mutex_t;
    {$EndIf}
  public
    procedure Init;
    procedure Done;
    function Lock: Boolean;
    procedure Unlock;
  end;

  { TPoolableThread }

  generic TPoolableThread<T> = class(TThread)
  private
    FLock: TMutex;
    FIdle: Boolean;
    FStopped: Boolean;
    FTaskArg: T;
    FPooling: Boolean;
  protected
    procedure ExecuteTask(constref Arg: T); virtual; abstract;
    procedure Execute; override;
  public
    constructor Create(Pooling: Boolean);
    destructor Destroy; override;

    procedure Start(const Arg: T); virtual;
    procedure Stop; virtual;
    procedure Kill; virtual;
    property Stopped: Boolean read FStopped;
    property IsIdle: Boolean read FIdle;
  end;

  { TThreadPool }

  generic TThreadPool<TThreadTypeArg> = class
  public type TThreadType = TThreadTypeArg;
  private type TThreadList = class(specialize TFPGList<TThreadType>);
  private
    FWorking: TThreadList;
    FIdle: TThreadList;
    FPooling: Boolean;
    procedure Cleanup;
    function CreateThread: TThreadType;
  public
    constructor Create(Pooling: Boolean);
    destructor Destroy; override;
    function GetThread: TThreadType;
  end;

  { TStreamHelper }

  TStreamHelper = class helper for TStream
  public
    function ReadRaw(const Count: Integer): String;
    procedure ReadTo(const pattern: string; out Result: string; MaxLen: integer = 1024);
    procedure WriteRaw(const Data: string);
  end;

  { TStringObjectMap }

  generic TStringObjectMap<T> = class
  private
    type
    TStrObjMap = class(specialize TFPGMap<string, T>);
  private
    FObjects: TStrObjMap;
    FDefaultObject: T;
    FFreeObjects: boolean;

    function GetObject(const AKey: string): T;
    procedure SetDefault(AValue: T);
    procedure SetObject(const AKey: string; AValue: T);
  public
    constructor Create(FreeObjects: boolean);
    destructor Destroy; override;

    procedure RemoveHandler(const AKey: string);
    function TryGetObject(const AKey: string; out AObject: T): boolean;

    property DefaultObject: T read FDefaultObject write SetDefault;
    property Objects[const AKey: string]: T read GetObject write SetObject; default;
  end;

implementation 

{ THttpHeader }

function DoHeaderKeyCompare(const Key1, Key2: string): integer;
begin
  // Headers are case insensetive
  Result := CompareStr(Key1.ToLower, Key2.ToLower);
end;

{ TThreadedData }

procedure TThreadedData.Init(const AValue: T);
begin
  InitCriticalSection(FLock);
  FData := AValue;
end;

procedure TThreadedData.Done;
begin
  DoneCriticalSection(FLock);
end;

function TThreadedData.Lock: PT;
begin
  EnterCriticalSection(FLock);
  Result := @FData;
end;

procedure TThreadedData.Unlock;
begin
  LeaveCriticalSection(FLock);
end;

procedure THttpHeader.Parse(const HeaderString: string);
var
  sl: TStringList;
  s: string;
  p: integer;
begin
  sl := TStringList.Create;
  try
    sl.TextLineBreakStyle := tlbsCRLF;
    sl.Text := HeaderString;
    for s in sl do
    begin
      // Use sl.Values instead?
      p := s.IndexOf(':');
      if p > 0 then
        Self.KeyData[s.Substring(0, p).ToLower] := s.Substring(p + 1).Trim;
    end;
  finally
    sl.Free;
  end;
end;

constructor THttpHeader.Create;
begin
  inherited Create;
  Self.OnKeyCompare := @DoHeaderKeyCompare;
  // Binary search => faster access
  Self.Sorted := True;
end;

{ TStringObjectMap }

function TStringObjectMap.GetObject(const AKey: string): T;
begin
  if not FObjects.TryGetData(AKey, Result) then
    Result := DefaultObject;
end;

procedure TStringObjectMap.SetDefault(AValue: T);
begin
  if FDefaultObject = AValue then
    Exit;
  if FFreeObjects and (FObjects.IndexOfData(AValue) < 0) then
    FDefaultObject.Free;
  FDefaultObject := AValue;
end;

procedure TStringObjectMap.SetObject(const AKey: string; AValue: T);
var
  tmp: T;
begin
  if FObjects.TryGetData(AKey, tmp) then
    tmp.Free;
  FObjects[AKey] := AValue;
end;

constructor TStringObjectMap.Create(FreeObjects: boolean);
begin
  FObjects := TStrObjMap.Create;
  FObjects.Sorted := True;
  FFreeObjects := FreeObjects;
end;

destructor TStringObjectMap.Destroy;
var
  i: integer;
begin
  if FFreeObjects then
  begin
    for i := 0 to FObjects.Count - 1 do
    begin
      if FObjects.Data[i] = FDefaultObject then
        FDefaultObject := nil;
      FObjects.Data[i].Free;
    end;
    FDefaultObject.Free;
  end;
  FObjects.Free;
  inherited Destroy;
end;

procedure TStringObjectMap.RemoveHandler(const AKey: string);
var
  idx: integer;
begin
  if FObjects.Find(AKey, idx) then
  begin
    if FDefaultObject = FObjects.Data[idx] then
      FDefaultObject := nil;
    if FFreeObjects then
      FObjects.Data[idx].Free;
    FObjects.Delete(idx);
  end;
end;

function TStringObjectMap.TryGetObject(const AKey: string; out AObject: T): boolean;
begin
  Result := FObjects.TryGetData(AKey, AObject);
end;

{ TThreadedObject }

constructor TThreadedObject.Create(const AObject: T);
begin
  InitCriticalSection(FLock);
  FObject := AObject;
end;

destructor TThreadedObject.Destroy;
begin
  Lock;
  try
    FObject.Free;
  finally
    Unlock;
  end;
  DoneCriticalsection(FLock);
  inherited Destroy;
end;

function TThreadedObject.Lock: T;
begin
  EnterCriticalsection(FLock);
  Result := FObject;
end;

procedure TThreadedObject.Unlock;
begin
  LeaveCriticalsection(FLock);
end;        

{ TStreamHelper }

function TStreamHelper.ReadRaw(const Count: Integer): String;
begin
  if Count <= 0 then Exit;
  SetLength(Result, Count);
  ReadBuffer(Result[1], Count);
end;

{* -----------------------------------------------------------------------------
 * Reads a stream until a pattern is found, maxlen is reached or an exception
 * is thrown.
 * On exception the result will still be a valid string. Can be used to read
 * until End of Stream
 * ----------------------------------------------------------------------------}
procedure TStreamHelper.ReadTo(const pattern: string; out Result: string;
  MaxLen: integer);
var
  c: char;
  len: integer;
  pLen: integer;
  backtrack: integer;
begin  
  if MaxLen <= 0 then Exit;
  SetLength(Result, 128);
  len := 0;
  plen := 0;
  backtrack := 0;
  try
    while len < MaxLen do
    begin
      c := char(Self.ReadByte);
      Result[len + 1] := c;
      Inc(len);
      if len = Result.Length then
        SetLength(Result, Result.Length * 2);
      if pattern[pLen + 1] = c then
      begin
        if plen = 0 then
        begin
          backtrack := len;
        end;
        Inc(pLen);
        if pLen = pattern.Length then
          Exit;
      end
      else if plen > 0 then
      begin
        pLen := 0;
        while backtrack + pLen < len do
        begin
          if pattern[pLen + 1] = Result[backtrack + pLen + 1] then
            Inc(pLen)
          else
          begin
            pLen := 0;
            Inc(backtrack);
          end;
        end;
      end;
    end;
  finally
    SetLength(Result, len);
  end;
end;

{* -----------------------------------------------------------------------------
 * HTTP writes plaintext, so this is a wrapper for .Write for ommiting the
 * Count parameter
 * ----------------------------------------------------------------------------}
procedure TStreamHelper.WriteRaw(const Data: string);
begin
  if Data.Length = 0 then Exit;
  self.WriteBuffer(Data[1], Data.Length);
end;

{ TMutex }

procedure TMutex.Init;
begin
  {$IfDef WINDOWS}
  semaphore := CreateSemaphore(nil, 1, 1, nil);
  {$Else}
  pthread_mutex_init(@mutex, nil);
  {$EndIf}
end;

procedure TMutex.Done;
begin
  {$IfDef WINDOWS}
  CloseHandle(semaphore);
  {$Else}
  pthread_mutex_destroy(@mutex);
  {$EndIf}
end;

function TMutex.Lock: Boolean;
begin
  {$IfDef WINDOWS}
  Result := WaitForSingleObject(semaphore, INFINITE) = WAIT_OBJECT_0;
  {$Else}
  Result := pthread_mutex_lock(@mutex) = 0;
  {$EndIf}
end;

procedure TMutex.Unlock;
begin
  {$IfDef WINDOWS}
  ReleaseSemaphore(semaphore, 1, nil);
  {$Else}
  pthread_mutex_unlock(@mutex);
  {$EndIf}
end;

{ TThreadPool }

procedure TThreadPool.Cleanup;
var
  Worker: TThreadType;
  i: SizeInt;
begin
  i := 0;
  while i < FWorking.Count do
  begin
    Worker := FWorking[i];
    if Worker.isIdle then
    begin
      FIdle.Add(Worker);
      // swap delete
      FWorking[i] := FWorking[FWorking.Count - 1];
      FWorking.Delete(FWorking.Count - 1);
    end
    else
      Inc(i);
  end;
end;

function TThreadPool.CreateThread: TThreadType;
begin
  Result := TThreadType.Create(FPooling);
  Result.FreeOnTerminate := True;
end;

constructor TThreadPool.Create(Pooling: Boolean);
begin
  FWorking := TThreadList.Create;
  FIdle := TThreadList.Create;
  FPooling := Pooling;
end;

destructor TThreadPool.Destroy;
var
  Worker: TThreadType;
begin
  for Worker in FWorking do
    Worker.Kill;
  for Worker in FIdle do
    Worker.Kill;
  FWorking.Free;
  FIdle.Free;
  inherited Destroy;
end;

function TThreadPool.GetThread: TThreadType;
var
  i: SizeInt;
begin
  Cleanup;
  if FIdle.Count > 0 then
  begin
    Result := FIdle[FIdle.Count - 1];
    FIdle.Delete(FIdle.Count - 1);
  end
  else for i := 0 to FWorking.Count do
  begin
    Result := CreateThread;
    if i < FWorking.Count then
      FIdle.Add(Result);
  end;
  FWorking.Add(Result);
end;

{ TPoolableThread }

procedure TPoolableThread.Execute;
begin
  while not Terminated do
  begin
    FLock.Lock;
    try
      FIdle := False;
      if Terminated then Exit;
      FStopped := False;
      ExecuteTask(FTaskArg);
    finally
      FLock.Unlock;
    end;
    if not Terminated and FPooling then
    begin
      FLock.Lock;
      FIdle := True;
    end
    else
      Terminate;
  end;
end;

constructor TPoolableThread.Create(Pooling: Boolean);
begin
  FLock.Init;
  FLock.Lock;
  FIdle := True;
  FPooling := Pooling;
  inherited Create(False);
end;

destructor TPoolableThread.Destroy;
begin
  Kill;
  FLock.Lock;
  inherited Destroy;
end;

procedure TPoolableThread.Start(const Arg: T);
begin
  Assert(isIdle);
  FTaskArg := Arg;
  FLock.Unlock;
end;

procedure TPoolableThread.Stop;
begin
  FStopped:=True;
end;

procedure TPoolableThread.Kill;
begin
  Terminate;
  Stop;
  if isIdle then
    FLock.Unlock;
end;

end.
