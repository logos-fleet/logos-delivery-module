# liblogosdelivery must not carry Nim's own signal handler.
#
# WHY. nix/no-nim-signal-handler.nix records it, and logos-workspace#150 is what
# it cost: Nim's `system/excpt.nim` arms `signalHandler` for SIGSEGV, SIGBUS,
# SIGABRT, SIGFPE, SIGILL and SIGINT from a module-init section, so it becomes
# the whole PROCESS's handler the moment delivery_module loads -- and its first
# statement is a GC allocation, which a fault in the allocator or on an
# exhausted stack cannot survive, so the handler re-enters itself for ever and
# the crash report holds nothing but its own frames. The library is therefore
# built with `--define:noSignalHandler`; this check is what keeps it that way.
#
# WHAT THIS ASSERTS, AND WHY BY STRING. Under the define Nim never compiles the
# proc, so its message literals go with it. Asserting on the LITERAL rather than
# on an `nm` symbol because the Nim symbols are local (`t`), and a stripped image
# would then answer "absent" to every symbol query -- a green check for a build
# that still installs the handler. String constants survive stripping. The
# sentinel below fails the check outright if the image has no Nim runtime
# literals at all, so the real assertion can never pass vacuously.
#
# `grep -a` over the image rather than `strings`: `strings` is in neither
# stdenv's default PATH (measured -- "strings: command not found" on
# aarch64-darwin), and a literal with no newline in it needs no extraction.
{ pkgs, liblogosdelivery }:

let
  # system/excpt.nim's SIGSEGV arm of `processSignal`.
  handlerLiteral = "SIGSEGV: Illegal storage access";
  # system/fatal.nim's index error, emitted by every Nim binary.
  sentinelLiteral = "index out of bounds";
in
pkgs.runCommand "liblogosdelivery-no-nim-signal-handler" { } ''
  set -eu
  images=$(find ${liblogosdelivery}/lib \
             \( -name 'liblogosdelivery.so' -o -name 'liblogosdelivery.dylib' \
                -o -name 'liblogosdelivery.dll' -o -name 'liblogosdelivery.a' \) | sort)
  [ -n "$images" ] || { echo "FAIL: no liblogosdelivery image under ${liblogosdelivery}/lib"; exit 1; }

  rc=0
  for img in $images; do
    echo "== $img"
    if ! LC_ALL=C grep -q -a -F '${sentinelLiteral}' "$img"; then
      echo "FAIL: no Nim runtime literal ('${sentinelLiteral}') in this image."
      echo "      Whatever it is, it is not a Nim build this check can read, so"
      echo "      the assertion below would pass vacuously."
      rc=1
      continue
    fi
    if LC_ALL=C grep -q -a -F '${handlerLiteral}' "$img"; then
      echo "FAIL: built WITH Nim's signal handler ('${handlerLiteral}' is present)."
      echo "      Add --define:noSignalHandler to this build (logos-workspace#150)."
      rc=1
    else
      echo "ok: no Nim signal handler"
    fi
  done

  [ $rc -eq 0 ] || exit 1
  mkdir -p $out
  echo ok > $out/result
''
