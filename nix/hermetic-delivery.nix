# A copy of the `logos-delivery` flake's package set with zerokit's pmtree
# tests made hermetic. See logos-workspace#126.
#
# zerokit's rln crate has three tests that name the ABSOLUTE path
# `/tmp/pmtree-test-path`, and two of them open a sled database there:
#
#   rln/tests/pm_tree.rs        test_pmtree_config_from_str
#   rln/tests/public.rs         test_tree_config_input_trait
#   rln/src/pm_tree_adapter.rs  test_pmtree_json_config   (parse only)
#
# Nix on darwin does not give a build its own /tmp, so the first build to run
# them leaves that directory behind owned by whichever `_nixbld` user ran it.
# `/tmp` is sticky, so nobody else can remove it -- and every later build runs
# as a DIFFERENT `_nixbld` user, cannot write into it, and dies with
#
#   PmtreeErrorKind(DatabaseError(CustomError("Cannot create database:
#   IO error: Permission denied (os error 13) ...
#
# which takes every Android and iOS build on that machine with it, because the
# mobile catalog pulls in delivery_module and its `generate` step builds this
# library. It stays invisible for as long as the store path survives.
#
# The fix is applied here rather than upstream because neither vacp2p/zerokit
# nor logos-messaging/logos-delivery is ours to push to. It rewrites the
# hardcoded path to a RELATIVE one, so each test gets its own directory inside
# the build tree: the tests still run (a `--skip` would drop them), and the
# build no longer touches shared state. Distinct names per file because cargo
# runs the test binaries concurrently from the same working directory and sled
# takes an exclusive lock on its directory.
#
# `--replace-fail` on purpose: if upstream changes those literals this build
# stops, rather than silently going back to writing into /tmp.
{ lib, delivery }:

let
  hermeticRln = rln: rln.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace rln/tests/pm_tree.rs \
        --replace-fail '"/tmp/pmtree-test-path"' '"pmtree-test-path-pm-tree"'
      substituteInPlace rln/tests/public.rs \
        --replace-fail '"/tmp/pmtree-test-path"' '"pmtree-test-path-public"'
      substituteInPlace rln/src/pm_tree_adapter.rs \
        --replace-fail '"/tmp/pmtree-test-path"' '"pmtree-test-path-adapter"'
    '';
  });

  # Every package `logos-delivery` builds from nix/default.nix takes the rln
  # derivation as the named argument `zerokitRln`, so `.override` swaps it for
  # the hermetic one -- overrideAttrs could not, the dependency is baked into
  # the call, not into the attrs.
  patchSystem = system:
    let
      upstream = delivery.packages.${system};
      rln = hermeticRln upstream.rln;
      relink = pkg: pkg.override { zerokitRln = rln; };
      liblogosdelivery = relink upstream.liblogosdelivery;
    in
    upstream // {
      inherit rln liblogosdelivery;
      wakucanary = relink upstream.wakucanary;
      logosdeliverynode = relink upstream.logosdeliverynode;
      default = liblogosdelivery;
    };
in
# Shaped like a flake input (`packages.<system>.<name>`) so it can be handed to
# `externalLibInputs.<name>.input` in place of the real one.
{
  packages = lib.genAttrs (builtins.attrNames delivery.packages) patchSystem;
}
