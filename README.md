# shoko-declarative-nix

> Personal project. Most of this code — especially the bootstrap script
> and the calls to Shoko's HTTP API — was written by Claude, with manual
> revisions along the way.

A NixOS module that sets up a [Shoko Server](https://shokoanime.com) instance through its HTTP API, so nothing has to be entered in the WebUI. It completes the first-run wizard, creates the admin user, sets the AniDB credentials and applies extra settings.

It is built on [nixflix](https://github.com/kiriwalawren/nixflix)'s [`mkSecureCurl`](https://github.com/kiriwalawren/nixflix/blob/main/lib/mk-secure-curl.nix) and [secrets](https://github.com/kiriwalawren/nixflix/tree/main/lib/secrets) helpers. Secrets are read from files at runtime: they never reach the Nix store, and they never appear in a process's argv.

## Usage

```nix
{
  inputs.shoko-declarative.url = "github:my7h3le/shoko-declarative-nix/main";

  outputs = { nixpkgs, shoko-declarative, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        shoko-declarative.nixosModules.default
        ({ config, ... }: {

          # Initialize sops secrets
          sops.secrets."shoko/admin-password" = { };
          sops.secrets."anidb/password" = { };

          services.shoko.enable = true;

          services.shoko.bootstrap = {
            enable = true;
            user = {
              username = "admin";

              # Any secret option can also take a plain string. That's fine for
              # testing, but the value ends up in the Nix store. Note that
              # `sops.secrets."<name>"` must be declared (as above) before its
              # `.path` can be referenced — sops-nix only decrypts and
              # provisions secrets you've declared.
              #
              password._secret = config.sops.secrets."shoko/admin-password".path;
            };
            anidb = {
              username = "my-anidb-user";
              password._secret = config.sops.secrets."anidb/password".path;
            };
            settings = {
              # Shoko doesn't document every setting key. The quickest way to
              # find the one you want: open the WebUI, open your browser's
              # devtools Network tab, change that setting on the Settings page
              # and save, then inspect the `PATCH /api/v3/Settings` request
              # that fires — its JSON body's shape (including nesting) is
              # exactly what you mirror under `settings` here.
              Language.SeriesTitleLanguageOrder = [
                "x-jat"
                "en"
              ];
            };
            importFolders = [
              {
                Name = "Anime";
                Path = "/mnt/media/anime";
                WatchForNewFiles = true; # default
                DropFolderType = "None"; # default; or Source, Destination, Both
              }
            ];
          };
        })
      ];
    };
  };
}
```

## What `shoko-bootstrap.service` does

It runs as a oneshot after `shoko.service`, on every boot and every time the config changes.

1. It waits for `GET /api/v3/Init/Status`.
2. **Fresh instance** (`Waiting`, i.e. setup mode):
   - `POST /api/v3/Init/DefaultUser` sets the admin user.
   - `PATCH /api/v3/Settings` sets the AniDB credentials. These are the only settings sent at this point; see below.
   - `POST /api/v3/Init/CompleteSetup` finishes setup. On 5.x servers it falls back to `GET /api/v3/Init/StartServer`.
3. It waits for `Started`.
4. It signs in (`POST /api/auth`) as the admin with the key name `shoko-bootstrap`, and uses that key from then on.
5. It applies every declared setting with `PATCH /api/v3/Settings`. Each one is a JSON Patch `replace`, so this is idempotent.
6. It reconciles `importFolders` against `GET /api/v3/ImportFolder`, matching by path. Missing folders are added (`POST`), folders whose name, watch flag or drop type differ are updated (`PUT`), and unchanged ones are skipped.

On an instance that is already set up, the wizard is skipped, and steps 3–5 bring the settings back in line with the config.

During setup mode only the AniDB credentials are sent. That matches what the WebUI wizard does, and it's necessary: the database isn't up yet, and on Shoko 5.x saving certain settings at that stage (such as the title language order) crashes the server.

## Limitations

- The admin password is only set on first run. If the password stored in Shoko no longer matches `user.password`, the unit fails with a clear message, and you'll need to change the password in the WebUI to match.
- Removing a setting from `settings` does not reset it to its default.
- `null` values and empty attrsets in `settings` are dropped.
- Import folder paths must already exist and be readable by the Shoko service (which runs as a `DynamicUser`), and can't be nested inside one another. Shoko rejects them otherwise, and the unit fails with Shoko's error.
- Removing a folder from `importFolders` doesn't delete it from Shoko. Changing a folder's `Path` adds a new folder rather than moving the old one.

## Testing

`nix flake check` runs a NixOS VM test (`tests/vm.nix`), which needs a Linux builder. It covers a fresh install, a re-run against the initialized instance, a Shoko restart, and a check that no secrets appear in the unit.

## Acknowledgements

- Thanks to [nixflix](https://github.com/kiriwalawren/nixflix) for `mkSecureCurl` and the secrets helpers this module is built on - I also use nixflix itself to run my media server, and am pretty grateful for the project as a whole!

- Also thank you to the [Shoko](https://shokoanime.com) team for Shoko Server itself - this module just automates what the WebUI's first-run wizard already does.
