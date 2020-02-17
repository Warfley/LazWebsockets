unit utilities;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, gvector, fgl;

type

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

  { TObjectPool }

  generic TObjectPool<T, Factory, Checker> = class
  private
    type
    TPool = class(specialize TVector<T>);
  private
    FWorking: TPool;
    FIdle: TPool;
    procedure CleanUp;
  public
    constructor Create;
    destructor Destroy; override;

    function GetObject: T;
  end;

  { TPoolableThread }

  TPoolableThread = class(TThread)
  private
    FIsIdle: boolean;
  protected
    procedure DoExecute; virtual;
    procedure Execute; override;
  public
    constructor Create(CreateSuspended: boolean;
      const StackSize: SizeUInt = DefaultStackSize);
    procedure Restart; virtual;
    property isIdle: boolean read FIsIdle;
  end;

  { TPoolableThreadFactory }

  generic TPoolableThreadFactory<T> = class
  public
    class function Produce: T;
    class function isIdle(const AThread: T): boolean;
    class procedure Clear(const AThread: T);
    class procedure DoDestroy(const AThread: T);
  end;

  { TStreamHelper }

  TStreamHelper = class helper for TStream
  public
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
  self.WriteBuffer(Data[1], Data.Length);
end;


{ TObjectPool }
{* -----------------------------------------------------------------------------
 * Searches the whole list, checks if some of the objects can be transfered from
 * working to idle
 * ----------------------------------------------------------------------------}
procedure TObjectPool.CleanUp;
var
  i: SizeUInt;
  len: SizeUInt;
begin
  i := 0;
  len := FWorking.Size;
  while i < len do
  begin
    if Checker.isIdle(FWorking[i]) then
    begin
      // If idle than put into idle list
      FIdle.PushBack(FWorking[i]);
      // swap delete, so in the end we only need to reduce the size
      FWorking[i] := FWorking[len - 1];
      Dec(len);
    end
    else
    begin
      Inc(i);
    end;
  end;
  // "Remove" the deleted objects
  FWorking.Resize(len);
  (* Maybe this is usefull?
  if FIdle.Size > FWorking.Size + 1 then
  begin
    for i := FWorking.Size + 1 to FIdle.Size - 1 do
      Factory.DoDestroy(FIdle[i]);
    FIdle.Resize(FWorking.Size + 1);
  end;
  *)
end;

constructor TObjectPool.Create;
begin
  FWorking := TPool.Create;
  FIdle := TPool.Create;
end;

destructor TObjectPool.Destroy;
var
  obj: T;
begin
  for obj in FWorking do
    Factory.DoDestroy(obj);
  FWorking.Free;
  for obj in FIdle do
    Factory.DoDestroy(obj);
  FIdle.Free;
  inherited Destroy;
end;

{* -----------------------------------------------------------------------------
 * Returns an object. If Idle ones are available they are reused, otherwise
 * new ones will be created
 * ----------------------------------------------------------------------------}
function TObjectPool.GetObject: T;
var
  i: SizeUInt;
begin
  CleanUp;
  // If we have objects cached return one of them
  if FIdle.Size > 0 then
  begin
    Result := FIdle.Back;
    FIdle.PopBack;
    Factory.Clear(Result);
    FWorking.PushBack(Result);
  end
  // if this isn't the first object, create as many idle ones as there are working ones
  else if FWorking.Size > 0 then
  begin
    FIdle.Reserve(FWorking.Size);
    for i := 0 to FWorking.Size do
      FIdle.PushBack(Factory.Produce);
    Result := FIdle.Back;
    FIdle.PopBack;
    Factory.Clear(Result);
    FWorking.PushBack(Result);
  end
  else // otherwise create only one
  begin
    Result := Factory.Produce;
    Factory.Clear(Result);
    FWorking.PushBack(Result);
  end;
end;

{ TPoolableThreadFactory }

class function TPoolableThreadFactory.Produce: T;
begin
  Result := T.Create(True);
end;

class function TPoolableThreadFactory.isIdle(const AThread: T): boolean;
begin
  Result := AThread.IsIdle;
end;

class procedure TPoolableThreadFactory.Clear(const AThread: T);
begin
  // Nothing to be done here
end;

class procedure TPoolableThreadFactory.DoDestroy(const AThread: T);
begin
  AThread.Free;
end;

{ TPoolableThread }

procedure TPoolableThread.DoExecute;
begin

end;

procedure TPoolableThread.Execute;
begin
  while not Self.Terminated do
  begin
    while isIdle do
    begin
      if Self.Terminated then
        Exit;
      TThread.Yield;
    end;
    DoExecute;
    FIsIdle := True;
  end;
end;

constructor TPoolableThread.Create(CreateSuspended: boolean; const StackSize: SizeUInt);
begin
  if CreateSuspended then
    FIsIdle := True
  else
    FIsIdle := False;
  inherited Create(False, StackSize);
end;

procedure TPoolableThread.Restart;
begin
  FIsIdle := False;
end;

end.
