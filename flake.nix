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
            # Derive GUI download info from workspace version and system
            cargoToml = builtins.fromTOML (builtins.readFile ./Cargo.toml);
            version = cargoToml.workspace.package.version;
            archSuffix = if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then "x86_64" else "aarch64";
            releaseTag = "v${version}";
            guiUrl = "https://github.com/yuezk/GlobalProtect-openconnect/releases/download/${releaseTag}/gpgui_${archSuffix}.bin.tar.xz";
            guiSha256 = if archSuffix == "x86_64"
              then "sha256-a2anev4k8VJEezbcY8paBf/6NQYyCSYOUJ2qNsGIULM="
              else "sha256-OzeCY9YSE4bZLkojSROIE2Yd5FJrw/ia77X6Wmu0q14=";
            gpguiTarball = pkgs.fetchurl { url = guiUrl; sha256 = guiSha256; };
          });
    in {
      packages = forEachSupportedSystem ({ pkgs, naersk', gpguiTarball, ... }: {
        default = naersk'.buildPackage {
          src = ./.;

          # Rust toolchain and build tools
          nativeBuildInputs = with pkgs; [
            rust-bin.stable.latest.default
            pkg-config
            perl
            jq
            xz
            autoPatchelfHook
            patchelf
          ];

          # C deps for tauri/wry and your crates
          buildInputs = with pkgs; [
            openconnect
            libsoup_2_4
            gtk3
            webkitgtk_4_1
            openssl
            # runtime libs for prebuilt gpgui (GTK/WebKit/Tauri)
            glib
            pango
            cairo
            gdk-pixbuf
            atk
            harfbuzz
            libepoxy
            libglvnd
            freetype
            fontconfig
            zlib
            dbus
            alsa-lib
            nss
            nspr
            wayland
            libxkbcommon
            libdrm
            libgbm
            xorg.libX11
            xorg.libXcursor
            xorg.libXrandr
            xorg.libXext
            xorg.libXi
            xorg.libXdamage
            xorg.libXcomposite
            xorg.libXrender
            xorg.libXfixes
            xorg.libxcb
            stdenv.cc.cc
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

            # Bundle the prebuilt gpgui binary into $out/bin so gpservice can launch it
            # This avoids runtime self-updating (which is incompatible with Nix store)
            postInstall = ''
              echo "Installing bundled gpgui from ${gpguiTarball}"
              mkdir -p "$out/bin"
              workdir=$(mktemp -d)
              tar -xJf ${gpguiTarball} -C "$workdir"
              # find extracted gpgui binary and install it
              f=$(find "$workdir" -type f -name gpgui | head -n1)
              if [ -z "$f" ]; then
                echo "gpgui binary not found in archive" >&2
                exit 1
              fi
              install -Dm755 "$f" "$out/bin/gpgui"
            '';
          };
        };
      });
    };
}
