; Frame's Windows installer (Inno Setup). Built by .github/workflows/windows.yml.
; Installs for the current user only, so Windows doesn't ask for an administrator password,
; adds a Start menu entry (and a desktop icon if wanted), and an uninstaller.

#ifndef AppVersion
  #define AppVersion "0.1"
#endif

[Setup]
AppId={{6C1F2B7E-6A43-4C7E-9E3B-5F0E1C2A9D41}
AppName=Frame
AppVersion={#AppVersion}
AppPublisher=Frame
DefaultDirName={localappdata}\Programs\Frame
DefaultGroupName=Frame
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=Output
OutputBaseFilename=FrameSetup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName=Frame
; Frame's icon on the installer itself and in Windows' list of installed apps.
SetupIconFile=..\packaging\app_icon.ico
UninstallDisplayIcon={app}\Frame.ico

[Tasks]
Name: "desktopicon"; Description: "Add a desktop icon"; GroupDescription: "Shortcuts:"

[Files]
; Everything Flutter built: the app, its DLLs (including the video player) and its data.
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Frame's icon, for the shortcuts and the list of installed apps.
Source: "..\packaging\app_icon.ico"; DestDir: "{app}"; DestName: "Frame.ico"; Flags: ignoreversion

[InstallDelete]
; Older versions installed the program as player_test.exe: remove it so only Frame.exe is left.
Type: files; Name: "{app}\player_test.exe"

[Icons]
; The shortcuts use Frame's icon file directly, so they show it even if Windows has an old
; icon cached for the program.
Name: "{autoprograms}\Frame"; Filename: "{app}\Frame.exe"; IconFilename: "{app}\Frame.ico"
Name: "{autodesktop}\Frame"; Filename: "{app}\Frame.exe"; IconFilename: "{app}\Frame.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\Frame.exe"; Description: "Open Frame"; Flags: nowait postinstall skipifsilent
