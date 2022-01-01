Name "Kite Updater"
VIProductVersion "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"  ; for some reason we need this, too
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "Copyright © Kite 2017"
VIAddVersionKey "FileDescription" "Kite Updater"
VIAddVersionKey "ProductName" "Kite Updater"
VIAddVersionKey "OriginalFilename" "KiteUpdater.exe"
VIAddVersionKey "InternalName" "KiteUpdater"
OutFile "current_build_bin\out\KiteUpdater.exe"
Icon "..\tools\artwork\icon\app.ico"
SetCompressor /SOLID lzma
RequestExecutionLevel admin
SilentInstall silent

Var executable_type ; e.g. "installer" "uninstaller" "updater"
Var machine_id_already_existed
Var redist

!include "LogicLib.nsh"
!include "WordFunc.nsh"
!include "StrFunc.nsh"
${StrLoc} ; must initialize this before it can be used in a Function (a nuance of StrFunc.nsh)
${UnStrLoc}
${StrRep}
${UnStrRep}
!include "FileFunc.nsh"
!include "WinVer.nsh"
!include "GetProcessInfo.nsh"
!include "servicelib.nsh"
!include "NsisIncludes\Debug.nsh"
!include "NsisIncludes\CheckAlreadyRunningInstallOrUninstall.nsh"
!include "NsisIncludes\FindKiteInstallationFolder.nsh"
!include "NsisIncludes\KillAllAvailableRunningInstances.nsh"

!define OutputDebugString `System::Call kernel32::OutputDebugString(ts)`

Section ""
	; we are a 32 bit installer, uninstaller, and updater, but the main Kite binaries are 64-bit, so we
	;   try to standardize on the 64-bit view where possible.
	SetRegView 64

	StrCpy $executable_type "updater"

	Call SilentCheckAlreadyRunningInstallOrUninstall
	Pop $0
	${If} $0 != 0
		${Debug} "Installer/uninstaller/updater is already running.  Quiting."
		Quit
	${EndIf}

	Call FindKiteInstallationFolder
	Pop $0
	${If} $0 == ""
		${Debug} "Could not find installation folder.  Quiting."
		Quit
	${EndIf}
	${Debug} "Installation found at $0"

	; === DO NOT CLOBBER $0 AFTER THIS POINT ===

	; Compare versions to make sure the version in this updater is newer than the preexisting one
	${Debug} "Checking versions..."
	GetTempFileName $1 "$0\"
	File "/oname=$1" "current_build_bin\in\KiteService.exe"
	${GetFileVersion} "$1" $2
	Delete $1
	${If} $2 == ""
		${Debug} "Could not read embedded KiteService.exe version.  Quiting.  (Kited.exe was not killed and KiteService was not stopped.)"
		Quit
	${EndIf}
	${GetFileVersion} "$0\KiteService.exe" $3
	${If} $2 == ""
		${Debug} "Could not read existing KiteService.exe version -- continuing..."
		Goto done_version_compare
	${EndIf}
	${VersionCompare} $2 $3 $4
	${If} $4 != 1
		${Debug} "The existing version is either equal or greater ($2 $3 $4).  Quiting.  (kited.exe was not killed, KiteService was not stopped.)"
		Quit
	${EndIf}
	done_version_compare:
	${Debug} "Versions check out.  We are newer.  Continuing..."

	; === DO NOT CLOBBER $0 AFTER THIS POINT ===

	; Kill kited.exe (and Kite.exe) if it's running
	Call KillAllAvailableRunningInstances

	; Remove existing KiteOnboarding.exe (its depricated now)
	Delete /REBOOTOK "$0\KiteOnboarding.exe"
	Delete /REBOOTOK "$0\KiteOnboarding.exe.config"

	; === DO NOT CLOBBER $0 AFTER THIS POINT ===

	; Try to stop service, as well, so we can update it
	${Debug} "Stopping service..."
	!insertmacro SERVICE "stop" "KiteService" ""
	; wait for service to exit
	; the WaitProcEnd call works iff elevated.  same goes for stopping it.  we're elvated.
	; note we aren't calling KillProc/TerminateProcess; this is a graceful exit.
	; this timeout empirically works most times I've tested it; ultimately we're comfortable
	;   without a TerminalProcess() fallback because if there's an issue here we can
	;   just change the updater and old clients will still run/get it.
	FindProcDLL::WaitProcEnd "KiteService.exe" 20000
	${If} $R0 == 100
		${Debug} "Timed out waiting for service to exit gracefully.  Exiting update."
		!insertmacro SERVICE "start" "KiteService" ""
		Quit
	${Else}
		${Debug} "Service exited successfully"
	${EndIf}

	; === DO NOT CLOBBER $0 AFTER THIS POINT ===

	;; Misc updates now that we are shipping with the sidebar:

	; Update/Add protocol handler
	WriteRegStr HKLM "Software\Classes\kite" "" "URL:kite"
	WriteRegStr HKLM "Software\Classes\kite" "URL Protocol" ""
	WriteRegStr HKLM "Software\Classes\kite\shell\open\command" "" '"$0\win-unpacked\Kite.exe" "%1"'

	; Update 'Run' key in registry
	; NOTE: This doesn't work because the user running the updater is different from the user that installed
	; Kite originally. This is currently handled by client/internal/autostart/autostart_windows.go once kited is restarted.
	; WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Kite" '"$0\kited.exe" --system-boot'

	; Remove local settings link, no longer needed
	SetShellVarContext all
	Delete /REBOOTOK "$SMPROGRAMS\Kite\Kite Local Settings.lnk"

	; Copy files
	${Debug} "Copying files..."
	SetOutPath "$0\"
	SetOverwrite try

	ClearErrors
	RMDir /r "$0\win-unpacked" ; remove old win-unpacked directory before replacing
	File /r "current_build_bin\in\win-unpacked"
	IfErrors 0 no_kite_file_copy_error
		${Debug} "Error encountered when trying to replace win-unpacked directory.  Relaunching service, then quiting.  Service might restart kited.exe."
		!insertmacro SERVICE "start" "KiteService" ""
		Quit
	no_kite_file_copy_error:

	ClearErrors
	File "current_build_bin\in\kited.exe"
	IfErrors 0 no_kited_file_copy_error
		${Debug} "Error encountered when trying to replace kited.exe.  Relaunching service, then quiting.  Service might restart kited.exe."
		!insertmacro SERVICE "start" "KiteService" ""
		Quit
	no_kited_file_copy_error:

	ClearErrors
 	ReadRegDword $redist HKLM "SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" "Installed"
	IfErrors 0 redist_found
		File "current_build_bin\in\vc_redist.x64.exe"
		ExecWait '"$0\vc_redist.x64.exe" /install /passive /quiet /norestart'
		Delete /REBOOTOK "$0\vc_redist.x64.exe"
	redist_found:

	File "current_build_bin\in\KiteService.exe"
	File "current_build_bin\in\KiteService.exe.config"
	File "current_build_bin\in\tensorflow.dll"
	File "current_build_bin\out\Uninstaller.exe"

	; Start new service
	${Debug} "Starting KiteService (which might start kited.exe)..."
	!insertmacro SERVICE "start" "KiteService" ""

	; Don't restart kited.exe.  It will be restarted from the service using
	; impersonation.

	${Debug} "Done with update.  Quiting."
SectionEnd
