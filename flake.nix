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

    grout = {
      url = "github:fudoniten/grout";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, grout, utils, fudo-nix-helpers, ... }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        helpers = fudo-nix-helpers.legacyPackages.${system};

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
          tree
          unzip
          xz
          zip
          zstd

          # Shell utilities & linting
          parallel # GNU parallel
          shellcheck
          sqlite

          # Additional utilities
          grout-cli
          grout-bulk # resumable bulk uploader that drives grout-cli
        ];

        # Environment variables for the container
        containerEnv = {
          EDITOR = "emacs";
          TERM = "xterm-256color";
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

          user = "fudo";
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
          inherit authorizedKeys;
          packages = terminalPackages;
          env = containerEnv;
          enableGit = true;
          enableNix = true;
          inherit extraSshdConfig;
          volumes = sshHostKeyVolumes;

          tags = [ "v1.0.0" "latest" ];
          verbose = true;
        };

      in {
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
      });
}
