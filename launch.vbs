' Hidden launcher for the Explorer context menu.
'
' wscript.exe is a GUI-subsystem host: creating it never brings up a console.
' PowerShell is then started with window state 0 (SW_HIDE), so its console is
' created hidden instead of being shown first and hidden afterwards. Calling
' powershell.exe straight from the menu cannot do that: Explorer passes
' SW_SHOWNORMAL, and -WindowStyle Hidden only takes effect once the console
' already exists, which is the flash the user sees.
'
' Kept ASCII-only on purpose: Windows Script Host reads BOM-less files with the
' ANSI code page, so non-ASCII text would come out as mojibake.
Option Explicit

Dim shell, here, scriptPath, powershell, target, command
Set shell = CreateObject("WScript.Shell")

here = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
scriptPath = here & "launch.ps1"
powershell = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"

target = ""
If WScript.Arguments.Count > 0 Then
  If Len(WScript.Arguments(0)) > 0 Then target = " """ & WScript.Arguments(0) & """"
End If

command = """" & powershell & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """" & target

' 0 = hidden window, False = do not wait for PowerShell to finish
shell.Run command, 0, False
