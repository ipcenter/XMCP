@echo off
chcp 65001 >nul
cd /d "%~dp0"
rem 在桌面创建快捷方式，直连 powershell.exe 隐藏拉起控制台（不经 cmd/bat 启动层）。
rem 程序目录里不放 .lnk：目录被拷贝到别的盘时，旧 .lnk 仍指向老路径，一点就启动老目录那份。
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$d='%~dp0'.TrimEnd('\\'); $desk=[Environment]::GetFolderPath('Desktop'); $lnk=Join-Path $desk 'XMCP 反代工具.lnk'; $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; $ps1=Join-Path $d 'XMCP控制台.ps1'; $q=[char]34; $s=(New-Object -ComObject WScript.Shell).CreateShortcut($lnk); $s.TargetPath=$ps; $s.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File '+$q+$ps1+$q; $s.WorkingDirectory=$d; $s.IconLocation=(Join-Path $d 'xmcp.ico')+',0'; $s.Description='XMCP 反代工具'; $s.WindowStyle=7; $s.Save(); Write-Host ('  已创建桌面快捷方式: '+$lnk)"
exit /b 0
