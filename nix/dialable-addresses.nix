# A copy of the `logos-delivery` package set that neither publishes nor dials
# an address no connect() could ever have completed. See logos-workspace#209
# and nix/patches/dialable-addresses.patch.
#
# WHAT WENT WRONG. On the venue's physical iPad the delivery switch
# (`agentVersion: logos-delivery-mobile`) published `/ip4/0.0.0.0/tcp/53024`
# into its signed peer record and `/ip4/0.0.0.0/tcp/0` into its
# `wakuPeerRecord`, and its dialer then took whatever discovery handed back.
# 364 of the run's 866 `Dialing failed` lines were against `/ip4/0.0.0.0/...`
# or `/tcp/0` -- listen arguments that leaked into somebody's peer record, and
# are invalid as destinations by construction. The OTHER switch in that run,
# `libp2p_module`, accounted for 0: logos-workspace#206 had already screened it.
#
# WHAT THE PATCH DOES, in three places:
#
#   logos_delivery/waku/net/dialable.nim   the rule, as pure functions over a
#                                          MultiAddress, with its own unit suite
#   .../node/waku_node.nim                 the publish side: the base address
#                                          mapper resolves the listen addresses
#                                          for the window BEFORE start resolves
#                                          the announced base (libp2p's
#                                          service-discovery signs and publishes
#                                          peerInfo.addrs inside it), and the
#                                          peer-record getter screens what it
#                                          hands out
#   .../node/delivery_dialer.nim           the dial side: DeliveryDialer already
#                                          replaces the switch dialer, so every
#                                          dial in the process passes through
#                                          one screen
#
# WHY HERE AND NOT UPSTREAM. Neither logos-messaging/logos-delivery nor
# vacp2p/nim-libp2p is ours to push to, and neither is forked under logos-fleet.
# Same bargain as nix/hermetic-delivery.nix and nix/no-nim-signal-handler.nix:
# the diff is reviewable in a Logos repo, and it carries its own tests
# (tests/test_dialable.nim, tests/test_delivery_dialer.nim, and two cases added
# to tests/test_announced_addresses.nim) which nix/dialable-addresses-test.nix
# compiles and runs as a check.
#
# The dial side is deliberately NOT in nim-libp2p's dialer, where the issue
# first proposed it. `DeliveryDialer` is waku's own dial policy layer and
# already sits in front of every dial in the process, so the rule lands in code
# we can patch instead of in a third-party dependency fetched by nimble.lock.
#
# `patches` rather than a `postPatch` substitution: this adds files and moves a
# proc between modules, which `substituteInPlace` cannot express. patch(1)
# fails the build if any hunk no longer applies, which is the same loud-on-drift
# bargain `--replace-fail` makes in nix/hermetic-delivery.nix.
{ delivery, patches }:

let
  # Only the nim library is patched. `rln` is Rust, built from the vendored
  # zerokit submodule, and has none of these files; `default` is the same
  # derivation as `liblogosdelivery` under another name and is kept in step so
  # the two cannot drift into two different builds.
  screened = ps:
    let
      lib' = ps.liblogosdelivery.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ patches;
      });
    in
    ps // { liblogosdelivery = lib'; default = lib'; };
in
# Shaped like a flake input, exactly as its two neighbours are, so the three
# compose in the order flake.nix applies them.
{
  packages = builtins.mapAttrs (_system: screened) delivery.packages;
}
