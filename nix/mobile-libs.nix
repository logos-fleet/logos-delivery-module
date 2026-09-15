# delivery_module's two `nix.external_libraries`, CROSS-BUILT for one of
# logos-nix's mobile pseudo-systems.
#
# WHY THIS FILE IS HERE AND NOT IN logos-module-builder. A module's
# `nix.external_libraries` are staged into lib/ by its own `generate` step as
# BUILD-PLATFORM images, and nothing in the builder can recompile them -- each
# comes from its own flake, and only the consumer knows how that flake builds.
# So the builder asks the module's flake for a per-target build
# (`externalLibInputs.<name>.mobilePackages`) and stages it over the
# build-platform image. This is delivery_module's answer, and it has to answer
# for TWO libraries where libp2p_module answered for one.
#
# STATIC ARCHIVES, where the desktop module links shared libraries: a Bare
# module on a phone carries every third-party library inside its own image.
# `<App>.app/Frameworks/` holds frameworks, not loose dylibs, and on Android a
# `liblogosdelivery.so` sitting beside the module would be an unbundled soname
# and fail the DT_NEEDED gate.
#
# ONE ARCHIVE, NOT TWO. `librln.a` is merged INTO `liblogosdelivery.a`, because
# only `logosdelivery` is named in CMakeLists' EXTERNAL_LIBS -- `rln` is a
# transitive dependency that the desktop resolves at load time through the
# bundled dylib, and there is no load time to resolve it at inside a static
# link. Leaving it out links (both mobile shapes tolerate undefined symbols by
# design) and dies at the first RLN call. `rln`'s own `mobilePackages` still
# returns the target archive: the builder refuses an entry with no build for
# the target by name, and the honest answer to "where is rln for aarch64-ios"
# is this derivation, not a null.
#
# TWO THINGS THE DESKTOP BUILD GETS ELSEWHERE:
#
#   miniupnpc /   nat_traversal reaches them with `{.passl: <abs>/lib*.a.}`, a
#   libnatpmp     LINK-time flag. `--app:staticlib` never links, so they are
#                 absent from the nim archive; they are built for the target
#                 here and merged in. On iOS `getgateway.c` cannot be built at
#                 all -- the SDK has no <net/route.h> -- so logos-delivery's own
#                 `library/ios_natpmp_stubs.c` supplies getdefaultgateway(),
#                 exactly as its `libLogosDeliveryIOS` nimble task does.
#   postgres      OFF. `--define:postgres` makes liblogosdelivery dlopen libpq,
#                 and a phone has no libpq to open. That is a behavioural
#                 decision, stated here rather than implied: delivery_module on
#                 a phone has no Postgres-backed store.
{
  lib,
  # logos-module-builder's OWN package-set constructor, because it is the one
  # that carries logos-nix's native overlays -- today the crates.io 403 fixes,
  # without which vendoring rln's dependency tree fails at the first download
  # ("error: cannot download crate-vacp2p_pmtree-2.0.3.tar.gz from any mirror",
  # measured here). A plain `import nixpkgs { }` silently loses them.
  mkPkgsWith,
  rust-overlay,
  deliverySrc,
  rustTargets,
}:

{
  system,
  pkgs,
  buildSystem,
}:

let
  isAndroid = system == "aarch64-android";

  # nim, cargo and the dependency sources RUN on the builder; only the code
  # they emit is for the phone. Same shape as the builder's own Rust cross: a
  # cross toolchain is chosen on the build platform, never taken from the
  # target set (for iOS the target set has no runnable stdenv at all).
  bp = pkgs.pkgsBuildBuild;

  rustTriple = rustTargets.${system}
    or (throw "logos-delivery-module: no cargo target known for ${system}");

  # ── rln (zerokit), for the target ───────────────────────────────────────
  # From logos-delivery's OWN vendored submodule rather than a new flake input:
  # the rev is kept in sync with the `zerokit` flake input it links on the
  # desktop (nix/zerokit.nix), so this is the same rln, built for a phone.
  zerokitSrc = deliverySrc + "/vendor/zerokit";

  # rust-overlay rather than nixpkgs' rustc: only rust-overlay can add a
  # target's std to an existing toolchain, and nixpkgs' cross rustPlatform
  # would have to come from the TARGET package set.
  rustPkgs = mkPkgsWith [ (import rust-overlay) ] buildSystem;
  rustToolchain = rustPkgs.rust-bin.stable.latest.default.override {
    targets = [ rustTriple ];
  };
  rustPlatform = rustPkgs.makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };

  rlnArchive = rustPlatform.buildRustPackage {
    pname = "rln-${system}";
    version = "2.0.2";
    src = zerokitSrc;
    cargoLock.lockFile = zerokitSrc + "/Cargo.lock";

    doCheck = false;
    # This derivation runs in the BUILD platform's stdenv (so cargo is
    # runnable) and produces a TARGET archive, so fixup's strip is the wrong
    # one -- see the same note on nimArchive below.
    dontStrip = true;
    # iOS reaches Xcode through /Applications (logos-nix ADR 0002); the Android
    # NDK is in the store and needs no escape hatch.
    __noChroot = !isAndroid;

    # `cargo rustc --crate-type staticlib`, not `cargo build --lib`: rln
    # declares `["rlib", "staticlib", "cdylib"]`, and the cdylib half is both
    # unwanted here and the one that would have to satisfy a real link.
    # cargoBuildHook would also derive --target from the stdenv's HOST
    # platform, which is the BUILDER.
    buildPhase = ''
      runHook preBuild
      ${pkgs.logosRustCrossSetup}
      export CARGO_HOME=$TMPDIR/cargo
      cargo rustc --release --offline --locked --lib \
        --manifest-path rln/Cargo.toml \
        --target ${rustTriple} --crate-type staticlib
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib
      cp target/${rustTriple}/release/librln.a $out/lib/
      runHook postInstall
    '';
  };

  # ── liblogosdelivery (nim), for the target ──────────────────────────────
  deps = import (deliverySrc + "/nix/deps.nix") { pkgs = bp; };

  # nat_traversal is excluded from the static path args and passed from a
  # writable copy, exactly as logos-delivery's own nix/default.nix does.
  otherDeps = builtins.removeAttrs deps [ "nat_traversal" ];
  pathArgs = lib.concatStringsSep " " (lib.concatMap
    (p: [ "--path:${p}" "--path:${p}/src" "--path:${p}/sds" ])
    (builtins.attrValues otherDeps));

  natTraversalSrc = deps.nat_traversal;

  # Where Xcode / the NDK are, from the repo that owns that decision.
  #
  # Android is the exception libp2p_module did not hit: logos-delivery's own
  # `config.nims` has an `if defined(android)` block that sets `clang.path` to
  # $ANDROID_TOOLCHAIN_DIR/bin, and nim composes path+exe -- so logos-nix's
  # ABSOLUTE `--clang.exe=` becomes `<ndk>/bin/<absolute path>` and nothing
  # runs. The working combination is to let config.nims own the toolchain and
  # hand it the three environment variables it reads. They are DERIVED from
  # logos-nix's own flag rather than restated, so a bump that moves the NDK
  # moves both.
  androidClangPath = lib.removePrefix "--clang.exe="
    (lib.head (lib.filter (lib.hasPrefix "--clang.exe=") pkgs.logosNimCrossFlags));
  androidToolchainDir = builtins.dirOf (builtins.dirOf androidClangPath);

  nimCrossFlags =
    if isAndroid
    then "--os:android --cpu:arm64 --cc:clang -d:androidNDK -d:chronosEventEngine=epoll"
    else lib.concatStringsSep " " pkgs.logosNimCrossFlags;

  nimCrossSetup =
    if isAndroid then ''
      export ANDROID_COMPILER=${builtins.baseNameOf androidClangPath}
      export ANDROID_TOOLCHAIN_DIR=${androidToolchainDir}
      export ANDROID_ARCH=aarch64-linux-android
    '' else pkgs.logosNimCrossSetup;

  # config.nims' default branch adds `-march=native` to passC AND passL for
  # anything that is not Windows, Android or macOS-on-arm64 -- and nim does not
  # define `macosx` for `--os:ios`. `-d:disableMarchNative` routes into the
  # branch that asks about i386/amd64 first and so contributes nothing on
  # arm64. Its macOS-only `-Wno-error=incompatible-function-pointer-types`
  # (nim-chronos vs nim-bearssl's `const` PEM callback) is skipped for the same
  # reason and has to be named again: Apple's clang is Apple's clang whether
  # the SDK says macOS or iOS.
  iosNimFlags = lib.optionalString (!isAndroid)
    "-d:disableMarchNative --passC:-Wno-error=incompatible-function-pointer-types";

  nimArchive = bp.stdenv.mkDerivation {
    pname = "liblogosdelivery-${system}";
    version = "dev";
    src = deliverySrc;

    nativeBuildInputs = [ bp.nim-2_2 bp.git bp.gnumake bp.which ];

    __noChroot = !isAndroid;

    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR XDG_CACHE_HOME=$TMPDIR/.cache
      export NIMBLE_DIR=$TMPDIR/.nimble NIMCACHE=$TMPDIR/nimcache
      mkdir -p build $NIMCACHE

      NAT_TRAV=$TMPDIR/nat_traversal
      cp -r ${natTraversalSrc} $NAT_TRAV
      chmod -R +w $NAT_TRAV

      # logosNimCrossSetup appends to this; on Android it is unused, because
      # there config.nims resolves the toolchain from the environment instead.
      nimFlagsArray=()
      ${nimCrossSetup}

      # The argument list is logos-delivery's own nix/default.nix verbatim,
      # minus `--define:postgres` and minus the `--passL:` for librln (nothing
      # is linked here), plus the cross flags and `--define:noSignalHandler`.
      #
      # THE DEFINE. Nim installs a PROCESS-wide SIGSEGV/SIGBUS/SIGABRT handler
      # from a module-init section, so it is armed the moment this archive's
      # NimMain runs -- inside the Shell, for every fault in it, Qt's included.
      # And the handler allocates (`newStringOfCap(2000)`) on the faulting
      # thread's stack, so a fault it cannot allocate through re-enters it for
      # ever; logos-workspace#150 is a mobile crash report made of nothing but
      # those frames. Without it the iOS crash reporter sees the real fault.
      # The desktop leg gets the same define through nim.cfg -- it does not
      # write its own `nim c` line; see nix/no-nim-signal-handler.nix.
      nim c ${nimCrossFlags} "''${nimFlagsArray[@]}" \
        --noNimblePath ${pathArgs} \
        --path:$NAT_TRAV --path:$NAT_TRAV/src \
        --define:disable_libbacktrace \
        --define:git_version=mobile \
        --define:nimDebugDlOpen \
        --define:noSignalHandler \
        ${iosNimFlags} \
        --threads:on --mm:refc --nimcache:$NIMCACHE \
        --app:staticlib --opt:size --noMain \
        --nimMainPrefix:liblogosdelivery \
        --out:build/liblogosdelivery.a \
        library/liblogosdelivery.nim
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib $out/include
      cp build/liblogosdelivery.a $out/lib/
      cp library/liblogosdelivery.h $out/include/
      cp library/liblogosdelivery_kernel.h $out/include/
      runHook postInstall
    '';

    # This derivation runs in the BUILD platform's stdenv (so nim is runnable)
    # and produces a TARGET archive, so fixup's strip is the wrong one.
    # Measured on aarch64-darwin: Darwin's strip rewrites an aarch64-android
    # archive's index into BSD's `__.SYMDEF SORTED`, and ld.lld then rejects it
    # with "not an ELF file" naming the `/` member.
    dontStrip = true;
  };

  # ── the vendored C, and the archive they all share ──────────────────────
  # In the TARGET's own stdenv, because `$AR` has to write an index the
  # target's linker reads and `$CC` has to emit the target's objects. Xcode's
  # clang for iOS (nix's cc-wrapper cannot target it), the NDK cross stdenv for
  # Android.
  mkTargetDrv = if isAndroid then pkgs.stdenv.mkDerivation else pkgs.xcodeClang.mkDerivation;

  # xcodeClang's preConfigure exports CC/AR out of xcrun, but a plain compile
  # gets no sysroot or triple from that. Named here, from logos-nix's own
  # spelling of this platform, so the objects are not quietly macOS ones.
  iosFlags = lib.optionalString (!isAndroid)
    "--target=${pkgs.logosIosTriple} -isysroot $(xcrun --sdk ${pkgs.logosIosAppleSdk} --show-sdk-path)";

  # libnatpmp's gateway discovery, the one vendored source file whose compile
  # differs by target.
  natpmpGatewayCompile =
    if isAndroid then ''
      # bionic IS linux, so getgateway.c's /proc/net/route branch is the right
      # one and NAT-PMP gateway discovery works.
      "$CC" $CFLAGS_TARGET -I"$NATPMP" -DENABLE_STRNATPMPERR \
        -c "$NATPMP/getgateway.c" -o objs/natpmp_getgateway.o
    '' else ''
      # No <net/route.h> in either iOS SDK, so getgateway.c cannot be built at
      # all; logos-delivery ships the stub that returns failure.
      "$CC" $CFLAGS_TARGET -c ${deliverySrc}/library/ios_natpmp_stubs.c \
        -o objs/natpmp_getgateway_stub.o
    '';

  # What miniupnpc puts in its UPnP User-Agent. The device, not the builder.
  uaOsString = if isAndroid then "Android/aarch64" else "iOS/aarch64";
  miniupnpcFiles = [
    "addr_is_reserved.c" "connecthostport.c" "igd_desc_parse.c"
    "minisoap.c" "minissdpc.c" "miniupnpc.c" "miniwget.c"
    "minixml.c" "portlistingparse.c" "receivedata.c" "upnpcommands.c"
    "upnpdev.c" "upnperrors.c" "upnpreplyparse.c"
  ];

in
{
  rln = rlnArchive;

  logosdelivery = mkTargetDrv {
    pname = "logosdelivery-${system}";
    version = "dev";

    dontUnpack = true;
    # xcodeClang.mkDerivation puts cmake on PATH for the projects that want it;
    # this is a handful of .c files, a copy and an archive.
    dontUseCmakeConfigure = true;

    buildPhase = ''
      runHook preBuild
      mkdir -p $out/lib $out/include objs

      NAT_TRAV=$TMPDIR/nat_traversal
      cp -r ${natTraversalSrc} $NAT_TRAV
      chmod -R +w $NAT_TRAV
      MINIUPNPC=$NAT_TRAV/vendor/miniupnp/miniupnpc
      NATPMP=$NAT_TRAV/vendor/libnatpmp-upstream

      CFLAGS_TARGET="${iosFlags} -Os -fPIC"

      # --- miniupnpc's generated header ---
      # `build/miniupnpcstrings.h` is normally produced by the Makefile through
      # updateminiupnpcstrings.sh, which reads `uname` -- so on a cross build it
      # would name the BUILDER. The two macros go into the UPnP User-Agent, so
      # the honest value is the target's, and the sed is the script's own.
      mkdir -p "$MINIUPNPC/build"
      sed -e 's|OS_STRING ".*"|OS_STRING "${uaOsString}"|' \
          -e "s|MINIUPNPC_VERSION_STRING \".*\"|MINIUPNPC_VERSION_STRING \"$(cat "$MINIUPNPC/VERSION")\"|" \
          "$MINIUPNPC/miniupnpcstrings.h.in" > "$MINIUPNPC/build/miniupnpcstrings.h"

      # --- miniupnpc ---
      # The file list is logos-delivery's own `libLogosDeliveryIOS` task's,
      # rather than `make`'s: the Makefile's link and install rules are for a
      # host build, and on iOS its `uname`-driven branches answer for the Mac.
      for f in ${lib.concatStringsSep " " miniupnpcFiles}; do
        [ -f "$MINIUPNPC/src/$f" ] || continue
        "$CC" $CFLAGS_TARGET \
          -I"$MINIUPNPC/include" -I"$MINIUPNPC/src" -I"$MINIUPNPC/build" \
          -DMINIUPNPC_SET_SOCKET_TIMEOUT -D_BSD_SOURCE -D_DEFAULT_SOURCE \
          -c "$MINIUPNPC/src/$f" -o "objs/miniupnpc_''${f%.c}.o"
      done

      # --- libnatpmp ---
      "$CC" $CFLAGS_TARGET -I"$NATPMP" -DENABLE_STRNATPMPERR \
        -c "$NATPMP/natpmp.c" -o objs/natpmp_natpmp.o
      ${natpmpGatewayCompile}

      # --- one archive ---
      # `ar r` INTO the nim archive rather than a merge of several: there is one
      # external library as far as _logos_find_external_lib is concerned, and it
      # resolves exactly one file.
      cp ${nimArchive}/lib/liblogosdelivery.a $out/lib/liblogosdelivery.a
      chmod u+w $out/lib/liblogosdelivery.a
      "$AR" r $out/lib/liblogosdelivery.a objs/*.o

      # rln's members, unpacked and re-added. Extracting rather than `ar r`-ing
      # the archive itself: `ar` would store librln.a as a single member, which
      # no linker looks inside.
      #
      # BY NAME, filtered to the objects. A blanket `ar x` also writes the
      # archive INDEX out as a file -- Apple's ar calls it `__.SYMDEF SORTED`,
      # and extracting it fails with "ar: rlnobjs/__.SYMDEF: Permission denied",
      # a message about the symbol table that reads like a message about the
      # sandbox. The NDK's llvm-ar skips it silently, so this only ever showed
      # up on the iOS leg.
      mkdir -p rlnobjs
      "$AR" t ${rlnArchive}/lib/librln.a | grep -E '\.o$' > members.txt
      ( cd rlnobjs && tr '\n' '\0' < ../members.txt \
          | xargs -0 "$AR" x ${rlnArchive}/lib/librln.a )
      "$AR" r $out/lib/liblogosdelivery.a rlnobjs/*.o

      cp ${nimArchive}/include/*.h $out/include/
      runHook postBuild
    '';

    dontInstall = true;
    # The archive is the artifact and nothing may rewrite it: the build
    # platform's strip is the wrong one for every target here.
    dontFixup = true;
  };
}
