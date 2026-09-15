# A copy of the `logos-delivery` package set built with `--define:noSignalHandler`.
# See logos-workspace#150, and nix/no-nim-signal-handler-test.nix for what that
# buys and how it is asserted.
#
# Nim installs `signalHandler` for SIGSEGV/SIGBUS/SIGABRT/SIGFPE/SIGILL/SIGINT
# from a module-init section, so `liblogosdeliveryNimMain` arms it the moment
# delivery_module loads -- and it is the whole PROCESS's handler from then on,
# for faults that have nothing to do with this library. The handler's first
# statement is a GC allocation (`newStringOfCap(2000)`), which is neither
# async-signal-safe nor survivable when the fault being handled is an exhausted
# stack or a fault inside the allocator: it re-faults inside itself and recurses
# until the guard page, and the crash report is nothing but handler frames.
#
# A LIBRARY LOADED INTO SOMEONE ELSE'S PROCESS HAS NO BUSINESS OWNING THE
# PROCESS'S SIGNAL DISPOSITIONS. Removing the handler is not a loss of
# diagnostics: with it gone the fault reaches the platform's own reporter -- the
# iOS crash reporter, a core file, lldb -- which reports the real frames, which
# is exactly what #150 could not get.
#
# WHY nim.cfg AND NOT A FLAG. `logos-delivery`'s nix/default.nix bakes its whole
# `nim c` command line into buildPhase and takes no extra-flags argument, so the
# lever a consumer has is the config file nim reads for that project directory.
# `library/nim.cfg` is already that file (its `--mm:refc` / `--threads:on` are in
# effect), and a command-line flag still wins over it, so nothing upstream sets
# is displaced. The mobile leg writes its own `nim c` line and names the define
# there directly -- see nix/mobile-libs.nix.
#
# Applied here rather than upstream because logos-messaging/logos-delivery is not
# ours to push to; same bargain as nix/hermetic-delivery.nix.
{ delivery }:

let
  withoutNimSignalHandler = pkg: pkg.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      # Loud rather than silent if the file ever moves: appending to a nim.cfg
      # that nim does not read would turn this into a no-op nobody notices.
      test -f library/nim.cfg || {
        echo "no-nim-signal-handler: library/nim.cfg is gone; the define has no home" >&2
        exit 1
      }
      cat >> library/nim.cfg <<'EOF'

      # logos-workspace#150: a signal handler that allocates cannot report
      # anything, and a library must not own the host process's dispositions.
      --define:noSignalHandler
      EOF
    '';
  });

  # `liblogosdelivery` is the one package delivery_module consumes, and
  # `default` is the same derivation under another name -- kept in step so the
  # two cannot drift into two different builds. `rln` is Rust and has no nim.cfg;
  # the apps are executables nobody here builds, and an executable owning its own
  # signal dispositions is a different (defensible) choice from a library doing
  # it, so they are left alone.
  patched = ps:
    let lib' = withoutNimSignalHandler ps.liblogosdelivery;
    in ps // { liblogosdelivery = lib'; default = lib'; };
in
# Shaped like a flake input, exactly as nix/hermetic-delivery.nix is, so the two
# compose: hermetic first (it calls `.override`, which would drop an
# `overrideAttrs` applied before it), this second.
{
  packages = builtins.mapAttrs (_system: patched) delivery.packages;
}
