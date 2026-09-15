param(
  [string]$Command = 'C:\dsh\start-dsh.cmd',
  [string]$TaskName = 'DshSessionTask'
)
$ErrorActionPreference = 'Continue'
$log = 'C:\dsh\session-task.log'
Remove-Item $log -Force -ErrorAction SilentlyContinue
function L($m) { Add-Content -LiteralPath $log -Value $m -Encoding UTF8 }

$user = "$env:COMPUTERNAME\$env:USERNAME"
L ('[' + (Get-Date -Format 'HH:mm:ss') + '] command=' + $Command + ' task=' + $TaskName + ' principal=' + $user)

$svc = New-Object -ComObject Schedule.Service
$svc.Connect()
$root = $svc.GetFolder('\')
try { $root.DeleteTask($TaskName, 0) } catch {}

$TASK_CREATE_OR_UPDATE = 6
$TASK_LOGON_INTERACTIVE_TOKEN = 3

try {
  $td = $svc.NewTask(0)
  $td.RegistrationInfo.Description = 'Run one DSH-related command in the interactive desktop session'
  $td.Settings.AllowDemandStart = $true
  $td.Settings.Enabled = $true
  $td.Settings.ExecutionTimeLimit = 'PT0S'
  $td.Settings.DisallowStartIfOnBatteries = $false
  $td.Settings.StopIfGoingOnBatteries = $false
  $td.Principal.UserId = $user
  $td.Principal.RunLevel = 0
  $a = $td.Actions.Create(0)
  $a.Path = $Command
  $a.WorkingDirectory = 'C:\dsh'
  $null = $root.RegisterTaskDefinition($TaskName, $td, $TASK_CREATE_OR_UPDATE, $user, $null, $TASK_LOGON_INTERACTIVE_TOKEN, $null)
  L 'registered OK'
  $task = $root.GetTask($TaskName)
  $task.Run($null) | Out-Null
  L 'started'
} catch {
  L ('FAILED: ' + $_.Exception.Message)
}
L 'done'
