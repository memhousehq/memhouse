@echo off
REM SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0
REM Applies packaged-release migrations without starting Phoenix.
setlocal
set "RELEASE_ROOT=%~dp0.."
call "%~dp0memhouse.bat" eval "MemHouse.Release.migrate()"
exit /b %ERRORLEVEL%
