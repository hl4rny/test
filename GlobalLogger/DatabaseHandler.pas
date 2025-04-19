unit DatabaseHandler;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, LogHandlers, SyncObjs, DateUtils,
  // Zeos 컴포넌트 관련
  ZConnection, ZDataset, ZDbcIntfs;

type
  // 로그 레코드 구조체
  TLogRecord = record
    Timestamp: TDateTime;
    Level: TLogLevel;
    Message: string;
    SourceId: string;
    Tag: string;
    ProcessId: Cardinal;
    ThreadId: Cardinal;
  end;
  PLogRecord = ^TLogRecord;

  // 로그 테이블 설정
  TLogTableSettings = record
    TableName: string;
    TimestampField: string;
    LevelField: string;
    MessageField: string;
    SourceIdField: string;
    TagField: string;
    ProcessIdField: string;
    ThreadIdField: string;
  end;

  // 로그 보관 정책
  TLogRetentionPolicy = record
    Enabled: Boolean;
    MaxDays: Integer;
    MaxRecords: Integer;
  end;

  // 큐 아이템 (비동기 처리용)
  TDBLogQueueItem = record
    LogRecord: TLogRecord;
  end;
  PDBLogQueueItem = ^TDBLogQueueItem;

  { TDatabaseHandlerThread - 비동기 DB 로깅용 스레드 }
  TDatabaseHandlerThread = class(TThread)
  private
    FOwner: TObject;
    FQueueEvent: TEvent;
    FTerminateEvent: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TObject);
    destructor Destroy; override;

    procedure SignalQueue;
    procedure SignalTerminate;
  end;

  { TDatabaseHandler - 데이터베이스 로그 핸들러 }
  TDatabaseHandler = class(TLogHandler)
  private
    // DB 연결 관련
    FConnection: TZConnection;
    FOwnsConnection: Boolean;
    FConnectionString: string;
    FUsername: string;
    FPassword: string;
    FConnected: Boolean;

    // 테이블 설정
    FTableSettings: TLogTableSettings;
    FAutoCreateTable: Boolean;
    FRetentionPolicy: TLogRetentionPolicy;

    // 비동기 처리 관련
    FLogQueue: TThreadList;
    FAsyncThread: TDatabaseHandlerThread;
    FQueueMaxSize: Integer;
    FQueueFlushInterval: Integer;
    FLastQueueFlush: TDateTime;
    FBatchSize: Integer; // 일괄 처리 크기

    // 내부 메서드
    procedure CheckConnection;
    procedure CloseConnection;
    procedure CheckTableExists;
    procedure CreateLogTable;
    procedure CleanupOldLogs;
    procedure FlushQueue;
    procedure ProcessLogQueue;
    procedure WriteLogRecord(const LogRecord: TLogRecord);
    procedure WriteBatchLogRecords(const Records: array of TLogRecord);
    function GetLogLevelName(Level: TLogLevel): string;

  protected
    procedure WriteLog(const Msg: string; Level: TLogLevel); override;

  public
    constructor Create(AConnection: TZConnection = nil); reintroduce;
    constructor CreateWithConnectionInfo(const ConnectionString, Username, Password: string);
    destructor Destroy; override;

    procedure Init; override;
    procedure Shutdown; override;

    // 데이터베이스 연결 설정
    procedure SetConnectionInfo(const ConnectionString, Username, Password: string);

    // 테이블 설정
    procedure ConfigureTable(const TableName: string = 'LOG_RECORDS';
                           const TimestampField: string = 'TIMESTAMP';
                           const LevelField: string = 'LEVEL';
                           const MessageField: string = 'MESSAGE';
                           const SourceIdField: string = 'SOURCE_ID';
                           const TagField: string = 'TAG';
                           const ProcessIdField: string = 'PROCESS_ID';
                           const ThreadIdField: string = 'THREAD_ID');

    // 로그 보관 정책 설정
    procedure SetRetentionPolicy(Enabled: Boolean = True;
                               MaxDays: Integer = 30;
                               MaxRecords: Integer = 100000);

    // 비동기 모드 설정 오버라이드
    procedure SetAsyncMode(Mode: TAsyncMode); override;

    // 속성
    property Connection: TZConnection read FConnection;
    property Connected: Boolean read FConnected;
    property AutoCreateTable: Boolean read FAutoCreateTable write FAutoCreateTable;
    property TableSettings: TLogTableSettings read FTableSettings write FTableSettings;
    property QueueMaxSize: Integer read FQueueMaxSize write FQueueMaxSize;
    property QueueFlushInterval: Integer read FQueueFlushInterval write FQueueFlushInterval;
    property BatchSize: Integer read FBatchSize write FBatchSize;
  end;

implementation

uses
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  StrUtils;

{ TDatabaseHandlerThread }

constructor TDatabaseHandlerThread.Create(AOwner: TObject);
begin
  inherited Create(True); // 일시 중단 상태로 생성

  FOwner := AOwner;
  FQueueEvent := TEvent.Create(nil, False, False, '');
  FTerminateEvent := TEvent.Create(nil, True, False, '');

  FreeOnTerminate := False;

  // 스레드 시작
  Start;
end;

destructor TDatabaseHandlerThread.Destroy;
begin
  FQueueEvent.Free;
  FTerminateEvent.Free;

  inherited;
end;

procedure TDatabaseHandlerThread.Execute;
var
  WaitResult: DWORD;
  Events: array[0..1] of THandle;
begin
  Events[0] := THandle(FQueueEvent.Handle);
  Events[1] := THandle(FTerminateEvent.Handle);

  while not Terminated do
  begin
    // 이벤트 대기 (5초 타임아웃)
    WaitResult := WaitForMultipleObjects(2, @Events[0], False, 5000);

    if Terminated then
      Break;

    case WaitResult of
      WAIT_OBJECT_0:     // 큐 이벤트
        TDatabaseHandler(FOwner).ProcessLogQueue;
      WAIT_OBJECT_0 + 1: // 종료 이벤트
        Break;
      WAIT_TIMEOUT:      // 타임아웃
        TDatabaseHandler(FOwner).ProcessLogQueue;
    end;
  end;
end;

procedure TDatabaseHandlerThread.SignalQueue;
begin
  FQueueEvent.SetEvent;
end;

procedure TDatabaseHandlerThread.SignalTerminate;
begin
  FTerminateEvent.SetEvent;
end;

{ TDatabaseHandler }
constructor TDatabaseHandler.Create(AConnection: TZConnection);
begin
  inherited Create;

  // DB 연결 설정
  FConnection := AConnection;
  FOwnsConnection := (AConnection = nil);
  if FOwnsConnection then
    FConnection := TZConnection.Create(nil);

  FConnected := False;
  FConnectionString := '';
  FUsername := '';
  FPassword := '';

  // 테이블 설정 초기화
  FTableSettings.TableName := 'LOG_RECORDS';
  FTableSettings.TimestampField := 'TIMESTAMP';
  FTableSettings.LevelField := 'LEVEL';
  FTableSettings.MessageField := 'MESSAGE';
  FTableSettings.SourceIdField := 'SOURCE_ID';
  FTableSettings.TagField := 'TAG';
  FTableSettings.ProcessIdField := 'PROCESS_ID';
  FTableSettings.ThreadIdField := 'THREAD_ID';

  FAutoCreateTable := True;

  // 로그 보관 정책 초기화
  FRetentionPolicy.Enabled := True;
  FRetentionPolicy.MaxDays := 30;
  FRetentionPolicy.MaxRecords := 100000;

  // 비동기 처리 관련
  FLogQueue := TThreadList.Create;
  FAsyncThread := nil;
  FQueueMaxSize := 1000;
  FQueueFlushInterval := 5000; // 5초
  FLastQueueFlush := Now;
  FBatchSize := 50; // 기본 배치 크기
end;

constructor TDatabaseHandler.CreateWithConnectionInfo(const ConnectionString, Username, Password: string);
begin
  Create(nil); // 기본 생성자 호출
  SetConnectionInfo(ConnectionString, Username, Password);
end;

destructor TDatabaseHandler.Destroy;
begin
  Shutdown;

  // 로그 큐 정리
  FlushQueue;
  FLogQueue.Free;

  // 연결 종료 및 해제
  CloseConnection;
  if FOwnsConnection and Assigned(FConnection) then
    FConnection.Free;

  inherited;
end;

procedure TDatabaseHandler.Init;
begin
  inherited;

  // DB 연결 확인
  CheckConnection;

  // 테이블 존재 확인 및 생성
  if FAutoCreateTable then
    CheckTableExists;

  // 오래된 로그 정리
  if FRetentionPolicy.Enabled then
    CleanupOldLogs;
end;

procedure TDatabaseHandler.Shutdown;
begin
  // 비동기 스레드 종료
  SetAsyncMode(amNone);

  // 로그 큐 플러시
  FlushQueue;

  // 연결 종료
  CloseConnection;

  inherited;
end;

procedure TDatabaseHandler.SetConnectionInfo(const ConnectionString, Username, Password: string);
begin
  FConnectionString := ConnectionString;
  FUsername := Username;
  FPassword := Password;

  // 이미 연결된 경우 재연결
  if FConnected then
  begin
    CloseConnection;
    CheckConnection;
  end;
end;

procedure TDatabaseHandler.ConfigureTable(const TableName, TimestampField, LevelField,
  MessageField, SourceIdField, TagField, ProcessIdField, ThreadIdField: string);
begin
  FTableSettings.TableName := TableName;
  FTableSettings.TimestampField := TimestampField;
  FTableSettings.LevelField := LevelField;
  FTableSettings.MessageField := MessageField;
  FTableSettings.SourceIdField := SourceIdField;
  FTableSettings.TagField := TagField;
  FTableSettings.ProcessIdField := ProcessIdField;
  FTableSettings.ThreadIdField := ThreadIdField;

  // 테이블 존재 확인 및 생성
  if FConnected and FAutoCreateTable then
    CheckTableExists;
end;

procedure TDatabaseHandler.SetRetentionPolicy(Enabled: Boolean; MaxDays, MaxRecords: Integer);
begin
  FRetentionPolicy.Enabled := Enabled;
  FRetentionPolicy.MaxDays := MaxDays;
  FRetentionPolicy.MaxRecords := MaxRecords;

  // 정책이 활성화된 경우 바로 오래된 로그 정리
  if Enabled and FConnected then
    CleanupOldLogs;
end;

procedure TDatabaseHandler.SetAsyncMode(Mode: TAsyncMode);
begin
  // 현재 모드와 같으면 아무것도 하지 않음
  if Mode = AsyncMode then
    Exit;

  inherited SetAsyncMode(Mode);

  case Mode of
    amNone:
      begin
        // 비동기 모드 비활성화
        if Assigned(FAsyncThread) then
        begin
          FAsyncThread.SignalTerminate;
          FAsyncThread.Terminate;
          FAsyncThread.WaitFor;
          FAsyncThread.Free;
          FAsyncThread := nil;
        end;

        // 큐에 남은 로그 처리
        FlushQueue;
      end;

    amThread:
      begin
        // 비동기 스레드 모드 활성화
        if not Assigned(FAsyncThread) then
          FAsyncThread := TDatabaseHandlerThread.Create(Self);
      end;
  end;
end;

procedure TDatabaseHandler.WriteLog(const Msg: string; Level: TLogLevel);
var
  LogItem: PDBLogQueueItem;
  List: TList;
  LogRecord: TLogRecord;
begin
  // 로그 레코드 생성
  LogRecord.Timestamp := Now;
  LogRecord.Level := Level;
  LogRecord.Message := Msg;
  LogRecord.SourceId := SourceIdentifier;
  LogRecord.Tag := '';

  {$IFDEF MSWINDOWS}
  LogRecord.ProcessId := GetCurrentProcessId;
  LogRecord.ThreadId := GetCurrentThreadId;
  {$ELSE}
  LogRecord.ProcessId := fpGetPID;
  LogRecord.ThreadId := {$IFDEF FPC}ThreadID{$ELSE}GetCurrentThreadId{$ENDIF};
  {$ENDIF}

  if AsyncMode = amThread then
  begin
    // 비동기 모드: 큐에 메시지 추가
    New(LogItem);
    LogItem^.LogRecord := LogRecord;

    List := FLogQueue.LockList;
    try
      List.Add(LogItem);

      // 큐 크기 확인 또는 플러시 간격 확인
      if (List.Count >= FQueueMaxSize) or
         (MilliSecondsBetween(Now, FLastQueueFlush) >= FQueueFlushInterval) then
      begin
        FLastQueueFlush := Now;
        if Assigned(FAsyncThread) then
          FAsyncThread.SignalQueue;
      end;
    finally
      FLogQueue.UnlockList;
    end;
  end
  else
  begin
    // 동기 모드: 직접 DB에 기록
    CheckConnection;
    if FConnected then
      WriteLogRecord(LogRecord);
  end;
end;

procedure TDatabaseHandler.CheckConnection;
begin
  if not Assigned(FConnection) then
    Exit;

  if not FConnection.Connected then
  begin
    try
      if FOwnsConnection and (FConnectionString <> '') then
      begin
        FConnection.Protocol := 'firebird';
        FConnection.HostName := '';
        FConnection.Database := FConnectionString;
        FConnection.User := FUsername;
        FConnection.Password := FPassword;
        FConnection.Properties.Clear;
        FConnection.Properties.Add('dialect=3');
        FConnection.Properties.Add('CreateNewDatabase=False');
      end;

      FConnection.Connect;
      FConnected := FConnection.Connected;
    except
      on E: Exception do
      begin
        FConnected := False;
        // 여기서 연결 실패를 다른 로그 핸들러로 기록할 수 있지만
        // 순환 참조 문제가 발생할 수 있으므로 주의
      end;
    end;
  end
  else
    FConnected := True;
end;

procedure TDatabaseHandler.CloseConnection;
begin
  if Assigned(FConnection) and FConnection.Connected then
  begin
    try
      FConnection.Disconnect;
    except
      // 연결 종료 오류 무시
    end;
  end;
  FConnected := False;
end;

procedure TDatabaseHandler.CheckTableExists;
var
  Query: TZQuery;
begin
  if not FConnected then
    Exit;

  Query := TZQuery.Create(nil);
  try
    Query.Connection := FConnection;

    // Firebird에서 테이블 존재 여부 확인
    Query.SQL.Text :=
      'SELECT COUNT(*) FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = ''' +
      UpperCase(FTableSettings.TableName) + '''';

    try
      Query.Open;
      if Query.Fields[0].AsInteger = 0 then
        CreateLogTable;
    except
      on E: Exception do
      begin
        // 테이블 확인 실패 처리
      end;
    end;
  finally
    Query.Free;
  end;
end;

procedure TDatabaseHandler.CreateLogTable;
var
  Query: TZQuery;
begin
  if not FConnected then
    Exit;

  Query := TZQuery.Create(nil);
  try
    Query.Connection := FConnection;

    // Firebird용 테이블 생성 SQL
    Query.SQL.Text :=
      'CREATE TABLE ' + FTableSettings.TableName + ' (' +
      'ID INTEGER NOT NULL, ' +
      FTableSettings.TimestampField + ' TIMESTAMP NOT NULL, ' +
      FTableSettings.LevelField + ' VARCHAR(20) NOT NULL, ' +
      FTableSettings.MessageField + ' BLOB SUB_TYPE TEXT, ' +
      FTableSettings.SourceIdField + ' VARCHAR(100), ' +
      FTableSettings.TagField + ' VARCHAR(100), ' +
      FTableSettings.ProcessIdField + ' INTEGER, ' +
      FTableSettings.ThreadIdField + ' INTEGER, ' +
      'PRIMARY KEY (ID))';

    try
      Query.ExecSQL;

      // 시퀀스 생성
      Query.SQL.Text :=
        'CREATE SEQUENCE GEN_' + FTableSettings.TableName + '_ID';
      Query.ExecSQL;

      // 인덱스 생성
      Query.SQL.Text :=
        'CREATE INDEX IDX_' + FTableSettings.TableName + '_TIMESTAMP ON ' +
        FTableSettings.TableName + ' (' + FTableSettings.TimestampField + ')';
      Query.ExecSQL;

      Query.SQL.Text :=
        'CREATE INDEX IDX_' + FTableSettings.TableName + '_LEVEL ON ' +
        FTableSettings.TableName + ' (' + FTableSettings.LevelField + ')';
      Query.ExecSQL;
    except
      on E: Exception do
      begin
        // 테이블 생성 실패 처리
      end;
    end;
  finally
    Query.Free;
  end;
end;

procedure TDatabaseHandler.CleanupOldLogs;
var
  Query: TZQuery;
  OldDate: TDateTime;
begin
  if not FConnected or not FRetentionPolicy.Enabled then
    Exit;

  Query := TZQuery.Create(nil);
  try
    Query.Connection := FConnection;

    try
      // 날짜 기반 정리
      if FRetentionPolicy.MaxDays > 0 then
      begin
        OldDate := IncDay(Now, -FRetentionPolicy.MaxDays);
        Query.SQL.Text :=
          'DELETE FROM ' + FTableSettings.TableName +
          ' WHERE ' + FTableSettings.TimestampField + ' < :OldDate';
        Query.ParamByName('OldDate').AsDateTime := OldDate;
        Query.ExecSQL;
      end;

      // 레코드 수 기반 정리
      if FRetentionPolicy.MaxRecords > 0 then
      begin
        // 현재 레코드 수 확인
        Query.SQL.Text := 'SELECT COUNT(*) FROM ' + FTableSettings.TableName;
        Query.Open;

        if Query.Fields[0].AsInteger > FRetentionPolicy.MaxRecords then
        begin
          Query.Close;

          // 오래된 레코드 삭제 (Firebird에서는 LIMIT이 없으므로 다른 방식 사용)
          Query.SQL.Text :=
            'DELETE FROM ' + FTableSettings.TableName +
            ' WHERE ID IN (SELECT FIRST ' +
            IntToStr(Query.Fields[0].AsInteger - FRetentionPolicy.MaxRecords) +
            ' ID FROM ' + FTableSettings.TableName +
            ' ORDER BY ' + FTableSettings.TimestampField + ')';
          Query.ExecSQL;
        end;
      end;
    except
      on E: Exception do
      begin
        // 정리 실패 처리
      end;
    end;
  finally
    Query.Free;
  end;
end;

procedure TDatabaseHandler.FlushQueue;
var
  List: TList;
  Item: PDBLogQueueItem;
  i, BatchCount: Integer;
  BatchRecords: array of TLogRecord;
begin
  List := FLogQueue.LockList;
  try
    // 큐에 로그가 없으면 종료
    if List.Count = 0 then
      Exit;

    // 연결 확인
    CheckConnection;
    if not FConnected then
      Exit;

    // 배치 처리를 위한 배열 준비
    BatchCount := Min(List.Count, FBatchSize);
    SetLength(BatchRecords, BatchCount);

    // 배치 처리할 레코드 복사
    for i := 0 to BatchCount - 1 do
    begin
      Item := PDBLogQueueItem(List[i]);
      BatchRecords[i] := Item^.LogRecord;
      Dispose(Item);
    end;

    // 처리된 항목 제거
    for i := 0 to BatchCount - 1 do
      List.Delete(0);

  finally
    FLogQueue.UnlockList;
  end;

  // 배치 기록
  if Length(BatchRecords) > 0 then
  begin
    try
      WriteBatchLogRecords(BatchRecords);
    except
      // 배치 처리 실패
    end;
  end;

  // 아직 큐에 항목이 있으면 재귀적으로 처리
  // (단, 무한 재귀를 방지하기 위해 List.Count 확인 필요)
  List := FLogQueue.LockList;
  try
    if List.Count > 0 then
    begin
      FLogQueue.UnlockList;
      FlushQueue;
    end;
  finally
    FLogQueue.UnlockList;
  end;
end;

procedure TDatabaseHandler.ProcessLogQueue;
begin
  // 큐 처리 (비동기 스레드에서 호출)
  FlushQueue;
  FLastQueueFlush := Now;
end;

procedure TDatabaseHandler.WriteLogRecord(const LogRecord: TLogRecord);
var
  Query: TZQuery;
begin
  if not FConnected then
    Exit;

  Query := TZQuery.Create(nil);
  try
    Query.Connection := FConnection;

    // 로그 레코드 삽입 SQL
    Query.SQL.Text :=
      'INSERT INTO ' + FTableSettings.TableName +
      ' (ID, ' +
      FTableSettings.TimestampField + ', ' +
      FTableSettings.LevelField + ', ' +
      FTableSettings.MessageField + ', ' +
      FTableSettings.SourceIdField + ', ' +
      FTableSettings.TagField + ', ' +
      FTableSettings.ProcessIdField + ', ' +
      FTableSettings.ThreadIdField + ') ' +
      'VALUES (GEN_ID(GEN_' + FTableSettings.TableName + '_ID, 1), ' +
      ':Timestamp, :Level, :Message, :SourceId, :Tag, :ProcessId, :ThreadId)';

    // 파라미터 설정
    Query.ParamByName('Timestamp').AsDateTime := LogRecord.Timestamp;
    Query.ParamByName('Level').AsString := GetLogLevelName(LogRecord.Level);
    Query.ParamByName('Message').AsString := LogRecord.Message;
    Query.ParamByName('SourceId').AsString := LogRecord.SourceId;
    Query.ParamByName('Tag').AsString := LogRecord.Tag;
    Query.ParamByName('ProcessId').AsInteger := LogRecord.ProcessId;
    Query.ParamByName('ThreadId').AsInteger := LogRecord.ThreadId;

    try
      Query.ExecSQL;
    except
      on E: Exception do
      begin
        // 로그 기록 실패 처리
      end;
    end;
  finally
    Query.Free;
  end;
end;

procedure TDatabaseHandler.WriteBatchLogRecords(const Records: array of TLogRecord);
var
  Query: TZQuery;
  i: Integer;
  SQL: string;
begin
  if not FConnected or (Length(Records) = 0) then
    Exit;

  Query := TZQuery.Create(nil);
  try
    Query.Connection := FConnection;

    // 트랜잭션 시작
    FConnection.StartTransaction;
    try
      for i := 0 to Length(Records) - 1 do
      begin
        // 로그 레코드 삽입 SQL
        Query.SQL.Text :=
          'INSERT INTO ' + FTableSettings.TableName +
          ' (ID, ' +
          FTableSettings.TimestampField + ', ' +
          FTableSettings.LevelField + ', ' +
          FTableSettings.MessageField + ', ' +
          FTableSettings.SourceIdField + ', ' +
          FTableSettings.TagField + ', ' +
          FTableSettings.ProcessIdField + ', ' +
          FTableSettings.ThreadIdField + ') ' +
          'VALUES (GEN_ID(GEN_' + FTableSettings.TableName + '_ID, 1), ' +
          ':Timestamp, :Level, :Message, :SourceId, :Tag, :ProcessId, :ThreadId)';

        // 파라미터 설정
        Query.ParamByName('Timestamp').AsDateTime := Records[i].Timestamp;
        Query.ParamByName('Level').AsString := GetLogLevelName(Records[i].Level);
        Query.ParamByName('Message').AsString := Records[i].Message;
        Query.ParamByName('SourceId').AsString := Records[i].SourceId;
        Query.ParamByName('Tag').AsString := Records[i].Tag;
        Query.ParamByName('ProcessId').AsInteger := Records[i].ProcessId;
        Query.ParamByName('ThreadId').AsInteger := Records[i].ThreadId;

        Query.ExecSQL;
      end;

      // 트랜잭션 커밋
      FConnection.Commit;
    except
      on E: Exception do
      begin
        // 롤백
        FConnection.Rollback;
        // 로그 기록 실패 처리
      end;
    end;
  finally
    Query.Free;
  end;
end;

function TDatabaseHandler.GetLogLevelName(Level: TLogLevel): string;
begin
  case Level of
    llDevelop: Result := 'DEVELOP';
    llDebug: Result := 'DEBUG';
    llInfo: Result := 'INFO';
    llWarning: Result := 'WARNING';
    llError: Result := 'ERROR';
    llFatal: Result := 'FATAL';
    else Result := 'UNKNOWN';
  end;
end;


end.


{
이 코드는 기존 로거 구조에 맞게 작성된 DatabaseHandler 유닛입니다. Firebird 5.0과 Zeos 컴포넌트를 사용하여
로그를 데이터베이스에 저장합니다. 주요 기능은 다음과 같습니다:

    로그 레코드를 데이터베이스 테이블에 저장
    비동기 로깅 지원 (스레드 기반)
    배치 처리를 통한 성능 최적화
    자동 테이블 생성 및 관리
    로그 보관 정책 (오래된 로그 자동 삭제)
    기존 소스 식별자 지원
    태그 기반 필터링 지원
    다양한 로그 레벨 지원

// 기본 사용법
var
  DBHandler: TDatabaseHandler;
begin
  // 방법 1: 기존 ZConnection 사용
  DBHandler := TDatabaseHandler.Create(MyZConnection);

  // 방법 2: 연결 정보 직접 설정
  DBHandler := TDatabaseHandler.CreateWithConnectionInfo(
    'C:\MyDatabase.fdb', 'SYSDBA', 'masterkey');

  // 로거에 핸들러 추가
  Logger.AddHandler(DBHandler);

  // 로그 테이블 설정 (선택적)
  DBHandler.ConfigureTable('APP_LOGS', 'LOG_TIME', 'LOG_LEVEL', 'LOG_MESSAGE');

  // 보관 정책 설정 (선택적)
  DBHandler.SetRetentionPolicy(True, 90, 500000);

  // 비동기 모드 활성화 (선택적)
  DBHandler.SetAsyncMode(amThread);

  // 로그 작성
  Logger.LogInfo('데이터베이스 로깅 테스트');
end;

이 코드는 GlobalLogger 클래스와 원활하게 통합되며, 기존 로그 핸들러들과 함께 사용할 수 있습니다. 필요에 따라
비동기 모드를 활성화하여 성능을 최적화할 수 있으며, 로그 보관 정책을 설정하여 데이터베이스 크기를 관리할 수 있습니다.

}
