# checks.<system>.ingress-lint (spec 05 §7.4, AT-L1–L5): render the tunnel
# config through the module exactly as a host would, then run
# infra/qa/cloudflared/lint.sh over it with this flake's own cloudflared.
{
  self,
  nixpkgs,
  pkgs,
}:
let
  t = import ./lib.nix { inherit self nixpkgs; };
  # Only the rendered string is taken from the x86_64-linux evaluation; it
  # carries no store path, so the same check runs on every system.
  rendered =
    (t.evalSystem {
      services.hasala.tunnel = {
        enable = true;
        id = t.testTunnelId;
        credentialsFile = "/dev/null";
      };
    }).config.services.hasala.tunnel.renderedConfig;
in
pkgs.runCommand "hasala-ingress-lint"
  {
    nativeBuildInputs = [
      pkgs.yq-go
      self.packages.${pkgs.stdenv.hostPlatform.system}.cloudflared
    ];
    rendered = pkgs.writeText "cloudflared-hasala.yml" rendered;
  }
  ''
    export HOME="$TMPDIR"
    bash ${../../cloudflared/lint.sh} all "$rendered" ${../../cloudflared}
    touch "$out"
  ''
