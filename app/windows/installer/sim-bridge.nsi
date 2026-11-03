; Sim Bridge for Windows: per-user installer and uninstaller.
;
; Build from app/ after `flutter build windows --release`:
;   makensis /DVERSION=1.0.0 /DVI_VERSION=1.0.0.6 \
;     /DSRC=build\windows\x64\runner\Release /DOUTFILE=Sim-Bridge-1.0.0-windows-x64-setup.exe \
;     windows\installer\sim-bridge.nsi
;
; Installs for the current user only, so no administrator prompt is needed. User data
; (pairing, keys and settings) lives outside the install folder and survives updates and
; uninstalling. Silent mode (/S) is used by the in-app updater; /RELAUNCH starts Sim Bridge
; again after a silent update.

Unicode true
!macro REQUIRE name
  !ifndef ${name}
    !error "Define ${name} on the makensis command line."
  !endif
!macroend
!insertmacro REQUIRE VERSION
!insertmacro REQUIRE VI_VERSION
!insertmacro REQUIRE SRC
!insertmacro REQUIRE OUTFILE

!define APP_NAME "Sim Bridge"
!define APP_EXE "sim_bridge.exe"
!define PUBLISHER "rennerdo30"
!define HOMEPAGE "https://sim-bridge.renner.dev"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\SimBridge"
!define WINDOW_CLASS "FLUTTER_RUNNER_WIN32_WINDOW"

Name "${APP_NAME}"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\Sim Bridge"
InstallDirRegKey HKCU "${UNINSTALL_KEY}" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
ManifestDPIAware true
BrandingText "${APP_NAME} ${VERSION}"

VIProductVersion "${VI_VERSION}"
VIAddVersionKey "ProductName" "${APP_NAME}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "FileDescription" "${APP_NAME} Setup"
VIAddVersionKey "CompanyName" "${PUBLISHER}"
VIAddVersionKey "LegalCopyright" "MIT License"

!include MUI2.nsh
!include LogicLib.nsh
!include x64.nsh
!include FileFunc.nsh

!define MUI_ICON "..\runner\resources\app_icon.ico"
!define MUI_UNICON "..\runner\resources\app_icon.ico"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_FUNCTION LaunchApp
!define MUI_FINISHPAGE_SHOWREADME
!define MUI_FINISHPAGE_SHOWREADME_TEXT "$(DesktopShortcut)"
!define MUI_FINISHPAGE_SHOWREADME_FUNCTION CreateDesktopShortcut
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "German"

LangString DesktopShortcut ${LANG_ENGLISH} "Create a desktop shortcut"
LangString DesktopShortcut ${LANG_GERMAN} "Verknüpfung auf dem Desktop erstellen"
LangString NeedsX64 ${LANG_ENGLISH} "Sim Bridge requires 64-bit Windows."
LangString NeedsX64 ${LANG_GERMAN} "Sim Bridge benötigt 64-Bit-Windows."
LangString StillRunning ${LANG_ENGLISH} "Sim Bridge is still running. Close it, then choose Retry."
LangString StillRunning ${LANG_GERMAN} "Sim Bridge läuft noch. Schließe die App und wähle dann Wiederholen."
LangString WelcomeText ${LANG_ENGLISH} "This installs Sim Bridge ${VERSION} for your Windows account.$\r$\n$\r$\nYour pairing and settings are kept when you update or uninstall."
LangString WelcomeText ${LANG_GERMAN} "Damit wird Sim Bridge ${VERSION} für dein Windows-Konto installiert.$\r$\n$\r$\nKopplung und Einstellungen bleiben beim Aktualisieren und Deinstallieren erhalten."
!define MUI_WELCOMEPAGE_TEXT "$(WelcomeText)"

Var Relaunch

; Waits for a running Sim Bridge window to close. The in-app updater quits the app just
; before it starts this installer, so a short wait covers the normal update path.
!macro WAIT_FOR_EXIT prefix
Function ${prefix}WaitForExit
  StrCpy $1 0
  ${Do}
    FindWindow $0 "${WINDOW_CLASS}" "${APP_NAME}"
    ${If} $0 = 0
      Return
    ${EndIf}
    ${If} $1 >= 20
      IfSilent 0 +2
        Abort
      MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "$(StillRunning)" /SD IDCANCEL IDRETRY +2
        Abort
      StrCpy $1 0
    ${EndIf}
    Sleep 500
    IntOp $1 $1 + 1
  ${Loop}
FunctionEnd
!macroend
!insertmacro WAIT_FOR_EXIT ""
!insertmacro WAIT_FOR_EXIT "un."

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "$(NeedsX64)" /SD IDOK
    Abort
  ${EndIf}
  ${GetParameters} $0
  ClearErrors
  ${GetOptions} $0 "/RELAUNCH" $1
  ${IfNot} ${Errors}
    StrCpy $Relaunch 1
  ${EndIf}
FunctionEnd

Function LaunchApp
  Exec '"$INSTDIR\${APP_EXE}"'
FunctionEnd

Function CreateDesktopShortcut
  CreateShortCut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"
FunctionEnd

Section "Sim Bridge" SecMain
  SectionIn RO
  Call WaitForExit
  SetOutPath "$INSTDIR"
  ; Replace the program files completely, so no file from an older version remains.
  RMDir /r "$INSTDIR\data"
  File /r "${SRC}\*.*"
  WriteUninstaller "$INSTDIR\Uninstall Sim Bridge.exe"
  CreateShortCut "$SMPROGRAMS\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"

  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "URLInfoAbout" "${HOMEPAGE}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\${APP_EXE}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall Sim Bridge.exe"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall Sim Bridge.exe" /S'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "EstimatedSize" "$0"

  ${If} $Relaunch == 1
    Call LaunchApp
  ${EndIf}
SectionEnd

Section "Uninstall"
  Call un.WaitForExit
  Delete "$SMPROGRAMS\${APP_NAME}.lnk"
  Delete "$DESKTOP\${APP_NAME}.lnk"
  ; Only the program folder is removed, and only if it really holds Sim Bridge; pairing
  ; and settings in the user profile stay, so reinstalling keeps the bridge.
  ${If} ${FileExists} "$INSTDIR\${APP_EXE}"
    RMDir /r "$INSTDIR"
  ${EndIf}
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
SectionEnd
