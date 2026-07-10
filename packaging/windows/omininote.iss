; Inno Setup script for OminiNote (Windows) — per-user install (no admin) that
; registers the .omninote file type + the omninote:// URL scheme so double-
; clicking a notebook file / invoking a link opens and imports it. The app reads
; the file/URL from the launch argument ("%1").
;
; Build: flutter build windows --release, then
;   iscc packaging\windows\omininote.iss
; Output: omininote-windows-setup.exe at the repo root.

#define AppName "OminiNote"
#define AppExe "omininote.exe"
#define AppVersion "1.0.0"
#define AppPublisher "OminiNote"

[Setup]
AppId={{B3F1A2C4-5D6E-4F70-9A81-2C3D4E5F6071}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\OminiNote
DefaultGroupName=OminiNote
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#AppExe}
OutputBaseFilename=omininote-windows-setup
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Paths below are relative to the repo root.
SourceDir=..\..
OutputDir=.

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\OminiNote"; Filename: "{app}\{#AppExe}"
Name: "{userdesktop}\OminiNote"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Registry]
; .omninote file association
Root: HKCU; Subkey: "Software\Classes\.omninote"; ValueType: string; ValueData: "OminiNote.Notebook"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\OminiNote.Notebook"; ValueType: string; ValueData: "OminiNote Notebook"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\OminiNote.Notebook\DefaultIcon"; ValueType: string; ValueData: "{app}\{#AppExe},0"
Root: HKCU; Subkey: "Software\Classes\OminiNote.Notebook\shell\open\command"; ValueType: string; ValueData: """{app}\{#AppExe}"" ""%1"""
; omninote:// URL scheme
Root: HKCU; Subkey: "Software\Classes\omninote"; ValueType: string; ValueData: "URL:OminiNote Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\omninote"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\omninote\DefaultIcon"; ValueType: string; ValueData: "{app}\{#AppExe},0"
Root: HKCU; Subkey: "Software\Classes\omninote\shell\open\command"; ValueType: string; ValueData: """{app}\{#AppExe}"" ""%1"""

[Run]
Filename: "{app}\{#AppExe}"; Description: "Launch OminiNote"; Flags: nowait postinstall skipifsilent
