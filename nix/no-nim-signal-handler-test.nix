# liblogosdelivery must not carry Nim's own signal handler.
#
# WHY. Nim's `system/excpt.nim` installs `signalHandler` for SIGSEGV, SIGBUS,
# SIGABRT, SIGFPE, SIGILL and SIGINT from a module-init section, so it is armed
# by `liblogosdeliveryNimMain` -- i.e. the moment delivery_module loads. It is
# PROCESS-wide: from then on a fault anywhere in the host (Qt, another module,
# the Shell itself) is delivered to it. And the handler's first act is
#
#   var buf = newStringOfCap(2000)   # -> newObjNoInit -> rawNewObj -> rawAlloc
#
# a GC allocation, on the faulting thread's own stack, from async-signal
# context. If the fault it is handling is one the allocator cannot itself
# survive -- an exhausted stack, or a fault inside `rawAlloc` -- it re-faults
# inside its own first statement and is re-entered, for ever:
#
#   rawAlloc / rawNewObj / newObjNoInit / signalHandler / _sigtramp / rawNewObj …
#
# That is logos-workspace#150: a crash report whose every frame belongs to the
# handler and not one frame to the code that actually failed. A signal handler
# that allocates cannot report anything, so the library is built with
# `--define:noSignalHandler` and the platform's own reporter (the iOS crash
# reporter, a core file, lldb) sees the real fault instead.
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
