@echo off
chcp 65001 >nul
cd /d "%~dp0"
rem 在桌面创建快捷方式，优先指向原生启动器 XMCP.Relay.exe（内嵌 X 图标）；exe 缺失才回退直连 powershell。
rem 程序目录里不放 .lnk：目录被拷贝到别的盘时，旧 .lnk 仍指向老路径，一点就启动老目录那份。
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$d='%~dp0'.TrimEnd('\\'); $desk=[Environment]::GetFolderPath('Desktop'); $lnk=Join-Path $desk 'XMCP 反代工具.lnk'; $exe=Join-Path $d 'XMCP.Relay.exe'; $ps1=Join-Path $d 'XMCP控制台.ps1'; $ico=Join-Path $d 'xmcp.ico'; $q=[char]34; $s=(New-Object -ComObject WScript.Shell).CreateShortcut($lnk); if(Test-Path $exe){ $s.TargetPath=$exe; $s.Arguments=''; $s.IconLocation=$exe+',0' } else { $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; $s.TargetPath=$ps; $s.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File '+$q+$ps1+$q; $s.IconLocation=$ico+',0' }; $s.WorkingDirectory=$d; $s.Description='XMCP 反代工具'; $s.WindowStyle=7; $s.Save(); Write-Host ('  已创建桌面快捷方式: '+$lnk)"
exit /b 0
