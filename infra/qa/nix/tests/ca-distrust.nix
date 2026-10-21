{
  self,
  nixpkgs,
  pkgs,
}:
let
  inherit (nixpkgs) lib;
  t = import ./lib.nix { inherit self nixpkgs; };
  distrusted = (t.evalSystem { }).config.security.pki.caCertificateBlacklist;
  stock = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  overridden = pkgs.cacert.override { blacklist = distrusted; };
  filtered = "${overridden}/etc/ssl/certs/ca-bundle.crt";
  compat = "${overridden}/etc/ssl/certs/ca-no-trust-rules-bundle.crt";
  needed = [
    "GTS Root R4"
    "DigiCert Global Root G2"
    "DigiCert Global Root G3"
    "USERTrust RSA Certification Authority"
    "ISRG Root X1"
    "ISRG Root X2"
  ];
in
assert distrusted != [ ];
pkgs.runCommand "hasala-ca-distrust" { } ''
  first() { awk -v n="$1" 'p { print; exit } $0 == n { p = 1 }' "$2"; }
  servers() { [ "$(first "$1" "$2")" = "-----BEGIN CERTIFICATE-----" ]; }
  fail=0
  ${lib.concatMapStrings (n: ''
    grep -qxF ${lib.escapeShellArg n} ${stock} || { echo "the stock bundle has no ${n}: the label is wrong"; fail=1; }
    if servers ${lib.escapeShellArg n} ${filtered}; then echo "the bundle still trusts ${n} for servers"; fail=1; fi
    if servers ${lib.escapeShellArg n} ${compat}; then echo "the compatible bundle still trusts ${n}"; fail=1; fi
  '') distrusted}
  ${lib.concatMapStrings (n: ''
    servers ${lib.escapeShellArg n} ${filtered} || { echo "the bundle no longer trusts ${n}, which a host the QA host calls chains to"; fail=1; }
  '') needed}
  [ "$fail" = 0 ] || exit 1
  echo "distrusted: ${lib.concatStringsSep ", " distrusted}" > $out
''
