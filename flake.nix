{
  description = "Logos Delivery Module";

  # Pull pre-built artifacts (liblogosdelivery, librln, …) from the self-hosted
  # Logos Attic cache. Read-only and public; see infra-ci#263.
  nixConfig = {
    extra-substituters = [ "https://cache.nix.logos.co/public" ];
    extra-trusted-public-keys = [ "public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=" ];
  };

  inputs = {
    # A rev on the logos-fleet fork, not logos-co: the mobile Bare outputs this
    # flake exposes -- and the `externalLibInputs.<name>.mobilePackages` contract
    # the two entries below answer -- are a property of the BUILDER, and only
    # that line has them yet. A builder without them simply publishes no mobile
    # keys in `packages`, so pointing this back at logos-co degrades the flake
    # rather than breaking it.
    #
    # ...and since metadata.json declares `"platform": true` (ADR 0009), the rev
    # also has to be one that KNOWS that key. An older builder's near-miss guard
    # for `platforms` overlays THROWS on it -- "rename it to `platforms`
    # (plural)", which names the wrong fix for a key spelled correctly -- and a
    # throw at parse time takes every output of this flake with it. The
    # workspace's `follows` hid that for as long as nobody evaluated this repo on
    # its OWN lock; `ws test logos-delivery-module` and a bare `nix build` here
    # both do. logos-workspace#214.
    logos-module-builder.url = "github:logos-fleet/logos-module-builder/738f1a6ef5a6f755f8433297ac0d2ef54bba8d2f";
    nix-bundle-lgx.url = "github:logos-co/nix-bundle-lgx";
    logos-delivery.url = "git+https://github.com/logos-messaging/logos-delivery?submodules=1";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    let
      # The mobile half of both externalLibInputs below. nim-delivery's and
      # zerokit's own flakes answer for desktop systems only, and
      # logos-module-builder cannot recompile an external library for a phone
      # either -- it comes from somewhere else entirely. So this flake
      # cross-builds them itself, from the SAME locked input, and the builder
      # stages the results over the build-platform images its `generate` step
      # left in lib/. See nix/mobile-libs.nix.
      mobileLibs = import ./nix/mobile-libs.nix {
        inherit (logos-module-builder.inputs.nixpkgs) lib;
        inherit (logos-module-builder.inputs) rust-overlay;
        inherit (logos-module-builder.lib.common) mkPkgsWith;
        deliverySrc = inputs.logos-delivery;
        # Which cargo triple each mobile pseudo-system is, read off the builder
        # rather than restated: a list copied into this flake would go stale
        # silently. `or { }` because a builder predating the mobile targets has
        # no such attribute -- then this flake simply has no mobile keys.
        rustTargets = logos-module-builder.lib.common.mobileRustTargets or { };
      };

      # `logos-delivery` with zerokit's pmtree tests made hermetic: upstream
      # they open a sled database at the absolute path /tmp/pmtree-test-path,
      # which on a shared macOS builder poisons /tmp for every later build and
      # so for every mobile artifact. See nix/hermetic-delivery.nix and
      # logos-workspace#126. Shaped like the flake input it stands in for.
      hermeticDelivery = import ./nix/hermetic-delivery.nix {
        delivery = inputs.logos-delivery;
      };

      # ...and then built without Nim's own signal handler, which a library
      # loaded into someone else's process has no business owning and which
      # could never report a fault anyway. See nix/no-nim-signal-handler.nix
      # and logos-workspace#150.
      #
      # Hermetic FIRST: it calls `.override`, which re-evaluates the package
      # from its arguments and would drop an `overrideAttrs` applied before it.
      deliveryPackages = import ./nix/no-nim-signal-handler.nix {
        delivery = hermeticDelivery;
      };

      module = logos-module-builder.lib.mkLogosModule {
        src = ./.;
        configFile = ./metadata.json;
        flakeInputs = inputs;
        externalLibInputs = {
          logosdelivery = {
            input = deliveryPackages;
            packages.default = "liblogosdelivery";
            # { system, pkgs, buildSystem } -> a derivation laid out lib/ +
            # include/. A FUNCTION rather than an attrset keyed by system: `pkgs`
            # is the target package set the Bare build is already using, and for
            # Android its BUILD platform is a parameter, so an attrset would have
            # to pick one and a Mac cannot realise an x86_64-linux one.
            mobilePackages = args: (mobileLibs args).logosdelivery;
          };
          # Bundle librln.dylib alongside liblogosdelivery.dylib so the transitive
          # dep resolves at runtime (and during logos-cpp-generator dlopen).
          # Sourced from logos-delivery (not zerokit directly) so we bundle the
          # exact, cargoHash-corrected librln that liblogosdelivery links — zerokit
          # v2.0.2's own rln package has a stale committed cargoHash.
          rln = {
            input = deliveryPackages;
            packages.default = "rln";
            # The target's librln.a. On a phone it is also MERGED into
            # liblogosdelivery.a -- CMakeLists names only `logosdelivery` in
            # EXTERNAL_LIBS, and a static link has no load time at which a
            # transitive dependency could be resolved. This entry still answers,
            # because "rln, built for aarch64-ios" is a real thing and the
            # builder refuses an entry with no build for the target by name.
            mobilePackages = args: (mobileLibs args).rln;
          };
        };
        tests = {
          dir = ./tests;
          mockCLibs = [ "logosdelivery" ];
          # liblogosdelivery.dylib has a Cargo-baked absolute path to librln.dylib.
          # Rewrite it to @rpath/librln.dylib so the dynamic linker can find it via
          # the lib/ RPATH set on the integration test binary.
          # TODO: remove once logos-module-builder mkLogosModuleTests.nix handles
          # transitive dylib dependency rewriting in its preConfigure (similar to
          # the postInstall rewrite done for the main module build).
          preConfigure = ''
            if [ -f lib/liblogosdelivery.dylib ]; then
              OLD_RLN=$(otool -L lib/liblogosdelivery.dylib | awk '/librln/{print $1}')
              if [ -n "$OLD_RLN" ]; then
                install_name_tool -change "$OLD_RLN" "@rpath/librln.dylib" lib/liblogosdelivery.dylib
              fi
            fi
          '';
        };
        # Bundle runtime libraries alongside the plugin.
        postInstall = ''
          # liblogosdelivery.dylib has a sandbox-baked absolute path for librln.dylib
          # (Cargo bakes the build-time path as the install name). Rewrite it to
          # @rpath/librln.dylib so the dynamic linker finds it via @loader_path.
          if [ -f "$out/lib/liblogosdelivery.dylib" ]; then
            OLD_RLN=$(otool -L "$out/lib/liblogosdelivery.dylib" | awk '/librln/{print $1}')
            if [ -n "$OLD_RLN" ]; then
              echo "Fixing librln rpath in liblogosdelivery.dylib: $OLD_RLN -> @rpath/librln.dylib"
              install_name_tool -change "$OLD_RLN" "@rpath/librln.dylib" \
                "$out/lib/liblogosdelivery.dylib"
            fi

            # Add @loader_path/. as an rpath so that Nim's runtime dlopen("libpq.dylib")
            # finds the bundled libpq in the same directory as liblogosdelivery.dylib.
            if ! otool -l "$out/lib/liblogosdelivery.dylib" | awk '
              $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
              in_rpath && $1 == "path" { print $2; in_rpath = 0 }
            ' | grep -Fxq "@loader_path/."; then
              install_name_tool -add_rpath "@loader_path/." \
                "$out/lib/liblogosdelivery.dylib"
            fi
          fi

          # Use pkg-config to locate the exact libpq from the build environment
          LIBPQ_LIBDIR=$(pkg-config --variable=libdir libpq 2>/dev/null || true)
          if [ -n "$LIBPQ_LIBDIR" ] && [ -d "$LIBPQ_LIBDIR" ]; then
            for f in "$LIBPQ_LIBDIR"/libpq.*; do
              [ -f "$f" ] && cp -L "$f" $out/lib/ 2>/dev/null || true
            done
          fi

          # libpq is loaded at runtime via dlopen/dlsym (not a linked dependency),
          # so install_name_tool has no effect on macOS — otool -L won't show libpq.
          # On Linux, dlopen with a bare name searches the calling library's DT_RUNPATH,
          # so setting $ORIGIN makes libpq.so discoverable from the same directory.
          if [ -f "$out/lib/liblogosdelivery.so" ]; then
            echo "Fixing rpath in liblogosdelivery.so: adding \$ORIGIN for dlopen libpq resolution"
            chmod u+w "$out/lib/liblogosdelivery.so"
            patchelf --set-rpath '$ORIGIN' "$out/lib/liblogosdelivery.so"
          fi
        '';
      };

      # The systems the signal-handler check can be BUILT AND RUN on.
      # `module.checks` also carries x86_64-windows, which is a cross target
      # with no runnable nixpkgs of its own -- the artifact for it is asserted
      # on wherever it is cross-built, not here.
      nativeSystems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      nixpkgs = logos-module-builder.inputs.nixpkgs;
    in
    module // {
      # `//` on checks rather than a replacement: the builder's own `unit-tests`
      # is this module's test suite and stays.
      checks = module.checks // nixpkgs.lib.genAttrs nativeSystems (system:
        (module.checks.${system} or { }) // {
          no-nim-signal-handler = import ./nix/no-nim-signal-handler-test.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            liblogosdelivery = deliveryPackages.packages.${system}.liblogosdelivery;
          };
        });
    };
}
