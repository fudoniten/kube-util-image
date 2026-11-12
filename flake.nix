# Kube Util Terminal - Debug and utility image for  Kubernetes
#
# This flake builds an OCI container image that serves as a utility and debug
# image for Kubernetes. We can add whatever useful utilities we want to use to
# interact with Kubernetes pods.
#
# Build the container:
#   nix build .#container
#
# Push to registry:
#   nix run .#push

{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-26.05";
    utils.url = "github:numtide/flake-utils";

    fudo-nix-helpers = {
      url = "github:fudoniten/fudo-nix-helpers";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # nixpkgs-unstable retained: nothing uses it now, but keeping the input
    # documents the 2.0.0 experiment (v2.0.0 segfaults on `iso:` sources —
    # verified 2026-11-12 on Zootopia + Grand Budapest ISOs; reverted to
    # 1.18.4 + faketime wrapper, see makemkv-wrapped below).
    nixpkgs-unstable = {
      url = "github:NixOS/nixpkgs/nixos-unstable";
    };

    grout = {
      url = "github:fudoniten/grout";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      grout,
      utils,
      fudo-nix-helpers,
      ...
    }:
    utils.lib.eachDefaultSystem (
      system:
      let
        # allowUnfree: makemkv (needed for BR-DISK/ISO remuxing of the
        # /arr-data disc structures) is unfree-refused by default, which
        # broke `nix build`/`nix run .#push` outside of an --impure env.
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        helpers = fudo-nix-helpers.legacyPackages.${system};

        # nixpkgs-unstable is no longer referenced by any package (kept as an
        # input for the experiment note above); remove when convenient.
        # unstablePkgs = import nixpkgs-unstable {
        #   inherit system;
        #   config.allowUnfree = true;
        # };

        grout-cli = grout.packages."${system}".grout-cli;
        grout-bulk = grout.packages."${system}".grout-bulk;

        authorizedKeys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKrl31isnzPNup80KzUWX46rvXrhvUS22Q0dIIdcUEmj"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOY8hUVuyf2Mpqd6TPxDaK/dc4mFdznUCh399TnoJKzk"
        ];

        # Container registry settings
        containerConfig = {
          name = "kube-util";
          repo = "registry.kube.sea.fudo.link";
          tag = "latest";
        };

        # Additional packages to include in the image
        terminalPackages = with pkgs; [
          # Programming languages & runtimes
          clang
          gcc
          go
          nodejs
          python3
          ruby

          # Clojure
          babashka
          clj-kondo
          clojure
          leiningen
          temurin-bin # JDK required by Clojure tooling

          # Build tools
          cmake
          gnumake
          pkg-config

          # Version control extras (git is included by default)
          gh # GitHub CLI
          git-lfs

          # Kubernetes / Cloud ops
          fluxcd
          helm # kubernetes-helm
          k9s
          kubectl
          kubectx
          kustomize

          # Secrets & config management
          age
          sops

          # Network tools
          aria2 # multi-protocol download accelerator (pairs with yt-dlp)
          bind # dig, nslookup
          curl
          grpcurl
          httpie # human-friendly HTTP client
          iproute2 # ip, ss
          iputils # ping, ping6, arping, tracepath
          mtr # network diagnostic (traceroute + ping)
          net-tools # netstat, ifconfig, route
          netcat-openbsd
          nmap # nmap + ncat
          openssh
          rsync
          socat
          tcpdump
          traceroute
          wget

          # System monitoring & inspection
          btop
          htop
          lsof
          procps # ps, top, kill, free, vmstat, watch
          strace

          # Terminal multiplexer & editors
          tmux
          vim
          nano

          # Text processing & search
          bat # syntax-highlighting cat
          emacs-nox
          fd
          gawk
          gnused
          hexyl # hex viewer
          jless
          jq
          miller # mlr - CSV/JSON/TSV processing
          ripgrep
          yq-go

          # File & archive utilities
          bzip2
          diffutils
          file
          findutils
          gzip
          less
          patch
          pv # pipe viewer
          gnutar # was missing — extraction needed a Python fallback workaround
          tree
          unzip
          xz
          yt-dlp
          yt-dlg
          zip
          zstd

          # Media processing (yt-dlp DASH merges, probe/transcode debugging,
          # mirrors what the Grout server-side normalizer does)
          ffmpeg
          mediainfo
          exiftool # media metadata inspection

          # Optical-disc remuxing (2026-11-11 media audit: /data/complete holds
          # UHD Blu-ray disc structures — BDMV dirs with multi-segment MPLS
          # playlists — that ffmpeg/ffprobe cannot parse; PV probes them as
          # 1-second "BR-DISK" garbage. makemkvcon reads the playlists and
          # remuxes losslessly to MKV; mkvtoolnix covers general remux work).
          #
          # makemkvcon version-gate workaround: nixpkgs 26.05 ships 1.18.4
          # (2026-06-15), which refuses to run once older than ~60 days even
          # with a current beta key, and v2.0.0 segfaults on `iso:` sources.
          # faketime pins the clock inside 1.18.4's window; the beta key in
          # ~/.MakeMKV/settings.conf (arr-util home PVC) satisfies the license
          # check. Wrapper name shadows nothing (plain makemkv not installed).
          (pkgs.writeShellScriptBin "makemkvcon" ''
            exec env \
              LD_PRELOAD=${pkgs.libfaketime}/lib/faketime/libfaketime.so.1 \
              FAKETIME="2026-06-20" \
              ${pkgs.makemkv}/bin/makemkvcon "$@"
          '')
          mkvtoolnix

          # Shell utilities & linting
          bc # arbitrary-precision calculator
          parallel # GNU parallel
          shellcheck
          sqlite

          # Database clients (debugging Pseudovision/Jellyfin backing stores)
          postgresql # psql client

          # Web lookups
          whois

          # Additional utilities
          grout-cli
          grout-bulk # resumable bulk uploader that drives grout-cli
        ];

        # Environment variables for the container. SSL_CERT_FILE/NIX_SSL_CERT_FILE
        # point curl / python / other non-Nix tools at the CA bundle — without
        # them HTTPS calls fail with cert errors that look like "no internet"
        # (verified 2026-11-10: yt-dlp was unusable until SSL_CERT_FILE was set).
        containerEnv = {
          EDITOR = "emacs";
          TERM = "xterm-256color";
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        };

        # Additional sshd configuration (mirrors fudoniten/hermes-terminal).
        # UsePAM is already disabled in the helper's base sshd_config, so we
        # only need to opt into agent forwarding here.
        extraSshdConfig = ''
          # Allow agent forwarding for git operations
          AllowAgentForwarding yes
        '';

        # Persist the sshd host keys on a dedicated volume so the server's
        # identity stays stable across pod restarts. The helper generates host
        # keys in /etc/ssh only when they are missing, and nothing else in this
        # image writes to /etc/ssh (authorized_keys live in ~/.ssh, sshd_config
        # lives in the Nix store), so mounting a PVC here gives us a persistent,
        # host-key-only volume. See README.md for the Kubernetes manifests.
        sshHostKeyVolumes = [ "/etc/ssh" ];

        # --------------------------------------------------------------------
        # Container definitions
        # --------------------------------------------------------------------

        # The main terminal container
        containerImage = helpers.makeTerminalContainer {
          inherit (containerConfig) name repo tag;

          inherit authorizedKeys;

          # Match the arr stack's PUID/PGID (sonarr/radarr write as 1001:1000
          # per deployment-sonarr/radarr.yaml). Files written over SSH by the
          # agent must land as 1001:1000 or the arr apps can't chmod/delete
          # them (verified 2026-11-12: arr-util wrote as 1000:1000, Sonarr
          # couldn't take ownership of from-arr-downloads content).
          user = "fudo";
          uid = 1001;
          gid = 1000;
          packages = terminalPackages;
          env = containerEnv;

          # Git is enabled by default
          enableGit = true;

          # Enable nix if you want the agent to be able to install packages
          enableNix = true;

          # Additional sshd configuration if needed
          inherit extraSshdConfig;

          # Persist sshd host keys on a PVC mounted at /etc/ssh
          volumes = sshHostKeyVolumes;
        };

        # Deploy script for pushing to registry
        deployContainer = helpers.deployTerminalContainer {
          inherit (containerConfig) name repo;
          user = "fudo";
          uid = 1001;
          gid = 1000;
          inherit authorizedKeys;
          packages = terminalPackages;
          env = containerEnv;
          enableGit = true;
          enableNix = true;
          inherit extraSshdConfig;
          volumes = sshHostKeyVolumes;

          tags = [ "latest" ];
          verbose = true;
        };

        # Versioned deploy (example: for releases)
        deployContainerVersioned = helpers.deployTerminalContainer {
          inherit (containerConfig) name repo;
          user = "fudo";
          uid = 1001;
          gid = 1000;
          inherit authorizedKeys;
          packages = terminalPackages;
          env = containerEnv;
          enableGit = true;
          enableNix = true;
          inherit extraSshdConfig;
          volumes = sshHostKeyVolumes;

          tags = [
            "v1.0.0"
            "latest"
          ];
          verbose = true;
        };

      in
      {
        packages = {
          # The container image itself
          container = containerImage;
          default = containerImage;

          # Push scripts
          push = deployContainer;
          push-versioned = deployContainerVersioned;
        };

        # Development shell for working on this configuration
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            skopeo # For pushing containers
            dive # For inspecting container layers
          ];
        };
      }
    );
}
