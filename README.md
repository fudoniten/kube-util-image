# kube-util

A debug and utility container image for Kubernetes. It bundles a broad set of
CLI tools (kubectl, k9s, flux, helm, network/diagnostic tooling, editors,
language runtimes, etc.) behind an SSH server, so you can drop it into a cluster
and get an interactive, fully-equipped shell.

The image is built with [`fudo-nix-helpers`][helpers]' `makeTerminalContainer`,
the same helper used by [`hermes-terminal`][hermes]. Like that image it runs
`tini` as init with `sshd` as the main service (no systemd), which makes it a
good fit for a standard Kubernetes `Deployment`.

[helpers]: https://github.com/fudoniten/fudo-nix-helpers
[hermes]: https://github.com/fudoniten/hermes-terminal

## Build & push

```sh
# Build the OCI image
nix build .#container

# Push :latest to the registry
nix run .#push

# Push a versioned tag (+ latest)
nix run .#push-versioned
```

## SSH access

`sshd` listens on port 22. Authentication is public-key only
(`PasswordAuthentication no`); the authorized keys are baked in via the
`authorizedKeys` list in `flake.nix`. Agent forwarding is enabled so you can use
your local SSH agent for git operations from inside the container.

## Persistent host keys (PVC)

By default the helper generates fresh sshd **host keys** on every container
start. In a `Deployment` that means each new pod presents a different host key,
and clients that have pinned the old key get the noisy
`REMOTE HOST IDENTIFICATION HAS CHANGED` warning.

To keep a stable server identity, this image declares `/etc/ssh` as a volume and
the init script only generates host keys when they are missing. Mount a
`PersistentVolumeClaim` at `/etc/ssh` and the keys are created once, then reused
for the life of the PVC. Nothing else in the image writes to `/etc/ssh`
(`authorized_keys` live in `~/.ssh`, `sshd_config` lives in the Nix store), so
the volume ends up holding host keys only.

### Example manifests

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: kube-util-ssh-host-keys
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 100Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-util
spec:
  replicas: 1
  selector:
    matchLabels: { app: kube-util }
  template:
    metadata:
      labels: { app: kube-util }
    spec:
      containers:
        - name: kube-util
          image: registry.kube.sea.fudo.link/kube-util:latest
          ports:
            - containerPort: 22
          volumeMounts:
            - name: ssh-host-keys
              mountPath: /etc/ssh
      volumes:
        - name: ssh-host-keys
          persistentVolumeClaim:
            claimName: kube-util-ssh-host-keys
```

> **Note:** because the PVC is `ReadWriteOnce`, keep this to a single replica.
> If you need multiple replicas sharing one identity, use a `ReadWriteMany`
> volume or provision the host keys as a `Secret` mounted at `/etc/ssh` instead.
