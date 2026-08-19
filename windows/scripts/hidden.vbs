' Launch the batch file given as argument 1 with no visible console window.
' Used by the Startup shortcuts and the daily scheduled task so that
' nothing pops up on the desktop while the bot is running.
Option Explicit
Dim sh
If WScript.Arguments.Count < 1 Then WScript.Quit 1
Set sh = CreateObject("WScript.Shell")
sh.Run """" & WScript.Arguments(0) & """", 0, False
