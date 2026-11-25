# Helpers for deploy.sh's desktop-shortcut step. Sourced, never run.
# A PowerShell single-quoted string ends at the next single quote, so a quote inside a Windows path (O'Brien) would end
# the string early and let the rest of the path run as PowerShell code. In a single-quoted string the ONLY special
# character is the quote itself, and doubling it is the escape.
psq() { printf '%s' "${1//\'/\'\'}"; }

# shortcut_ps <lnk path> <exe path> <install dir>: the PowerShell that writes (or keeps) the shortcut; all three are
# Windows paths. It rewrites the .lnk only when its target differs, so a re-run never makes a second one.
shortcut_ps() {
  local lnk exe dir ps
  lnk="$(psq "$1")" exe="$(psq "$2")" dir="$(psq "$3")"
  ps="\$s=(New-Object -ComObject WScript.Shell).CreateShortcut('$lnk');"
  ps+="if(\$s.TargetPath -eq '$exe'){'shortcut already points at $exe'}else{"
  ps+="\$s.TargetPath='$exe';\$s.WorkingDirectory='$dir';\$s.Description='Orcastration Station';\$s.Save();'shortcut written'}"
  printf '%s' "$ps"
}
