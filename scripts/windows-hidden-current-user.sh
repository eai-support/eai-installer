#!/usr/bin/env bash

# Execute a PowerShell script in the signed-in Windows session without letting
# Parallels create a visible console window. The caller supplies the script on
# stdin and an optional logical stdin payload as the second argument.
windows_hidden_current_user_ps() {
  local vm_name="$1"
  local stdin_payload="${2:-}"
  local script nonce base stage_base payload wrapper wrapper_base64 vbs vbs_base64
  local ps_path vbs_path stdout_path stderr_path status_path
  local stage status_text output error_text attempt
  script="$(/bin/cat)"
  [[ -n "$script" ]] || return 2
  nonce="$(/usr/bin/uuidgen | /usr/bin/tr -d '-' | /usr/bin/tr '[:upper:]' '[:lower:]')"
  base="C:\\Users\\Public\\eai-hidden-${nonce}"
  stage_base="${base}.tmp"
  ps_path="${base}\\runner.ps1"
  vbs_path="${base}\\runner.vbs"
  stdout_path="${base}\\runner.stdout"
  stderr_path="${base}\\runner.stderr"
  status_path="${base}\\runner.status"
  payload="$(printf '%s' "$stdin_payload" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  wrapper="$(printf '%s\n' \
    "\$ErrorActionPreference = 'Stop'" \
    "\$__eaiInput = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payload'))" \
    '[Console]::SetIn([IO.StringReader]::new($__eaiInput))' \
    '$__eaiInput = $null' \
    "\$__eaiOut = [IO.StreamWriter]::new('$stdout_path', \$false, [Text.UTF8Encoding]::new(\$false))" \
    "\$__eaiErr = [IO.StreamWriter]::new('$stderr_path', \$false, [Text.UTF8Encoding]::new(\$false))" \
    '[Console]::SetOut($__eaiOut)' \
    '[Console]::SetError($__eaiErr)' \
    '$__eaiExit = 0' \
    'try {' \
    '  $__eaiPipeline = & {' \
    "$script" \
    '  } | Out-String' \
    '  if ($__eaiPipeline) { [Console]::Out.Write($__eaiPipeline) }' \
    '  $__eaiPipeline = $null' \
    '  if ($LASTEXITCODE) { $__eaiExit = $LASTEXITCODE }' \
    '} catch {' \
    '  [Console]::Error.WriteLine(($_ | Out-String))' \
    '  $__eaiExit = 1' \
    '} finally {' \
    '  $__eaiOut.Flush(); $__eaiErr.Flush()' \
    '  $__eaiOut.Dispose(); $__eaiErr.Dispose()' \
    '}' \
    'exit $__eaiExit' \
    '')"
  wrapper_base64="$(printf '%s' "$wrapper" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  vbs="$(printf '%s\r\n' \
    'Set s=CreateObject("WScript.Shell")' \
    'Set f=CreateObject("Scripting.FileSystemObject")' \
    "c=s.Run(\"powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"\"$ps_path\"\"\",0,True)" \
    "Set o=f.CreateTextFile(\"$status_path.tmp\",True)" \
    'o.Write CStr(c)' \
    'o.Close' \
    "f.MoveFile \"$status_path.tmp\",\"$status_path\"")"
  vbs_base64="$(printf '%s' "$vbs" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  stage="$(printf '%s\n' \
    "\$ErrorActionPreference = 'Stop'" \
    "try {" \
    "\$interactiveUser = (Get-CimInstance Win32_ComputerSystem).UserName" \
    "if ([string]::IsNullOrWhiteSpace(\$interactiveUser)) { throw 'No interactive Windows user is available' }" \
    "\$interactiveSid = ([Security.Principal.NTAccount]::new(\$interactiveUser)).Translate([Security.Principal.SecurityIdentifier])" \
    "Remove-Item -LiteralPath '$stage_base' -Recurse -Force -ErrorAction SilentlyContinue" \
    "New-Item -ItemType Directory -Path '$stage_base' -ErrorAction Stop | Out-Null" \
    "\$acl = [Security.AccessControl.DirectorySecurity]::new()" \
    "\$acl.SetAccessRuleProtection(\$true, \$false)" \
    "\$identities = @([Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'),\$interactiveSid)" \
    "foreach (\$identity in \$identities) {" \
    "  \$rule = [Security.AccessControl.FileSystemAccessRule]::new(\$identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')" \
    "  [void]\$acl.AddAccessRule(\$rule)" \
    "}" \
    "Set-Acl -LiteralPath '$stage_base' -AclObject \$acl -ErrorAction Stop" \
    "[IO.File]::WriteAllBytes('$stage_base\\runner.ps1',[Convert]::FromBase64String('$wrapper_base64'))" \
    "[IO.File]::WriteAllBytes('$stage_base\\runner.vbs',[Convert]::FromBase64String('$vbs_base64'))" \
    "Move-Item -LiteralPath '$stage_base' -Destination '$base' -ErrorAction Stop" \
    "Write-Output 'EAI_HIDDEN_WORKER_STAGED'" \
    "exit 0" \
    "} catch {" \
    "  [Console]::Error.WriteLine((\$_ | Out-String))" \
    "  exit 1" \
    "}" \
    '')"
  # `prlctl exec ... powershell -Command -` evaluates complete input records.
  # Keep the protected staging transaction on one record so a compound try
  # block cannot be accepted without ever being invoked.
  stage="$(printf '%s' "$stage" | /usr/bin/perl -0pe 's/\r?\n/;/g; s/\{;/\{ /g; s/;\}/ \}/g')"
  local stage_output=""
  if ! stage_output="$(printf '%s\n' "$stage" | prlctl exec "$vm_name" powershell.exe \
      -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -InputFormat Text -OutputFormat Text -Command - 2>&1)" \
      || [[ "$(printf '%s' "$stage_output" | /usr/bin/tr -d '\r')" != *EAI_HIDDEN_WORKER_STAGED* ]]; then
    [[ -z "$stage_output" ]] || printf '%s\n' "$stage_output" >&2
    printf '%s\n' "Remove-Item -LiteralPath '$stage_base','$base' -Recurse -Force -ErrorAction SilentlyContinue" \
      | prlctl exec "$vm_name" powershell.exe -NoLogo -NoProfile -NonInteractive \
        -InputFormat Text -OutputFormat Text -Command - >/dev/null 2>&1 || true
    return 3
  fi

  if ! prlctl exec "$vm_name" --current-user wscript.exe "$vbs_path" >/dev/null 2>&1; then
    printf '%s\n' "Remove-Item -LiteralPath '$base' -Recurse -Force -ErrorAction SilentlyContinue" \
      | prlctl exec "$vm_name" powershell.exe -NoLogo -NoProfile -NonInteractive \
        -InputFormat Text -OutputFormat Text -Command - >/dev/null 2>&1 || true
    return 4
  fi
  status_text=""
  for attempt in $(seq 1 1800); do
    status_text="$(prlctl exec "$vm_name" cmd.exe /D /Q /C type "$status_path" 2>/dev/null | /usr/bin/tr -d '\r\n' || true)"
    [[ "$status_text" =~ ^-?[0-9]+$ ]] && break
    sleep 1
  done
  if [[ ! "$status_text" =~ ^-?[0-9]+$ ]]; then
    status_text=124
  fi
  output="$(prlctl exec "$vm_name" cmd.exe /D /Q /C type "$stdout_path" 2>/dev/null | /usr/bin/tr -d '\r' | /usr/bin/sed $'1s/^\\xEF\\xBB\\xBF//' || true)"
  error_text="$(prlctl exec "$vm_name" cmd.exe /D /Q /C type "$stderr_path" 2>/dev/null | /usr/bin/tr -d '\r' | /usr/bin/sed $'1s/^\\xEF\\xBB\\xBF//' || true)"
  printf '%s\n' "$output"
  [[ -z "$error_text" ]] || printf '%s\n' "$error_text" >&2
  if [[ "${EAI_WINDOWS_HIDDEN_KEEP_FILES:-0}" != 1 ]]; then
    printf '%s\n' "Remove-Item -LiteralPath '$base' -Recurse -Force -ErrorAction SilentlyContinue" \
      | prlctl exec "$vm_name" powershell.exe -NoLogo -NoProfile -NonInteractive \
        -InputFormat Text -OutputFormat Text -Command - >/dev/null 2>&1 || true
  fi
  [[ "$status_text" == 0 ]]
}
