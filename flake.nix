{
  description = "Hasala: Go server, conformance fixtures and the TypeScript reference client";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    # Used for ONE package, Go (see goFor). Everything else comes from 26.05.
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
    }:
    let
      inherit (nixpkgs) lib;

      # The QA host and the Apple-silicon Mac share one devShell.
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});

      # One Go for everything: the devShell, buildGoModule and gofmt. It must
      # stay at or above the `toolchain` line in server/go.mod, which
      # scripts/check.sh enforces.
      #
      # From nixos-unstable because 26.05 stops at 1.26.8: that release is past
      # GO-2026-6090 (the TLS KeyUpdate DoS in the 2026-08-14 ledgerd security
      # review, which is not published; fixed in 1.26.6) but still
      # carries ten reachable net/http, crypto/tls and mime/multipart advisories
      # fixed in 1.26.9 / 1.27.2, and no nixpkgs branch packages 1.26.9.
      goFor = system: nixpkgs-unstable.legacyPackages.${system}.go_1_27;

      # 26.05's buildGoModule, driven by that Go. The server is built with it,
      # and so are the Go tools below: 26.05 compiles them with Go 1.26, and a
      # tool built with an older go/types cannot load 1.27's standard library
      # (govulncheck fails outright on it). They are still 26.05's packages,
      # compiled locally rather than fetched from the cache.
      buildGoModuleFor = system: pkgs: pkgs.buildGoModule.override { go = goFor system; };
      goToolsFor =
        system: pkgs:
        let
          buildGoModule = buildGoModuleFor system pkgs;
        in
        [
          (pkgs.gopls.override { buildGoLatestModule = buildGoModule; })
          (pkgs.govulncheck.override { buildGoLatestModule = buildGoModule; })
          # 26.05's 2.12.2 cannot read Go 1.27 export data even when built with
          # 1.27 ("export data version 5 is greater than maximum supported"), so
          # its definition is pointed at 2.14.0, the release nixos-unstable
          # builds with Go 1.27. Hashes as pinned there.
          ((pkgs.golangci-lint.override { buildGo126Module = buildGoModule; }).overrideAttrs {
            version = "2.14.0";
            src = pkgs.fetchFromGitHub {
              owner = "golangci";
              repo = "golangci-lint";
              tag = "v2.14.0";
              hash = "sha256-HATA7JKHwEouM+8jYZbQrkX7p4gut4IpyTvcBexu/4o=";
            };
            vendorHash = "sha256-ekP/zDhYMpMG+tYAyYHNfLOCt/JkxrXUw1jHUEfsM8k=";
          })
        ];

      # XcodeGen 2.46.0 exactly (spec 06 §1; ios/scripts/generate-project.sh says
      # why): 26.05 ships 2.44.1, whose projects build an app with no asset
      # catalog and no privacy manifest. nixpkgs builds XcodeGen from source with
      # its Swift 5.10 toolchain, and 2.46.0 needs XcodeProj 9.14.0, whose
      # manifest requires swift-tools-version 6.0; so this is the release's own macOS
      # binary (yonaskolb/XcodeGen, asset xcodegen.zip, upstream sha256
      # 4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806),
      # pinned by hash. Darwin only; the ios CI job runs it with `nix build`.
      xcodegenFor =
        pkgs:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "xcodegen";
          version = "2.46.0";
          src = pkgs.fetchzip {
            url = "https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip";
            hash = "sha256-7NjCsInBjkOL1RqWSaWKGDJxp/gn71rmhTWG2ErHDqA=";
          };
          dontConfigure = true;
          dontBuild = true;
          dontFixup = true;
          installPhase = ''
            mkdir -p $out
            cp -R bin share $out/
          '';
          meta = {
            mainProgram = "xcodegen";
            platforms = lib.platforms.darwin;
            sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
          };
        };

      treefmtFor =
        system: pkgs:
        pkgs.treefmt.withConfig {
          runtimeInputs = [
            pkgs.nixfmt
            (goFor system)
          ];
          settings = {
            tree-root-file = "flake.nix";
            on-unmatched = "debug";
            formatter.nixfmt = {
              command = "nixfmt";
              includes = [ "*.nix" ];
            };
            formatter.gofmt = {
              command = "gofmt";
              options = [ "-w" ];
              includes = [ "*.go" ];
              # Byte-frozen v1 reference code (see its README): a formatter
              # must never be the thing that edits it.
              excludes = [ "server/oracle/v1ref/*" ];
            };
          };
        };
    in
    {
      formatter = forAllSystems treefmtFor;

      packages = forAllSystems (
        system: pkgs:
        {
          # Spec 02 §3.1 names it packages.<system>.hasalad; `server` is kept as
          # an alias for anything that still says .#server.
          hasalad = buildGoModuleFor system pkgs {
            pname = "hasalad";
            # Static on purpose: the go-modules fixed-output derivation is named
            # after it, so a per-commit version would re-fetch every module.
            version = "0-unstable";
            src = ./server;
            vendorHash = "sha256-EJnxPJhAvGDTQuroF55AD0KG6RSEZ3oPxh3QOXnc2MA=";
            subPackages = [ "cmd/hasalad" ];
            # `hasalad version` prints the commit (05 §4.2). ldflags do not reach
            # the go-modules derivation, so this does not re-fetch modules.
            ldflags = [ "-X main.version=${self.shortRev or self.dirtyShortRev or "dirty"}" ];
            env.CGO_ENABLED = "0";
            # Not stripped (no `-s -w`), on purpose: `govulncheck -mode=binary`
            # needs the symbol table to tell which packages are linked in. On a
            # stripped binary it falls back to whole-module matches and reports
            # x/crypto's unfixable, unused openpgp advisory (GO-2026-5932).
            # The test suite needs a Postgres cluster, bun and the conformance
            # fixtures outside server/; scripts/check.sh is the gate that runs it.
            doCheck = false;
            meta.mainProgram = "hasalad";
          };
          # 05 §4.2: the same PostgreSQL the devShell's test clusters use, so CI
          # and the QA host run one major and minor.
          postgresql = pkgs.postgresql_17;
          # 05 §4.2, R-09: nixos-26.05's cloudflared source and version, compiled
          # with the Go 1.27 above. It is the only internet-facing process on
          # the QA host, and 26.05's Go has reachable standard-library advisories.
          # The ingress lint (infra/qa/cloudflared/lint.sh) and the host run this
          # same binary.
          #
          # Its Linux test suite (nixpkgs skips it on darwin) runs here too, except
          # seven tests in connection/http2_test.go. Each one uses a zero
          # golang.org/x/net/http2.Transport{} as the test's stand-in for the edge,
          # and with Go 1.27 x/net v0.55's NewClientConn dereferences that
          # transport's nil net/http Transport and panics. That is test-only:
          # cloudflared serves HTTP/2 to the edge (http2.Server) and never dials
          # with a bare http2.Transport, and the package's other tests still run.
          cloudflared =
            (pkgs.cloudflared.override { buildGoModule = buildGoModuleFor system pkgs; }).overrideAttrs
              (old: {
                checkFlags = (old.checkFlags or [ ]) ++ [
                  "-skip=^(TestFailRegistration|TestGracefulShutdownHTTP2|TestHTTP2ConfigurationSet|TestNoWriteAfterServeHTTPReturns|TestServeControlStream|TestServeHTTP|TestServeTCP_RateLimited)$"
                ];
              });
          server = self.packages.${system}.hasalad;
          default = self.packages.${system}.hasalad;
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
          xcodegen = xcodegenFor pkgs;
        }
      );

      # services.hasala, the QA backend (spec 05 §5): Hasala's own PostgreSQL,
      # `hasalad serve` and `hasalad console` on loopback, the tunnel, backups.
      nixosModules.hasala = import ./infra/qa/nix/module.nix self;
      nixosModules.default = self.nixosModules.hasala;

      checks = forAllSystems (
        system: pkgs:
        {
          hasalad = self.packages.${system}.hasalad;
          # Spec 05 §7.4: the module's rendered tunnel config against the golden
          # file (G1), the structural rules L1–L9, the routing table, and every
          # negative fixture rejected.
          ingress-lint = import ./infra/qa/nix/tests/ingress-lint.nix { inherit self nixpkgs pkgs; };
          formatting =
            pkgs.runCommand "hasala-formatting" { nativeBuildInputs = [ (treefmtFor system pkgs) ]; }
              ''
                cp -r ${self} src
                chmod -R u+w src
                cd src
                treefmt --ci
                touch $out
              '';
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          # Spec 05 §14 AT-E*: the module's assertions fire on every misuse, and
          # the units carry exactly the environment and credentials the specs fix.
          module-eval = import ./infra/qa/nix/tests/eval.nix { inherit self nixpkgs pkgs; };
          # Spec 05 §14 AT-V*: boots the module in a VM. Needs KVM; CI runs it in
          # its own job (nixos-vm), and the gate job builds every other check.
          qa-vm = pkgs.testers.runNixOSTest (import ./infra/qa/nix/tests/vm.nix self);
        }
      );

      devShells = forAllSystems (
        system: pkgs: {
          # NoCC: on darwin the cc-wrapper stdenv exports SDKROOT/DEVELOPER_DIR
          # pointing into the Nix store, which breaks Xcode's own toolchain.
          # Nothing here needs cgo, so there is no C compiler on Linux either.
          default = pkgs.mkShellNoCC {
            packages = [
              (goFor system)
            ]
            ++ goToolsFor system pkgs
            ++ [
              pkgs.postgresql_17 # initdb/pg_ctl/postgres for internal/pgtest
              pkgs.bun
              pkgs.sops
              pkgs.gh
              pkgs.nixfmt
              (treefmtFor system pkgs)
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
              (xcodegenFor pkgs)
              pkgs.swiftlint
            ];
            env = {
              # Never let `go` fetch a different toolchain than the pinned one.
              GOTOOLCHAIN = "local";
              CGO_ENABLED = "0";
            };
          };
        }
      );
    };
}
