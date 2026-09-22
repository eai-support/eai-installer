#!/usr/bin/env bash

# This library intentionally exposes only one fixed, read-only guest query. It
# must not become a general retry wrapper: an ambiguous Parallels result can
# never authorize replay of a guest mutation.

windows_is_parallels_exact_job_result_failure() {
  local status="$1"
  local normalized=""
  [[ "$status" == 255 ]] || return 1
  normalized="$(printf '%s' "$2" | /usr/bin/tr -d '\r')"
  case "$normalized" in
    'PrlJob_GetRetCode: Invalid argument. An invalid argument was passed.'|\
    'PrlJob_GetResult: Invalid argument. An invalid argument was passed.')
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

windows_ai_handoff_process_query() {
  local max_attempts=3
  local output=""
  local normalized=""
  local status=1
  local attempt

  for attempt in $(seq 1 "$max_attempts"); do
    if output="$(guest_ps 1 2>&1 <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$expected = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'))
$session = (Get-Process -Id $PID -ErrorAction Stop).SessionId
$matching = @(Get-Process Code -ErrorAction SilentlyContinue | Where-Object {
  $_.SessionId -eq $session -and
  $_.MainWindowHandle -ne 0 -and
  [string]::Equals($_.Path, $expected, [StringComparison]::OrdinalIgnoreCase)
})
if ($matching.Count -eq 0) {
  'EAI_AI_HANDOFF_PROCESS_NOT_READY'
  return
}
if ($matching.Count -ne 1) {
  'EAI_AI_HANDOFF_PROCESS_AMBIGUOUS'
  return
}
'EAI_AI_HANDOFF_PROCESS_READY:{0}' -f [int]$matching[0].Id
POWERSHELL
)"; then
      status=0
    else
      status=$?
    fi

    if [[ "$status" == 0 ]]; then
      normalized="$(printf '%s' "$output" | /usr/bin/tr -d '\r')"
      case "$normalized" in
        EAI_AI_HANDOFF_PROCESS_NOT_READY)
          printf '%s\n' "$normalized"
          return 0
          ;;
        EAI_AI_HANDOFF_PROCESS_READY:*)
          [[ "${normalized#EAI_AI_HANDOFF_PROCESS_READY:}" =~ ^[1-9][0-9]*$ ]] || {
            printf '%s\n' 'The fixed Windows AI handoff process query returned invalid output.' >&2
            return 65
          }
          printf '%s\n' "$normalized"
          return 0
          ;;
        *)
          printf '%s\n' 'The fixed Windows AI handoff process query returned invalid output.' >&2
          return 65
          ;;
      esac
    fi

    if windows_is_parallels_exact_job_result_failure "$status" "$output"; then
      if [[ "$attempt" -lt "$max_attempts" ]]; then
        printf '%s read-only Windows AI handoff process query transport unavailable; retry %s/%s\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$attempt" "$max_attempts" >&2
        sleep 2
        continue
      fi
    fi

    printf '%s\n' "$output" >&2
    return "$status"
  done

  return "$status"
}
