# Secrets bootstrap

How to set up sops-nix on a forge deployment so encrypted secrets in the repo decrypt cleanly into `/run/secrets/<name>` on the box at activation time.

This is the one-time operator setup. Daily editing of secrets is just `sops secrets.yaml`.

Reference: [sops-nix upstream README](https://github.com/Mic92/sops-nix). Read it for the deep stuff; this doc is the forge-specific walkthrough.

## What's wired already

- `flake.nix` pulls `sops-nix` and adds `sops-nix.nixosModules.sops` to every forge deployment.
- `modules/secrets.nix` sets sensible defaults:
  - `sops.defaultSopsFile` points at `deployments/<hostname>/secrets.yaml`
  - `sops.age.keyFile` points at `/var/lib/sops-nix/key.txt` on the box
- `.gitignore` excludes `secrets.yaml`, `*.age`, `key.txt`/`keys.txt`.

What you still do (once):

## 1. Generate an age key

On your laptop (or wherever you'll edit secrets):

```sh
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
```

The file has two parts:
- The private key (the long `AGE-SECRET-KEY-...` line). Never commit this.
- The public key (the `# public key: age1...` comment).

Grab the public key:

```sh
age-keygen -y ~/.config/sops/age/keys.txt
# -> age1abcdef...
```

## 2. Register your public key

Edit `deployments/agicash-team-forge/.sops.yaml` and replace the `age1placeholder...` line with your real public key:

```yaml
keys:
  - &operator_alice age1abcdef...    # the value you just printed

creation_rules:
  - path_regex: secrets\.yaml$
    key_groups:
      - age:
          - *operator_alice
```

Commit the `.sops.yaml` change. Public keys are not sensitive.

## 3. Encrypt the secrets file

Copy the example and edit it through sops (sops auto-encrypts on save):

```sh
cd deployments/agicash-team-forge
cp secrets.yaml.example secrets.yaml   # only to seed the shape, then delete and start fresh
sops secrets.yaml
```

In the editor sops opens, write plaintext YAML:

```yaml
team-bot-token: your-discord-bot-token-here
```

Save and quit. The on-disk file is now encrypted — safe to commit. (The repo gitignores `secrets.yaml` by default; if your team prefers committing the encrypted file, remove that entry from `.gitignore`. Encrypted-in-repo is the canonical sops-nix workflow.)

## 4. Copy your private key to the box (one time)

The box needs the age private key once, in a known location:

```sh
ssh root@<box-ip> "install -d -m 0700 /var/lib/sops-nix"
scp ~/.config/sops/age/keys.txt root@<box-ip>:/var/lib/sops-nix/key.txt
ssh root@<box-ip> "chmod 0400 /var/lib/sops-nix/key.txt"
```

(`key.txt` — singular — matches the upstream sops-nix default and the value in `modules/secrets.nix`.)

This is the only manual step that touches the box outside `deploy-rs`. Everything else flows through declarative deploy from now on.

## 5. Declare secrets in `configuration.nix`

Edit `deployments/agicash-team-forge/configuration.nix` and uncomment the block under `--- Secrets ---`:

```nix
sops.secrets."team-bot-token" = {
  owner = "gudnuf";
};
services.forge.discord.bots.team = {
  tokenFile = config.sops.secrets."team-bot-token".path;
};
```

## 6. Deploy

```sh
deploy .#agicash-team-forge
```

sops-nix decrypts `team-bot-token` into `/run/secrets/team-bot-token` at activation, owned by `gudnuf`, mode `0400`. The Discord bot manifest reads the path. The token never lands on disk in plaintext outside `/run` (a tmpfs).

## Adding a new secret

1. `cd deployments/agicash-team-forge && sops secrets.yaml`
2. Add the new key in the editor; save.
3. Add `sops.secrets."<name>" = { owner = "..."; };` in `configuration.nix`.
4. Wire the path where it's needed (e.g. another `tokenFile`).
5. Redeploy.

## Adding a new operator

1. New operator runs `age-keygen` and shares their public key.
2. Add a second `&operator_bob age1...` entry under `keys:` in `.sops.yaml`.
3. Add the alias under the rule's `key_groups.age` list.
4. Re-encrypt the existing file to the new recipient set:
   ```sh
   sops updatekeys secrets.yaml
   ```
5. Commit `.sops.yaml` and the updated `secrets.yaml`. New operator can now decrypt.

(See the [sops-nix README](https://github.com/Mic92/sops-nix) for multi-host recipients — encrypting to the box's SSH host key so the box decrypts without a copied private key. That's a later refinement; the single-key flow above is enough for the demo.)
