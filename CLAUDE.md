# CLAUDE.md

This is a NixOS module flake that bootstraps a Shoko Server instance through its HTTP API. It completes the first-run wizard, creates the admin user, sets the AniDB login and applies extra settings. It needs no manual WebUI steps and is idempotent across activations. `README.md` has the user-facing docs.

## Status / what needs doing on this machine

The module was written and tested on macOS. There, the rendered bootstrap script was run by hand against a real **Shoko 5.3.3** (the version in nixpkgs) on `localhost:8111`. These paths passed:
- fresh install;
- re-run against an already-initialized instance;
- running while Shoko was still booting;
- wrong admin password, which gives a clear error.

What has **not** been done yet, and is the reason you're on Linux:
1. **Run the NixOS VM test.** Use `nix build .#checks.x86_64-linux.vm -L`, or `nix flake check -L`.
2. **Test the real systemd unit against a running Shoko.** Covered in "Testing against a running instance" below.
3. Fix whatever breaks and keep `README.md` in sync.

## Layout

- `flake.nix`: inputs are `nixpkgs` (unstable) and `nixflix` (`github:kiriwalawren/nixflix`, which follows nixpkgs). Outputs:
  - `nixosModules.default` (alias `shoko-declarative`);
  - `checks.<linux>.vm`;
  - `formatter` (`nixfmt-tree`).
- `module.nix`: the `services.shoko.bootstrap.*` options and `systemd.services.shoko-bootstrap`, a oneshot with `RemainAfterExit`, `after`/`requires` on `shoko.service`, and `RuntimeDirectory=shoko-bootstrap`.
- `tests/vm.nix`: a `pkgs.testers.runNixOSTest` test. It runs a fresh setup, re-runs the bootstrap, restarts Shoko, checks key-file mode and group, and asserts that no secrets appear in the unit or script.

## Hard constraints

- **Do not modify nixflix.** It's an upstream flake input. Its helpers are imported by path, because nixflix's flake `lib` output doesn't export them:
  - `import "${nixflix}/lib/mk-secure-curl.nix" { inherit lib pkgs; }`
  - `import "${nixflix}/lib/secrets" { inherit lib; }`, which provides `mkSecretOption`, `mkJqSecretArgs`, `mkNestedJqSecretArgs`, `stripSecretRefs` and `isSecretRef`.
- **Make all HTTP calls through `mkSecureCurl`**, which is the user's explicit requirement. Don't call `curl` directly in the module.
- **Keep secrets out of the Nix store and out of argv.** Secrets are `{ _secret = "/path"; }` refs and are read at runtime with `jq --rawfile`. Payloads travel as shell variables, which `mkSecureCurl` writes to a mktemp file through an unquoted heredoc and sends with `--data-binary @file`. The API token is read with curl's `--variable apiKey@file`.

## mkSecureCurl quirks you'll trip over

- Signature: `mkSecureCurl apiKeyOrNull { url, method ? "GET", headers ? {}, data ? null, extraArgs ? "", apiKeyHeader ? "X-Api-Key", silent ? true }`. It returns a **shell snippet string**.
- When `data != null`, the snippet sets `trap … EXIT` to delete its temp file. That would clobber traps in the caller, so every helper (`noauth_get`, `noauth_send`, `auth_send`) is a **subshell function** `f() ( … )`.
- Shoko's auth header is `apikey`, so use `apiKeyHeader = "apikey"`. The token path must be a literal, because it gets `escapeShellArg`'d and `$RUNTIME_DIRECTORY` won't expand. That's why `tokenFile = "/run/shoko-bootstrap/token"` is hardcoded.
- `method`, `url` and `data` may contain shell variables (`"$1"`, `"$API/$2"`, `"$3"`), and they are expanded at runtime.
- Helpers write the body to `$RESP` and print the HTTP code (`-o "$RESP" -w '%{http_code}'`). Callers add `|| true` because `set -e` plus a curl connection error would otherwise abort the script.

## Shoko API facts

These were checked in the ShokoServer source. The upstream repos are github.com/ShokoAnime/ShokoServer and github.com/ShokoAnime/Shoko-WebUI.

- `GET /api/v3/Init/Status` returns `{"State": "Waiting"|"Starting"|"Started"|"Failed", "StartupMessage": …}`. `Waiting` means setup mode.
- **In setup mode every request is authenticated as the `init` user**, with no key needed (`CustomAuthHandler`). The setup endpoints are:
  - `POST /api/v3/Init/DefaultUser` `{Username, Password}`;
  - `PATCH /api/v3/Settings`, a JSON Patch;
  - `POST /api/v3/Init/CompleteSetup`. That endpoint is 6.x only; the 5.x equivalent is `GET /api/v3/Init/StartServer`, and the script falls back to it on 404/405.
- The admin user is created at first startup from the `DefaultUser` values.
- **During setup only `AniDb.Username` and `AniDb.Password` are patched.** In 5.3.3, `SettingsProvider.SaveSettings` resets titles through repositories when `Language.*TitleLanguageOrder` changes, and that throws a NullReferenceException (HTTP 500) before the database is up. All other settings are patched **after** `Started`, authenticated with a token.
- Sign-in is `POST /api/auth` `{user, pass, device}` → `{apikey}`, which works on 5.x and 6.x. The newer `POST /api/v3/Auth/SignIn` exists only in 6.x. Don't switch to it while nixpkgs ships 5.x.
- **API keys:** the client picks a name (`device`) and Shoko generates a GUID. `AuthTokensRepository.CreateNewApiKey` **returns the existing token for the same user and device**, which is what makes the bootstrap's own token (device `shoko-bootstrap`) stable across runs.
- Once `FirstRun = false`, the settings validator requires both AniDB username and password.
- `GET /api/v3/Settings` masks secrets in 6.x, so don't compare passwords from it. On 5.3.3 they come back in plaintext.
- Changing the password (`POST /api/v3/User/Current/ChangePassword`, `/api/auth/ChangePassword`) needs a session for the user. The module deliberately doesn't reconcile the admin password. If it drifts, the 401 path fails with an explanatory message.
- Repeated failed sign-ins are throttled by `AuthenticationThrottleService`. If you see 429 or unexpected 401s after experimenting with wrong passwords, wait or restart Shoko.

## Commands

```bash
nix fmt                                  # nixfmt-tree
nix flake check --no-build --all-systems # eval only, quick
nix build .#checks.x86_64-linux.vm -L    # VM test; needs KVM (check /dev/kvm)
# interactive VM debugging:
nix build .#checks.x86_64-linux.vm.driverInteractive && ./result/bin/nixos-test-driver
# view the rendered bootstrap script:
nix eval --raw .#checks.x86_64-linux.vm.nodes.machine.systemd.services.shoko-bootstrap.script
```

New files must be `git add`ed before nix can see them, because this is a git-tracked flake.

## Testing against a running instance

**Ask the user before you touch their running Shoko.** The bootstrap:
- creates the admin user and completes setup if the instance is in setup mode;
- overwrites any settings it declares, including the AniDB credentials;
- creates API keys.

Find out the following first:
- whether it's a throwaway instance;
- its URL and port;
- whether it's already set up, by checking `curl -s <url>/api/v3/Init/Status`;
- the real admin username and password, and the AniDB credentials. Put the passwords in files with mode 0600 and never echo them or put them on a command line.

Also find out how the user's instance is run, so you can tell which option fits:
- `services.shoko` in the system config;
- `nix run nixpkgs#shoko`, the `Shoko.CLI` binary, with `SHOKO_HOME`;
- Docker.

Options, from least to most invasive:

1. **Throwaway local instance (preferred if the user agrees).** Run `SHOKO_HOME=$(mktemp -d) nix run nixpkgs#shoko` in the background. This needs port 8111 to be free. Then run the rendered script against it (option 2). You can reset it by killing it and deleting `SHOKO_HOME`.
2. **Run the rendered script by hand.**
   - Evaluate a NixOS config that uses the module with the user's values. Put the secrets in files under a temp dir, and set `url` if it isn't `127.0.0.1:8111`.
   - Extract `systemd.services.shoko-bootstrap.script`.
   - Replace `/run/shoko-bootstrap` with a temp dir; the hardcoded runtime dir doesn't exist outside systemd.
   - On Linux the store paths for `curl` and `jq` in the script are real. Realise them with `nix build --no-link` on the paths from `nix eval …script`, or with `nix-store -r`.
   - Example of evaluating against a custom config:
     ```bash
     nix eval --raw --impure --expr '
       let f = builtins.getFlake (toString ./.); in
       (f.inputs.nixpkgs.lib.nixosSystem {
         system = "x86_64-linux";
         modules = [ f.nixosModules.default {
           services.shoko.bootstrap = {
             enable = true;
             url = "http://127.0.0.1:8111";
             user = { username = "admin"; password._secret = "/tmp/sb/admin-password"; };
             anidb = { username = "…"; password._secret = "/tmp/sb/anidb-password"; };
           };
           fileSystems."/".device = "nodev"; boot.loader.grub.enable = false; system.stateVersion = "25.11";
         } ];
       }).config.systemd.services.shoko-bootstrap.script' > /tmp/sb/script.sh
     sed -i "s|/run/shoko-bootstrap|/tmp/sb/run|g" /tmp/sb/script.sh
     mkdir -p /tmp/sb/run && (umask 077; bash /tmp/sb/script.sh)
     ```
3. **Through the real unit on the user's NixOS host.** Add the flake as an input in their system config, then run `nixos-rebuild switch`. Check with `systemctl status shoko-bootstrap` and `journalctl -u shoko-bootstrap`. Re-run with `systemctl restart shoko-bootstrap`. Only do this with explicit approval.

Things to verify in any run:
- The script prints `Shoko bootstrap complete` and exits 0.
- `/api/v3/User/Current` with header `apikey: $(cat <runtime dir>/token)` returns the admin user.
- `/api/v3/Settings` shows the declared values and `FirstRun: false`.
- A second run leaves `<runtime dir>/token` **byte-identical**.
- Restarting Shoko and then the bootstrap still succeeds, going through the `Starting` → `Started` wait.
- `journalctl -u shoko-bootstrap` and the rendered script contain no secret values. File paths are fine.

## Style

- Nix is formatted with `nixfmt` (`nix fmt`).
- Match `module.nix`'s idioms: `escapeShellArg` for every interpolated value, and secrets only through the nixflix helpers.
- In the generated bash, keep `set -euo pipefail` intact.
- Keep the jq `ops($p)` JSON-Patch generator binding `.key` and `.value` into variables before recursing. jq filter arguments are lazy closures, and an earlier version produced paths like `/Username/Username`.
