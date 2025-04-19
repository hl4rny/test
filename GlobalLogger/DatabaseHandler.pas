unit DatabaseHandler;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ZConnection, ZDataset, ZDbcIntfs,
  DateUtils, StrUtils, Forms, Dialogs,
  // GlobalLogger 시스템 모듈
  GlobalLogger, LogHandlers, SourceIdentifier;

type
  { TDatabaseLogHandler }
  TDatabaseLogHandler = class(TLogHandler)
  private
    FDBConnection: TZConnection;
    FMetaQuery: TZQuery;
    FLogQuery: TZQuery;
    FCurrentLogTable: string;
    FAppPath: string;
    FLastTableCheck: TDateTime;
    FTableCheckInterval: Integer; // 테이블 존재 확인 간격 (분)
    FRetentionMonths: Integer;    // 로그 유지 기간 (월)
    FMetaTableName: string;

    procedure InitializeConnection;
    function CreateDatabase: Boolean;
    function ConnectToDatabase: Boolean;
    procedure EnsureMetaTableExists;
    procedure EnsureCurrentLogTableExists;
    function GetCurrentTableName: string;
    function TableExists(const ATableName: string): Boolean;
    function RegisterLogTable(const ATableName, AYearMonth: string): Boolean;
    function UpdateLogTableMetrics(const ATableName: string): Boolean;
    procedure ManageLogTables;
    function GetTableDate(const ATableName: string; out ADate: TDateTime): Boolean;
    function GetLogTableList: TStringList;
    function ExecuteSQL(const ASQL: string): Boolean;
    function GetDatabaseFilePath: string;
    function GetClientLibPath: string;

  protected
    procedure DoWriteLog(const AMsg: string; const ALevel: TLogLevel;
                        const ATag: string = ''); override;
    procedure SetFormatSettings; override;

  public
    constructor Create; override;
    destructor Destroy; override;

    // GlobalLogger 시스템에 통합되므로 핸들러 초기화 및 LogLevel 설정
    procedure Initialize; override;
    procedure SetLogLevels(const ALevels: TLogLevelSet); override;

    // 로그 테이블 조회 기능
    function GetLogs(const AFromDate, AToDate: TDateTime;
                    const ALevel: TLogLevel = llInfo;
                    const ATag: string = ''): TStringList;

    // 유지보수 관련 기능
    procedure PerformMaintenance;

    property RetentionMonths: Integer read FRetentionMonths write FRetentionMonths;
  end;

implementation

{ TDatabaseLogHandler }

constructor TDatabaseLogHandler.Create;
begin
  inherited Create;

  FAppPath := ExtractFilePath(Application.ExeName);
  SourceIdentifier := 'DB';
  FLastTableCheck := 0;
  FTableCheckInterval := 5; // 5분마다 테이블 확인
  FRetentionMonths := 12;   // 기본 12개월 보관
  FMetaTableName := 'LOG_META';

  FDBConnection := TZConnection.Create(nil);
  FMetaQuery := TZQuery.Create(nil);
  FLogQuery := TZQuery.Create(nil);

  FMetaQuery.Connection := FDBConnection;
  FLogQuery.Connection := FDBConnection;

  InitializeConnection;
end;

destructor TDatabaseLogHandler.Destroy;
begin
  if FDBConnection.Connected then
  begin
    // 접속 종료 전 메타데이터 업데이트
    if FCurrentLogTable <> '' then
      UpdateLogTableMetrics(FCurrentLogTable);

    FDBConnection.Disconnect;
  end;

  FLogQuery.Free;
  FMetaQuery.Free;
  FDBConnection.Free;

  inherited;
end;

procedure TDatabaseLogHandler.Initialize;
begin
  inherited;

  // 전체 로그 레벨 활성화
  LogLevels := [llDevelop, llDebug, llInfo, llWarning, llError, llFatal];

  // 필요한 경우 여기에 추가 초기화 코드 작성
end;

procedure TDatabaseLogHandler.SetLogLevels(const ALevels: TLogLevelSet);
begin
  inherited;
  // 추가 작업이 필요한 경우 여기에 구현
end;

procedure TDatabaseLogHandler.SetFormatSettings;
begin
  inherited;

  // 로그 출력 형식 설정
  TimestampFormat := 'yyyy-mm-dd hh:nn:ss.zzz';
  IncludeDate := True;
  IncludeTime := True;
  IncludeMilliseconds := True;
end;

procedure TDatabaseLogHandler.InitializeConnection;
begin
  try
    // 데이터베이스 디렉토리 확인 및 생성
    ForceDirectories(FAppPath + 'log');

    // DB 연결 설정
    with FDBConnection do
    begin
      Protocol := 'firebird';
      ClientCodepage := 'UTF8';
      LibraryLocation := GetClientLibPath;
      Database := GetDatabaseFilePath;
      User := 'SYSDBA';
      Password := 'masterkey';
      Properties.Clear;
      Properties.Values['dialect'] := '3';
      Port := 0;
      Catalog := '';
      HostName := '';
    end;

    // DB 생성 및 연결
    if not FileExists(GetDatabaseFilePath) then
      CreateDatabase
    else
      ConnectToDatabase;

    // 메타 테이블 존재 확인 및 생성
    if FDBConnection.Connected then
      EnsureMetaTableExists;
  except
    on E: Exception do
      LogError('DatabaseHandler 초기화 오류: ' + E.Message);
  end;
end;

function TDatabaseLogHandler.CreateDatabase: Boolean;
begin
  Result := False;
  try
    with FDBConnection do
    begin
      Properties.Clear;
      Properties.Values['dialect'] := '3';
      Properties.Values['CreateNewDatabase'] :=
        'CREATE DATABASE ' + QuotedStr(Database) +
        ' USER ' + QuotedStr('SYSDBA') +
        ' PASSWORD ' + QuotedStr('masterkey') +
        ' PAGE_SIZE 16384 DEFAULT CHARACTER SET UTF8';
    end;

    FDBConnection.Connect;
    Result := FDBConnection.Connected;
  except
    on E: Exception do
      LogError('로그 데이터베이스 생성 오류: ' + E.Message);
  end;
end;

function TDatabaseLogHandler.ConnectToDatabase: Boolean;
begin
  Result := False;
  try
    // 이미 연결되어 있다면 재연결할 필요 없음
    if FDBConnection.Connected then
    begin
      Result := True;
      Exit;
    end;

    FDBConnection.Connect;
    Result := FDBConnection.Connected;
  except
    on E: Exception do
      LogError('로그 데이터베이스 연결 오류: ' + E.Message);
  end;
end;

function TDatabaseLogHandler.GetDatabaseFilePath: string;
begin
  Result := FAppPath + 'log\Log.fdb';
end;

function TDatabaseLogHandler.GetClientLibPath: string;
begin
  Result := FAppPath + 'fbclient.dll';
end;

procedure TDatabaseLogHandler.EnsureMetaTableExists;
begin
  // 메타 테이블 존재 여부 확인
  if not TableExists(FMetaTableName) then
  begin
    // 메타 테이블 생성
    ExecuteSQL(
      'CREATE TABLE ' + FMetaTableName + ' (' +
      'TABLE_NAME VARCHAR(50) NOT NULL PRIMARY KEY, ' +
      'YEAR_MONTH VARCHAR(6) NOT NULL, ' +
      'CREATION_DATE TIMESTAMP NOT NULL, ' +
      'LAST_UPDATE TIMESTAMP, ' +
      'ROW_COUNT INTEGER DEFAULT 0)'
    );

    // 인덱스 생성
    ExecuteSQL(
      'CREATE INDEX IDX_' + FMetaTableName + '_YEAR_MONTH ON ' +
      FMetaTableName + ' (YEAR_MONTH)'
    );
  end;
end;

procedure TDatabaseLogHandler.EnsureCurrentLogTableExists;
var
  TableName: string;
  YearMonth: string;
begin
  // 마지막 확인으로부터 일정 시간이 지났거나 초기 상태인 경우에만 확인
  if (MinutesBetween(Now, FLastTableCheck) > FTableCheckInterval) or (FCurrentLogTable = '') then
  begin
    TableName := GetCurrentTableName;
    YearMonth := FormatDateTime('YYYYMM', Now);

    // 현재 월 테이블이 존재하는지 확인
    if not TableExists(TableName) then
    begin
      // 새 로그 테이블 생성
      ExecuteSQL(
        'CREATE TABLE ' + TableName + ' (' +
        'ID INTEGER NOT NULL PRIMARY KEY, ' +
        'LOG_TIME TIMESTAMP NOT NULL, ' +
        'LOG_DATE DATE COMPUTED BY (CAST(LOG_TIME AS DATE)), ' + // 날짜 필드 추가
        'LOG_LEVEL VARCHAR(10) NOT NULL, ' +
        'SOURCE_NAME VARCHAR(100), ' +
        'MESSAGE BLOB SUB_TYPE TEXT, ' +
        'ADDITIONAL_INFO BLOB SUB_TYPE TEXT)'
      );

      // 시퀀스 생성 (ID 자동 증가용)
      ExecuteSQL(
        'CREATE SEQUENCE GEN_' + TableName + '_ID'
      );

      // 인덱스 생성
      ExecuteSQL(
        'CREATE INDEX IDX_' + TableName + '_LOG_TIME ON ' +
        TableName + ' (LOG_TIME)'
      );

      ExecuteSQL(
        'CREATE INDEX IDX_' + TableName + '_LOG_DATE ON ' +
        TableName + ' (LOG_DATE)'
      );

      ExecuteSQL(
        'CREATE INDEX IDX_' + TableName + '_LOG_LEVEL ON ' +
        TableName + ' (LOG_LEVEL)'
      );

      // 메타 테이블에 등록
      RegisterLogTable(TableName, YearMonth);
    end;

    // 현재 테이블 이름 저장 및 확인 시간 업데이트
    FCurrentLogTable := TableName;
    FLastTableCheck := Now;

    // 오래된 테이블 관리
    ManageLogTables;
  end;
end;

function TDatabaseLogHandler.GetCurrentTableName: string;
begin
  // 현재 년월에 해당하는 테이블 이름 생성 (예: LOG_202504)
  Result := 'LOG_' + FormatDateTime('YYYYMM', Now);
end;

function TDatabaseLogHandler.TableExists(const ATableName: string): Boolean;
begin
  Result := False;

  if not FDBConnection.Connected then
    if not ConnectToDatabase then
      Exit;

  try
    FMetaQuery.Close;
    FMetaQuery.SQL.Text :=
      'SELECT 1 FROM RDB$RELATIONS ' +
      'WHERE RDB$RELATION_NAME = ''' + UpperCase(ATableName) + '''';
    FMetaQuery.Open;
    Result := not FMetaQuery.EOF;
    FMetaQuery.Close;
  except
    on E: Exception do
      LogWarning('테이블 존재 확인 오류: ' + E.Message);
  end;
end;

function TDatabaseLogHandler.RegisterLogTable(const ATableName, AYearMonth: string): Boolean;
begin
  Result := False;

  if not FDBConnection.Connected then
    if not ConnectToDatabase then
      Exit;

  try
    FMetaQuery.Close;
    FMetaQuery.SQL.Text :=
      'INSERT INTO ' + FMetaTableName +
      ' (TABLE_NAME, YEAR_MONTH, CREATION_DATE, LAST_UPDATE, ROW_COUNT) ' +
      'VALUES (:TNAME, :YMONTH, :CDATE, :LUPDATE, 0)';

    FMetaQuery.ParamByName('TNAME').AsString := ATableName;
    FMetaQuery.ParamByName('YMONTH').AsString := AYearMonth;
    FMetaQuery.ParamByName('CDATE').AsDateTime := Now;
    FMetaQuery.ParamByName('LUPDATE').AsDateTime := Now;

    FMetaQuery.ExecSQL;
    Result := True;
  except
    on E: Exception do
      LogWarning('로그 테이블 등록 오류: ' + E.Message);
  end;
end;

function TDatabaseLogHandler.UpdateLogTableMetrics(const ATableName: string): Boolean;
var
  RowCount: Integer;
begin
  Result := False;

  if not FDBConnection.Connected then
    if not ConnectToDatabase then
      Exit;

  try
    // 테이블의 현재 행 수 가져오기
    FMetaQuery.Close;
    FMetaQuery.SQL.Text := 'SELECT COUNT(*) FROM ' + ATableName;
    FMetaQuery.Open;
    RowCount := FMetaQuery.Fields[0].AsInteger;
    FMetaQuery.Close;

    // 메타 테이블 업데이트
    FMetaQuery.SQL.Text :=
      'UPDATE ' + FMetaTableName +
      ' SET LAST_UPDATE = :LUPDATE, ROW_COUNT = :RCOUNT ' +
      'WHERE TABLE_NAME = :TNAME';

    FMetaQuery.ParamByName('LUPDATE').AsDateTime := Now;
    FMetaQuery.ParamByName('RCOUNT').AsInteger := RowCount;
    FMetaQuery.ParamByName('TNAME').AsString := ATableName;

    FMetaQuery.ExecSQL;
    Result := True;
  except
    on E: Exception do
      LogWarning('로그 테이블 메트릭 업데이트 오류: ' + E.Message);
  end;
end;

procedure TDatabaseLogHandler.DoWriteLog(const AMsg: string; const ALevel: TLogLevel; const ATag: string);
var
  LevelStr: string;
begin
  // 현재 로그 테이블이 존재하는지 확인하고 필요시 생성
  EnsureCurrentLogTableExists;

  if FCurrentLogTable = '' then
    Exit;

  if not FDBConnection.Connected then
    if not ConnectToDatabase then
      Exit;

  try
    // 로그 레벨을 문자열로 변환
    case ALevel of
      llDevelop: LevelStr := 'DEVELOP';
      llDebug:   LevelStr := 'DEBUG';
      llInfo:    LevelStr := 'INFO';
      llWarning: LevelStr := 'WARNING';
      llError:   LevelStr := 'ERROR';
      llFatal:   LevelStr := 'FATAL';
      else       LevelStr := 'UNKNOWN';
    end;

    // 로그 기록
    FLogQuery.Close;
    FLogQuery.SQL.Text :=
      'INSERT INTO ' + FCurrentLogTable +
      ' (ID, LOG_TIME, LOG_LEVEL, SOURCE_NAME, MESSAGE, ADDITIONAL_INFO) ' +
      'VALUES (NEXT VALUE FOR GEN_' + FCurrentLogTable + '_ID, ' +
      ':LTIME, :LLEVEL, :LSOURCE, :LMSG, :LINFO)';

    FLogQuery.ParamByName('LTIME').AsDateTime := Now;
    FLogQuery.ParamByName('LLEVEL').AsString := LevelStr;
    FLogQuery.ParamByName('LSOURCE').AsString := BuildSourceIdentifier(ATag);
    FLogQuery.ParamByName('LMSG').AsString := AMsg;
    FLogQuery.ParamByName('LINFO').AsString := ''; // 추가 정보는 필요시 여기에 구현

    FLogQuery.ExecSQL;
  except
    on E: Exception do
    begin
      // 로그 기록 실패 시 자기 자신에게 무한 재귀 호출이 발생하지 않도록 ShowMessage 사용
      ShowMessage('로그 기록 오류: ' + E.Message);
    end;
  end;
end;

function TDatabaseLogHandler.GetLogs(const AFromDate, AToDate: TDateTime;
                                    const ALevel: TLogLevel = llInfo;
                                    const ATag: string = ''): TStringList;
var
  FromYearMonth, ToYearMonth: string;
  YearMonth: string;
  YM: Integer;
  SQLWhere, SQLUnion: string;
  TableList: TStringList;
  TableYM: string;
  i: Integer;
  LogEntry: string;
  LevelStr: string;
begin
  Result := TStringList.Create;

  if not FDBConnection.Connected then
    if not ConnectToDatabase then
      Exit;

  try
    // 로그 레벨을 문자열로 변환
    case ALevel of
      llDevelop: LevelStr := 'DEVELOP';
      llDebug:   LevelStr := 'DEBUG';
      llInfo:    LevelStr := 'INFO';
      llWarning: LevelStr := 'WARNING';
      llError:   LevelStr := 'ERROR';
      llFatal:   LevelStr := 'FATAL';
      else       LevelStr := '';
    end;

    // 조회 범위의 년월 구하기
    FromYearMonth := FormatDateTime('YYYYMM', AFromDate);
    ToYearMonth := FormatDateTime('YYYYMM', AToDate);

    // 메타 테이블에서 해당 기간의 테이블 목록 가져오기
    TableList := TStringList.Create;
    try
      FMetaQuery.Close;
      FMetaQuery.SQL.Text :=
        'SELECT TABLE_NAME, YEAR_MONTH FROM ' + FMetaTableName +
        ' WHERE YEAR_MONTH >= :FROM_YM AND YEAR_MONTH <= :TO_YM ' +
        'ORDER BY YEAR_MONTH';

      FMetaQuery.ParamByName('FROM_YM').AsString := FromYearMonth;
      FMetaQuery.ParamByName('TO_YM').AsString := ToYearMonth;

      FMetaQuery.Open;

      while not FMetaQuery.EOF do
      begin
        TableList.Add(FMetaQuery.FieldByName('TABLE_NAME').AsString + '=' +
                     FMetaQuery.FieldByName('YEAR_MONTH').AsString);
        FMetaQuery.Next;
      end;

      FMetaQuery.Close;

      // 조건절 생성
      SQLWhere := 'WHERE LOG_TIME BETWEEN :FROM_DATE AND :TO_DATE ';

      if LevelStr <> '' then
        SQLWhere := SQLWhere + 'AND LOG_LEVEL = :LOG_LEVEL ';

      if ATag <> '' then
        SQLWhere := SQLWhere + 'AND SOURCE_NAME LIKE :SOURCE ';

      // UNION 쿼리 생성
      SQLUnion := '';

      for i := 0 to TableList.Count - 1 do
      begin
        if i > 0 then
          SQLUnion := SQLUnion + ' UNION ALL ';

        SQLUnion := SQLUnion +
          'SELECT ID, LOG_TIME, LOG_LEVEL, SOURCE_NAME, MESSAGE, ADDITIONAL_INFO FROM ' +
          Copy(TableList[i], 1, Pos('=', TableList[i]) - 1) + ' ' + SQLWhere;
      end;

      // 테이블이 없으면 빈 결과 반환
      if SQLUnion = '' then
        Exit;

      // 최종 쿼리 생성 및 실행
      FLogQuery.Close;
      FLogQuery.SQL.Text :=
        SQLUnion + ' ORDER BY LOG_TIME DESC';

      FLogQuery.ParamByName('FROM_DATE').AsDateTime := AFromDate;
      FLogQuery.ParamByName('TO_DATE').AsDateTime := AToDate;

      if LevelStr <> '' then
        FLogQuery.ParamByName('LOG_LEVEL').AsString := LevelStr;

      if ATag <> '' then
        FLogQuery.ParamByName('SOURCE').AsString := '%' + ATag + '%';

      FLogQuery.Open;

      // 결과를 문자열 목록으로 변환
      while not FLogQuery.EOF do
      begin
        LogEntry :=
          FormatDateTime('YYYY-MM-DD HH:NN:SS.ZZZ', FLogQuery.FieldByName('LOG_TIME').AsDateTime) + #9 +
          FLogQuery.FieldByName('LOG_LEVEL').AsString + #9 +
          FLogQuery.FieldByName('SOURCE_NAME').AsString + #9 +
          FLogQuery.FieldByName('MESSAGE').AsString;

        Result.Add(LogEntry);
        FLogQuery.Next;
      end;

      FLogQuery.Close;
    finally
      TableList.Free;
    end;
  except
    on E: Exception do
    begin
      LogWarning('로그 조회 오류: ' + E.Message);
      FreeAndNil(Result);
      Result := TStringList.Create;
    end;
  end;
end;

procedure TDatabaseLogHandler.ManageLogTables;
var
  RetentionDate: TDateTime;
  YearMonth: string;
  TableList: TStringList;
  TableName, TableYM: string;
  i: Integer;
  TableDate: TDateTime;
  Pos: Integer;
begin
  if not FDBConnection.Connected then
    if not ConnectToDatabase then
      Exit;

  try
    // 현재 날짜에서 유지 기간을 뺀 날짜 계산 (기본: 12개월)
    RetentionDate := IncMonth(Now, -FRetentionMonths);
    YearMonth := FormatDateTime('YYYYMM', RetentionDate);

    // 모든 로그 테이블 목록 가져오기
    TableList := GetLogTableList;
    try
      for i := 0 to TableList.Count - 1 do
      begin
        TableName := TableList[i];

        // 테이블 이름에서 날짜 추출 (예: LOG_202101)
        if GetTableDate(TableName, TableDate) then
        begin
          // 보관 기간 초과 테이블 삭제
          if TableDate < RetentionDate then
          begin
            // 테이블 삭제
            ExecuteSQL('DROP TABLE ' + TableName);

            // 시퀀스 삭제
            ExecuteSQL('DROP SEQUENCE GEN_' + TableName + '_ID');

            // 메타테이블에서 삭제
            FMetaQuery.Close;
            FMetaQuery.SQL.Text :=
              'DELETE FROM ' + FMetaTableName +
              ' WHERE TABLE_NAME = :TNAME';

            FMetaQuery.ParamByName('TNAME').AsString := TableName;
            FMetaQuery.ExecSQL;
          end;
        end;
      end;
    finally
      TableList.Free;
    end;
  except
    on E: Exception do
      LogWarning('로그 테이블 관리 오류: ' + E.Message);
  end;
end;

function TDatabaseLogHandler.GetTableDate(const ATableName: string; out ADate: TDateTime): Boolean;
var
  YearMonth: string;
  Year, Month: Integer;
begin
  Result := False;
  ADate := 0;

  // LOG_YYYYMM 형식의 테이블 이름에서 YYYYMM 추출
  if Length(ATableName) >= 9 then
  begin
    YearMonth := Copy(ATableName, 5, 6);

    if TryStrToInt(Copy(YearMonth, 1, 4), Year) and
       TryStrToInt(Copy(YearMonth, 5, 2), Month) then
    begin
      if (Year >= 2000) and (Year <= 2100) and
         (Month >= 1) and (Month <= 12) then
      begin
        ADate := EncodeDate(Year, Month, 1);
        Result := True;
      end;
    end;
  end;
end;

function TDatabaseLogHandler.GetLogTableList: TStringList;
begin
  Result := TStringList.Create;

  if not FDBConnection.Connected then
    if not ConnectToDatabase then
      Exit;

  try
    FMetaQuery.Close;
    FMetaQuery.SQL.Text :=
      'SELECT TABLE_NAME FROM ' + FMetaTableName +
      ' ORDER BY YEAR_MONTH';

    FMetaQuery.Open;

    while not FMetaQuery.EOF do
    begin
      Result.Add(FMetaQuery.FieldByName('TABLE_NAME').AsString);
      FMetaQuery.Next;
    end;

    FMetaQuery.Close;
  except
    on E: Exception do
    begin
      LogWarning('로그 테이블 목록 조회 오류: ' + E.Message);
      FreeAndNil(Result);
      Result := TStringList.Create;
    end;
  end;
end;

function TDatabaseLogHandler.ExecuteSQL(const ASQL: string): Boolean;
begin
  Result := False;

  if not FDBConnection.Connected then
    if not ConnectToDatabase then
      Exit;

  try
    FDBConnection.ExecuteDirect(ASQL);
    Result := True;
  except
    on E: Exception do
      LogWarning('SQL 실행 오류: ' + E.Message + #13#10 + ASQL);
  end;
end;

procedure TDatabaseLogHandler.PerformMaintenance;
begin
  // 유지보수 작업 수행
  if FCurrentLogTable <> '' then
    UpdateLogTableMetrics(FCurrentLogTable);

  // 오래된 테이블 관리
  ManageLogTables;
end;

end.
{
이 코드는 월별 로그 테이블을 자동으로 관리하는 시스템을 구현합니다. 다음과 같은 주요 기능을 포함하고 있습니다:
주요 기능

자동 테이블 생성

월별로 새로운 로그 테이블을 자동 생성합니다 (예: LOG_202504)
각 테이블에 필요한 인덱스를 함께 생성합니다


메타데이터 관리

LOG_META 테이블에서 모든 로그 테이블의 정보를 관리합니다
테이블별 생성 날짜, 마지막 업데이트, 행 수 등을 기록합니다


자동 유지보수

설정된 보관 기간(기본 12개월)이 지난 로그 테이블을 자동 삭제합니다
주기적으로 테이블 메트릭을 업데이트합니다


효율적인 조회

여러 테이블에 걸친 조회를 자동으로 처리합니다
날짜, 로그 레벨, 소스 등으로 필터링할 수 있습니다

다음 설정을 적용했습니다:

데이터베이스 파일: App\log\Log.fdb
Firebird 클라이언트: App\fbclient.dll
자동 경로 생성 및 DB 초기화 포함

이 구현은 로그 데이터가 시간이 지남에 따라 늘어나도 성능이 유지되도록 설계되었습니다.
필요에 따라 RetentionMonths 속성을 조정하여 로그 보관 기간을 변경할 수 있습니다.

이 소스 코드는 다음 요소들을 모두 포함하고 있습니다:

유닛 선언 및 인터페이스 섹션
TDatabaseLogHandler 클래스 정의 및 모든 메서드
구현 섹션의 모든 메서드 구현
DB 생성, 연결, 테이블 관리 등 모든 기능

요청하신 사항(App\log\Log.fdb 경로와 App\fbclient.dll 라이브러리 위치 등)을 모두 반영했습니다.
이 코드를 그대로 GlobalLogger 프로젝트에 포함시켜 사용하실 수 있습니다.

// 데이터베이스 로그 핸들러 등록
var
  DBHandler: TDatabaseLogHandler;
begin
  DBHandler := TDatabaseLogHandler.Create;
  DBHandler.RetentionMonths := 6; // 선택적: 기본값은 12개월
  GlobalLogger.RegisterLogHandler(DBHandler);

  // 이제 로그를 기록하면 자동으로 DB에 저장됩니다
  GlobalLogger.LogInfo('애플리케이션 시작됨');
end;



GlobalLogger와 통합

TLogHandler 클래스를 상속하여 GlobalLogger 시스템과 완벽하게 통합됩니다
DoWriteLog 메서드를 오버라이드하여
GlobalLogger에서 로그 메시지를 받아 데이터베이스에 저장합니다
SourceIdentifier 시스템을 활용하여 로그 소스 정보를 저장합니다


월별 로그 테이블 자동 관리

매월 새로운 테이블을 자동으로 생성합니다 (예: LOG_202504)
LOG_META 테이블에서 모든 로그 테이블의 정보를 관리합니다
지정된 기간(기본 12개월)이 지난 오래된 테이블을 자동으로 삭제합니다


효율적인 다중 테이블 조회

GetLogs 메서드를 통해 여러 테이블에 걸친 로그를 쉽게 조회할 수 있습니다
날짜, 로그 레벨, 태그로 필터링이 가능합니다


Firebird DB 설정

App\log\Log.fdb 경로에 데이터베이스 파일을 생성합니다
App\fbclient.dll 경로의 클라이언트 라이브러리를 사용합니다



이 코드는 다음과 같이 GlobalLogger 시스템에서 사용할 수 있습니다:
// 초기화 예시
var
  DBHandler: TDatabaseLogHandler;
begin
  // 데이터베이스 로그 핸들러 생성 및 등록
  DBHandler := TDatabaseLogHandler.Create;
  DBHandler.RetentionMonths := 6; // 6개월 보관으로 설정
  GlobalLogger.RegisterLogHandler(DBHandler);

  // 이제 GlobalLogger를 통해 기록되는 모든 로그가 DB에도 저장됩니다
  Logger.LogInfo('애플리케이션 시작');
end;
}
