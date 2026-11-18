@echo off
chcp 65001 >nul
cd /d "%~dp0"
rem 在「桌面」创建快捷方式，指向当前目录的 XMCP控制台.bat。
rem 程序目录里不放 .lnk：目录被拷贝到别的盘时，旧 .lnk 仍指向老路径，一点就启动老目录那份。
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$d='%~dp0'.TrimEnd('\\'); $desk=[Environment]::GetFolderPath('Desktop'); $lnk=Join-Path $desk 'XMCP 反代工具.lnk'; $s=(New-Object -ComObject WScript.Shell).CreateShortcut($lnk); $s.TargetPath=(Join-Path $d 'XMCP控制台.bat'); $s.WorkingDirectory=$d; $s.IconLocation=(Join-Path $d 'xmcp.ico')+',0'; $s.Description='XMCP 反代工具'; $s.WindowStyle=7; $s.Save(); Write-Host ('  已创建桌面快捷方式: '+$lnk)"
exit /b 0
