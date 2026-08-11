#!/usr/bin/env bash

_install_stat_stub() {
  local mockbin="$1" dialect="$2" real_stat
  real_stat="$(command -v stat)"
  mkdir -p "$mockbin"
  cat > "$mockbin/stat" <<EOF
#!/usr/bin/env bash
dialect='$dialect'; real_stat='$real_stat'
fmt="\${2-}"; path="\${3-}"
if [[ "\$dialect" == gnu && "\${1-}" == -f ]]; then printf '  File: "%s"\n    ID: 1 Namelen: 255 Type: fake\n' "\$path"; exit 1; fi
if [[ "\$dialect" == bsd && "\${1-}" == -c ]]; then echo 'stat: illegal option -- c' >&2; exit 1; fi
case "\$dialect:\$fmt" in
  gnu:%Y|bsd:%m) exec "\$real_stat" -f %m "\$path" ;;
  gnu:%s|bsd:%z) exec "\$real_stat" -f %z "\$path" ;;
  gnu:%a) exec "\$real_stat" -f %Lp "\$path" ;;
  bsd:%p) exec "\$real_stat" -f %p "\$path" ;;
  gnu:%u|bsd:%u) exec "\$real_stat" -f %u "\$path" ;;
  gnu:%i|bsd:%i) exec "\$real_stat" -f %i "\$path" ;;
esac
exit 1
EOF
  chmod +x "$mockbin/stat"
}

stub_gnu_stat() { _install_stat_stub "$1" gnu; }
stub_bsd_stat() { _install_stat_stub "$1" bsd; }
unstub_stat() { rm -f "$1/stat"; }
