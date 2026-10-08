{ nixflix }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    escapeShellArg
    ;

  cfg = config.services.shoko.bootstrap;

  mkSecureCurl = import "${nixflix}/lib/mk-secure-curl.nix" { inherit lib pkgs; };
  secrets = import "${nixflix}/lib/secrets" { inherit lib; };

  jq = "${pkgs.jq}/bin/jq";

  # RuntimeDirectory of the unit; holds the bootstrap's own admin token.
  runtimeDir = "/run/shoko-bootstrap";
  tokenFile = "${runtimeDir}/token";
  bootstrapDevice = "shoko-bootstrap";

  # AniDB credentials are the only settings sent while Shoko is still in setup
  # mode, mirroring the WebUI wizard: the database isn't up yet, and some
  # settings (e.g. title language order) touch it when saved.
  anidbSettings = {
    AniDb = {
      Username = cfg.anidb.username;
      Password = cfg.anidb.password;
    };
  };
  allSettings = lib.recursiveUpdate cfg.settings anidbSettings;

  # Shell command printing `settings` as a JSON Patch: one `replace` op per
  # non-object leaf (arrays are replaced whole), with `_secret` refs read from
  # their files at runtime.
  mkSettingsPatch =
    name: settings:
    let
      json = pkgs.writeText "shoko-${name}.json" (builtins.toJSON (secrets.stripSecretRefs settings));
      secretArgs = secrets.mkNestedJqSecretArgs settings;
      program = lib.concatStringsSep " | " (
        secretArgs.assignments
        ++ [
          ''
            def ops($p): to_entries[] | (.key | gsub("~"; "~0") | gsub("/"; "~1")) as $k | .value as $v
              | if ($v | type) == "object"
                then ($v | ops($p + [$k]))
                else { op: "replace", path: ("/" + (($p + [$k]) | join("/"))), value: $v } end;
            [ops([])]''
        ]
      );
    in
    "${jq} -c ${secretArgs.flagsString} ${escapeShellArg program} ${json}";

  userSecrets = secrets.mkJqSecretArgs {
    username = cfg.user.username;
    password = cfg.user.password;
  };

  jsonHeaders = {
    "Content-Type" = "application/json";
  };

  # Every helper runs in a subshell: mkSecureCurl installs an EXIT trap to
  # clean up its payload temp file, which must not clobber the main shell's.
  # Response bodies go to $RESP, the HTTP status code to stdout.
  curlHelpers = ''
    noauth_get() (
      ${mkSecureCurl null {
        url = "$API/$1";
        extraArgs = ''-o "$RESP" -w '%{http_code}' '';
      }}
    )

    noauth_send() (
      ${mkSecureCurl null {
        url = "$API/$2";
        method = "$1";
        headers = jsonHeaders;
        data = "$3";
        extraArgs = ''-o "$RESP" -w '%{http_code}' '';
      }}
    )

    auth_send() (
      ${mkSecureCurl { _secret = tokenFile; } {
        url = "$API/$2";
        method = "$1";
        headers = jsonHeaders;
        data = "$3";
        apiKeyHeader = "apikey";
        extraArgs = ''-o "$RESP" -w '%{http_code}' '';
      }}
    )
  '';

  script = ''
    set -euo pipefail

    API=${escapeShellArg cfg.url}/api
    RESP=$(mktemp -p ${runtimeDir})

    ${curlHelpers}

    fail() {
      echo "shoko-bootstrap: $*" >&2
      if [ -s "$RESP" ]; then echo "response: $(cat "$RESP")" >&2; fi
      exit 1
    }

    expect_2xx() {
      case "$1" in
        2??) ;;
        *) fail "$2 failed with HTTP $1" ;;
      esac
    }

    deadline=$(( $(date +%s) + ${toString cfg.startupTimeout} ))

    # Prints the server's startup state (Waiting|Starting|Started|Failed),
    # retrying until the API answers or the deadline passes.
    get_state() {
      local code
      while :; do
        code=$(noauth_get v3/Init/Status || true)
        if [ "$code" = 200 ]; then
          ${jq} -r '.State' "$RESP"
          return
        fi
        [ "$(date +%s)" -lt "$deadline" ] || fail "timed out waiting for Shoko at ${cfg.url}"
        sleep 2
      done
    }

    wait_until_started() {
      local state
      while :; do
        state=$(get_state)
        case "$state" in
          Started) return ;;
          Failed) fail "Shoko failed to start: $(${jq} -r '.StartupMessage // empty' "$RESP")" ;;
        esac
        [ "$(date +%s)" -lt "$deadline" ] || fail "timed out waiting for Shoko to finish starting (state: $state)"
        sleep 2
      done
    }

    # Signs in as the declared user with the given device name; $RESP holds
    # {"apikey": ...}. Shoko reuses the existing token for a user+device pair.
    sign_in() {
      local payload code
      payload=$(${jq} -nc ${userSecrets.flagsString} --arg device "$1" \
        '{user: ${userSecrets.refs.username}, pass: ${userSecrets.refs.password}, device: $device}')
      code=$(noauth_send POST auth "$payload" || true)
      case "$code" in
        200) ;;
        401) fail "sign-in as the declared admin user was rejected. The password stored in Shoko differs from services.shoko.bootstrap.user.password; change it in the WebUI to match." ;;
        *) expect_2xx "$code" "sign-in" ;;
      esac
    }

    state=$(get_state)
    echo "Shoko startup state: $state"

    if [ "$state" = Waiting ]; then
      echo "Completing first-run setup..."

      payload=$(${jq} -nc ${userSecrets.flagsString} \
        '{Username: ${userSecrets.refs.username}, Password: ${userSecrets.refs.password}}')
      expect_2xx "$(noauth_send POST v3/Init/DefaultUser "$payload" || true)" "setting the default user"

      expect_2xx "$(noauth_send PATCH v3/Settings "$(${mkSettingsPatch "anidb-settings" anidbSettings})" || true)" \
        "setting AniDB credentials"

      code=$(noauth_send POST v3/Init/CompleteSetup "" || true)
      case "$code" in
        # Older servers (5.x) only have the now-deprecated GET StartServer.
        404 | 405) code=$(noauth_get v3/Init/StartServer || true) ;;
      esac
      expect_2xx "$code" "completing setup"
    fi

    echo "Waiting for Shoko to start..."
    wait_until_started

    sign_in ${bootstrapDevice}
    ${jq} -r '.apikey' "$RESP" > ${tokenFile}

    echo "Applying settings..."
    expect_2xx "$(auth_send PATCH v3/Settings "$(${mkSettingsPatch "settings" allSettings})" || true)" "applying settings"

    rm -f "$RESP"
    echo "Shoko bootstrap complete"
  '';
in
{
  options.services.shoko.bootstrap = {
    enable = mkEnableOption "declarative first-run setup of Shoko Server through its HTTP API";

    url = mkOption {
      type = types.str;
      default = "http://127.0.0.1:8111";
      description = "Base URL of the Shoko Server.";
    };

    user = {
      username = mkOption {
        type = types.str;
        description = "Username of the admin user created during first-run setup.";
        example = "admin";
      };
      password = secrets.mkSecretOption {
        description = "Password of the admin user.";
      };
    };

    anidb = {
      username = secrets.mkSecretOption {
        description = "AniDB username.";
      };
      password = secrets.mkSecretOption {
        description = "AniDB password.";
      };
    };

    settings = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = ''
        Extra Shoko server settings, applied as JSON Patch `replace` operations
        on every run. Nested attrsets map to the settings object's structure;
        lists and scalars are replaced whole. Any value may be
        `{ _secret = /path; }` to read it from a file at runtime.
      '';
      example = lib.literalExpression ''
        {
          Language.SeriesTitleLanguageOrder = [ "x-jat" "en" ];
          AniDb.DownloadCharacters = true;
        }
      '';
    };

    startupTimeout = mkOption {
      type = types.ints.positive;
      default = 300;
      description = "Seconds to wait for Shoko to become reachable and finish starting.";
    };
  };

  config = mkIf cfg.enable {
    warnings =
      lib.optional
        (
          lib.hasPrefix "http://" cfg.url
          && !(lib.any (h: lib.hasInfix h cfg.url) [
            "127.0.0.1"
            "localhost"
            "[::1]"
          ])
        )
        "services.shoko.bootstrap.url (${cfg.url}) is plain HTTP and not loopback: the admin password, AniDB credentials, and API token will cross the network in cleartext. Use https:// or a secure tunnel.";

    systemd.services.shoko-bootstrap = {
      description = "Declarative Shoko Server setup";
      after = [ "shoko.service" ];
      requires = [ "shoko.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.coreutils ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "shoko-bootstrap";
        RuntimeDirectoryMode = "0700";
        StateDirectory = "shoko-bootstrap";
        UMask = "0077";
        PrivateTmp = true;
      };

      inherit script;
    };
  };
}
