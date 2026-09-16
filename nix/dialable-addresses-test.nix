# Compiles and runs logos-delivery's own tests for the patch that
# nix/dialable-addresses.nix carries. See logos-workspace#209.
#
# WHY A CHECK OF ITS OWN. The patch adds three test files' worth of cases to a
# repo whose nix build runs no tests at all (`nix/default.nix` compiles the
# library and stops), so without this the only thing asserting the fix would be
# the fact that it still compiles. Each of the three fails on the unpatched
# tree -- measured, not assumed:
#
#   test_dialable             the rule itself, 10 pure cases transferred from
#                             logos-libp2p-module's addr_filter suite (#206)
#   test_delivery_dialer      a dial whose every address is un-dialable must
#                             name them and never reach a transport
#   test_announced_addresses  two cases added to the file that already owns
#                             this subject: no peerInfo commit DURING start may
#                             carry the wildcard, and the peer record screens
#                             what it hands out before start resolves anything
#
# THE nim COMMAND is logos-delivery's own nix/default.nix, minus the library
# flags (`--app:lib`, the C bindings) and plus what its tests/nim.cfg would
# want. Its deps come from the same `nix/deps.nix` the library build reads, out
# of the PATCHED source, so a dependency bump moves both together.
#
# rln is linked as the static archive rather than `-lrln`: Cargo bakes an
# absolute build-directory path as the dylib's install name, and the library
# build only survives it because postInstall rewrites the image afterwards.
# A test binary has no such step.
#
# nat_traversal is copied and its bundled C sub-libraries built first, exactly
# as logos-delivery's buildPhase does -- `{.passl.}` names their archives, so
# they must exist before the link.
{ pkgs, deliverySrc, deliveryPatches, rln }:

let
  deps = import (deliverySrc + "/nix/deps.nix") { inherit pkgs; };
  otherDeps = builtins.removeAttrs deps [ "nat_traversal" ];
  pathArgs = builtins.concatStringsSep " " (builtins.concatMap
    (p: [ "--path:${p}" "--path:${p}/src" "--path:${p}/sds" ])
    (builtins.attrValues otherDeps));

  suites = [
    "tests/test_dialable.nim"
    "tests/test_delivery_dialer.nim"
    "tests/test_announced_addresses.nim"
  ];
in
pkgs.stdenv.mkDerivation {
  pname = "liblogosdelivery-dialable-addresses-test";
  version = "dev";

  src = deliverySrc;
  # The tests this runs are part of the diff, so the same list the library is
  # built with is what makes them exist at all.
  patches = deliveryPatches;

  nativeBuildInputs = with pkgs; [ nim-2_2 git gnumake which ]
    ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.darwin.cctools ];

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    export XDG_CACHE_HOME=$TMPDIR/.cache
    export NIMBLE_DIR=$TMPDIR/.nimble
    export NIMCACHE=$TMPDIR/nimcache
    mkdir -p $NIMCACHE build

    NAT_TRAV=$TMPDIR/nat_traversal
    cp -r ${deps.nat_traversal} $NAT_TRAV
    chmod -R +w $NAT_TRAV
    make -C $NAT_TRAV/vendor/miniupnp/miniupnpc \
      CFLAGS="-Os -fPIC" build/libminiupnpc.a
    make -C $NAT_TRAV/vendor/libnatpmp-upstream \
      CFLAGS="-Wall -Os -fPIC -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4" libnatpmp.a

    for suite in ${builtins.concatStringsSep " " suites}; do
      echo "== compiling $suite"
      nim c \
        --noNimblePath \
        ${pathArgs} \
        --path:$NAT_TRAV \
        --path:$NAT_TRAV/src \
        --path:. \
        --passL:"${rln}/lib/librln.a${pkgs.lib.optionalString pkgs.stdenv.isLinux " -lstdc++"}" \
        --define:disable_libbacktrace \
        --define:libp2p_mix_experimental_exit_is_dest \
        --define:libp2p_quic_support \
        --define:git_version=check \
        --define:discv5_protocol_id=d5waku \
        --define:chronicles_log_level=WARN \
        --threads:on \
        --mm:refc \
        --nimcache:$NIMCACHE \
        --out:build/$(basename $suite .nim) \
        $suite
    done
    runHook postBuild
  '';

  # unittest2 exits non-zero on any failed case, so `set -e` is the assertion.
  # The transcript is kept in $out so a reviewer can read what ran without
  # rebuilding: a passing Nim test prints its summary and nothing else.
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    for suite in ${builtins.concatStringsSep " " suites}; do
      name=$(basename $suite .nim)
      echo "== running $name"
      ./build/$name 2>&1 | tee -a $out/result
      test "''${PIPESTATUS[0]}" -eq 0
    done
    runHook postInstall
  '';

  dontFixup = true;
}
