program GlobalLogger_test;
{$mode objfpc}{$H+}
uses
    {$IFDEF UNIX}
    cthreads,
    {$ENDIF}
    {$IFDEF HASAMIGA}
    athreads,
    {$ENDIF}
    Interfaces, // this includes the LCL widgetset
    Forms,
    SysUtils, // ExtractFilePath 함수를 위해 추가
    Classes,
    GlobalLogger, LogHandlers, FileHandler, PrintfHandler, // 로깅 관련 유닛
    unit1, datetimectrls
    { you can add units after this };

procedure InitializeLogger;
var
  FileHandler: TFileHandler;
  PrintfHandler: TPrintfHandler;
begin
  // 로거 기본 설정
  Logger.LogLevels := [llDebug..llFatal];
  Logger.IndentMode := imAuto;

  // 파일 핸들러 설정 - 빈 경로를 전달하여 날짜별 디렉토리 사용
  FileHandler := Logger.AddFileHandler('', 'app');
  FileHandler.SourceIdentifier := 'File';
  FileHandler.RotationMode := lrmSize; // 날짜는 이미 폴더로 구분되므로 사이즈 기반 회전 사용

  // Printf 핸들러 설정 - 생성자에서 자동으로 날짜별 디렉토리 사용
  PrintfHandler := Logger.AddPrintfHandler;
  PrintfHandler.SourceIdentifier := 'UI';
  PrintfHandler.SetFormDesign('WM747_LOG', 500, 400, fpTopRight);
  PrintfHandler.ColorByLevel := True;
  PrintfHandler.ShowDateInTimeColumn:= False;  // 실시간 로그폼에 일자표시 여부
  // 로그 로테이션 설정
  PrintfHandler.AutoRotate := True;           // 자동 로테이션 활성화
  PrintfHandler.RotateLineCount := 1000;      // 1000줄 이상이면 로테이션
  PrintfHandler.RotateSaveBeforeClear := True; // 클리어 전에 파일로 저장

  PrintfHandler.ShowForm(True);

end;

{$R *.res}
begin
  RequireDerivedFormResource := True;
    Application.Scaled:=True;
  Application.Initialize;

  // 로거 초기화 - 파일 핸들러와 PrintfHandler가 자동으로 날짜별 디렉토리 사용
  InitializeLogger;

  // 로그 세션 시작
  Logger.StartLogSession;
  Logger.LogInfo('애플리케이션 시작...');

  // 메인 폼 생성
  Application.CreateForm(TForm1, Form1);

  try
    Application.Run;
  finally
    Logger.LogInfo('애플리케이션 종료 중...');
    Logger.FlushAllBuffers;  // 모든 버퍼 플러시
  end;
end.
