@echo off
REM SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0
REM
REM Windows entry point for a running MemHouse node: the command a person runs
REM after unpacking the release. Mirrors the Unix bin/server launcher.
REM
REM Purpose
REM   Make "unpack and run" work with no configuration while leaving every
REM   decision overridable. Creates a private data directory and a persistent
REM   token signing secret on first run, defaults the node to supervising its
REM   own embedded PostgreSQL, then hands off to the generated release launcher.
REM
REM Environment - all optional; anything already set is left alone
REM   MEMHOUSE_DATA_ROOT      Local state directory. Default is .memhouse in
REM                            the user profile.
REM   MEMHOUSE_AUTH_SIGNING_SECRET  Token signing key. Generated and stored on
REM                            first run when absent.
REM   MEMHOUSE_DATABASE_MODE  pg0 for the embedded engine - the default here -
REM                            or external for an operator-run PostgreSQL.
REM   MEMHOUSE_AUTO_MIGRATE   Apply pending migrations during boot.
REM   MEMHOUSE_PG0_BINARY     Path to the embedded PostgreSQL launcher.
REM   MEMHOUSE_PG0_DATA_DIR   PostgreSQL cluster directory.
REM   MEMHOUSE_BLOB_ROOT      Local document blob storage directory.
REM
REM Outputs
REM   A running node in this console window, plus - on first run - the data
REM   root, the signing secret file, and the PostgreSQL cluster and blob
REM   directories once the node boots.
REM
REM Assumptions
REM   Only the unpacked release ships an embedded database. The container image
REM   deliberately contains no pg0 and is pointed at a stock PostgreSQL service,
REM   so nothing here has a container equivalent.
REM
REM Failure behaviour
REM   Configuration is validated by the node itself at startup, before any
REM   durable service starts; an unusable combination stops the boot there
REM   rather than in this script.
REM
REM Maintenance notes for editors of this file
REM   Comments inside a parenthesised if-block must avoid parentheses: a stray
REM   closing paren would end the block early. Variables assigned inside such a
REM   block also cannot be read back with percent-expansion until the block
REM   ends, which is why nothing below does that.
setlocal
if "%MEMHOUSE_DATA_ROOT%"=="" set MEMHOUSE_DATA_ROOT=%USERPROFILE%\.memhouse
if not exist "%MEMHOUSE_DATA_ROOT%" mkdir "%MEMHOUSE_DATA_ROOT%"
REM Generate the signing secret once and keep it. Minting a new one per start
REM would invalidate every previously issued token on every restart. 48
REM cryptographically random bytes base64-encoded give a value long enough to
REM satisfy the node's minimum signing-secret length. -NoNewline matters: a
REM trailing newline would be read back below as part of the secret.
if "%MEMHOUSE_AUTH_SIGNING_SECRET%"=="" (
  if not exist "%MEMHOUSE_DATA_ROOT%\auth-signing-secret" (
    powershell -NoProfile -Command "$b=New-Object byte[] 48;[Security.Cryptography.RandomNumberGenerator]::Fill($b);[Convert]::ToBase64String($b)|Set-Content -NoNewline '%MEMHOUSE_DATA_ROOT%\auth-signing-secret'"
  )
  set /p MEMHOUSE_AUTH_SIGNING_SECRET=<"%MEMHOUSE_DATA_ROOT%\auth-signing-secret"
)
REM Each default is applied only when the caller left the variable empty, so an
REM operator's own value always wins.
REM
REM The database default is the embedded engine, because a person who just
REM unpacked the release has no PostgreSQL to point at. %~dp0 is this script's
REM own directory, so the launcher is found inside the release wherever it was
REM unpacked. Migrations run during boot, before the node serves traffic.
REM Start-up ordering is enforced by the node rather than by this script: the
REM embedded PostgreSQL is started before the Repo connects and before
REM migrations run, since neither can proceed until the engine is listening.
if "%MEMHOUSE_DATABASE_MODE%"=="" set MEMHOUSE_DATABASE_MODE=pg0
if "%MEMHOUSE_AUTO_MIGRATE%"=="" set MEMHOUSE_AUTO_MIGRATE=true
if "%MEMHOUSE_PG0_BINARY%"=="" set MEMHOUSE_PG0_BINARY=%~dp0pg0.exe
if "%MEMHOUSE_PG0_DATA_DIR%"=="" set MEMHOUSE_PG0_DATA_DIR=%MEMHOUSE_DATA_ROOT%\pg0\instances\memhouse\data
if "%MEMHOUSE_BLOB_ROOT%"=="" set MEMHOUSE_BLOB_ROOT=%MEMHOUSE_DATA_ROOT%\blobs
REM Without this the release starts the application but never opens the HTTP
REM endpoint - correct for eval and remote-console style invocations, wrong for
REM a server.
set PHX_SERVER=true
REM `call` keeps this console attached to the node so Ctrl-C reaches it and the
REM shutdown is orderly, which is also what stops the embedded PostgreSQL
REM cleanly. setlocal above confines every variable set here to this process
REM tree, leaving the user's environment untouched.
call "%~dp0memhouse.bat" start
