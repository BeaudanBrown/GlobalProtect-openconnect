{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    naersk.url = "github:nix-community/naersk";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { self, nixpkgs, naersk, rust-overlay }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSupportedSystem = f:
        nixpkgs.lib.genAttrs supportedSystems (system:
          f rec {
            pkgs = import nixpkgs {
              inherit system;
              overlays = [ rust-overlay.overlays.default ];
              config.permittedInsecurePackages = [ "libsoup-2.74.3" ];
            };
            naersk' = pkgs.callPackage naersk {};
          });
    in {
      packages = forEachSupportedSystem ({ pkgs, naersk', ... }: {
        default = naersk'.buildPackage {
          src = ./.;

          # Rust toolchain and build tools
          nativeBuildInputs = with pkgs; [
            rust-bin.stable.latest.default
            pkg-config
            perl
            jq
          ];

          # C deps for tauri/wry and your crates
          buildInputs = with pkgs; [
            openconnect
            libsoup_2_4
            gtk3
            webkitgtk_4_1
            openssl
          ];

          overrideMain = { ... }: {
            # Replace hardcoded paths in your code
            postPatch = ''
              substituteInPlace crates/common/src/vpn_utils.rs \
                --replace-fail /etc/vpnc/vpnc-script ${pkgs.vpnc-scripts}/bin/vpnc-script

              substituteInPlace crates/gpapi/src/lib.rs \
                --replace-fail /usr/bin/gpclient $out/bin/gpclient \
                --replace-fail /usr/bin/gpservice $out/bin/gpservice \
                --replace-fail /usr/bin/gpgui-helper $out/bin/gpgui-helper \
                --replace-fail /usr/bin/gpgui $out/bin/gpgui \
                --replace-fail /usr/bin/gpauth $out/bin/gpauth
            '';

            # WORKAROUND: make the path tauri-build assumes actually exist
            # Tauri 2.4.x hardcodes <workspace>/target/... in its build script.
            # naersk’s first phase uses /build/dummy-src as the workspace root.
            # We symlink dummy-src/target -> source/target to satisfy that.
            preBuild = ''
              mkdir -p "$NIX_BUILD_TOP/dummy-src"
              ln -sfn "$PWD/target" "$NIX_BUILD_TOP/dummy-src/target"
            '';
          };
        };
      });
    };
}
