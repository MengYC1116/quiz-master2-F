; quiz-master2 Inno Setup script (one-click installer)
; ------------------------------------------------------------------
; How to use:
;   1. Install Inno Setup 6 from https://jrsoftware.org/isdl.php
;   2. In D:\quiz-master2-F run:
;        git checkout -- pubspec.lock
;        flutter pub get
;        flutter build windows --release
;   3. Put this file in the repo root (D:\quiz-master2-F\quiz-master2.iss)
;   4. Double-click it (opens Inno Setup Compiler) and press Ctrl+F9,
;      or run: "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" quiz-master2.iss
;   5. Output: D:\quiz-master2-F\Output\quiz-master2-Setup-0.1.0.exe
;      (single file - send this one file to other people)
;
; Notes:
; - Installs to Program Files. The app's own data (question database)
;   lives per-user in %LOCALAPPDATA%\quiz-master2, so installing to
;   Program Files is fine and each machine starts with an empty library.
; - The YOLO model file (assets/models/question/yolo11s-question-v1.onnx)
;   is bundled automatically as a Flutter asset, as long as it is in the
;   repo when you run `flutter build windows --release`.

#define MyAppName "quiz-master2"
#define MyAppVersion "0.1.0"
#define MyAppPublisher "quiz-master2"
#define MyAppExeName "quiz_master2.exe"

[Setup]
AppId={{4d210961-8753-4c68-a3a0-d4129218f81e}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin
OutputDir=Output
OutputBaseFilename=quiz-master2-Setup-{#MyAppVersion}
SetupIconFile=windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb"

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
