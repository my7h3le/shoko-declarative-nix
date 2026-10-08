{ pkgs, module }:
pkgs.testers.runNixOSTest {
  name = "shoko-declarative";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ module ];

      virtualisation.memorySize = 2048;

      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];

      # Stand-ins for sops-nix secret files.
      environment.etc."shoko-secrets/admin-password".text = "s3cret \"quoted\" $pass\n";
      environment.etc."shoko-secrets/anidb-password".text = "zz-anidb-secret-value\n";

      services.shoko.enable = true;
      services.shoko.bootstrap = {
        enable = true;
        user = {
          username = "admin";
          password._secret = "/etc/shoko-secrets/admin-password";
        };
        anidb = {
          username = "anidb-user";
          password._secret = "/etc/shoko-secrets/anidb-password";
        };
        settings.Language.SeriesTitleLanguageOrder = [
          "en"
          "x-jat"
        ];
      };
    };

  testScript = ''
    import json

    api = "http://127.0.0.1:8111/api"

    def check_instance():
        status = json.loads(machine.succeed(f"curl -sf {api}/v3/Init/Status"))
        assert status["State"] == "Started", status

        key = machine.succeed("cat /run/shoko-bootstrap/token").strip()
        assert len(key) > 0

        user = json.loads(machine.succeed(f"curl -sf -H 'apikey: {key}' {api}/v3/User/Current"))
        assert user["Username"] == "admin", user

        settings = json.loads(machine.succeed(f"curl -sf -H 'apikey: {key}' {api}/v3/Settings"))
        assert settings["AniDb"]["Username"] == "anidb-user", settings["AniDb"]
        assert settings["Language"]["SeriesTitleLanguageOrder"] == ["en", "x-jat"], settings["Language"]
        assert settings["FirstRun"] is False
        return key

    machine.wait_for_unit("shoko-bootstrap.service", timeout=600)
    key = check_instance()

    with subtest("re-running against an initialized instance is idempotent"):
        machine.succeed("systemctl restart shoko-bootstrap.service")
        assert check_instance() == key

    with subtest("survives a Shoko restart"):
        machine.succeed("systemctl restart shoko.service")
        machine.succeed("systemctl restart shoko-bootstrap.service")
        assert check_instance() == key

    with subtest("no secrets in the rendered unit"):
        unit = machine.succeed("cat $(systemctl show -P FragmentPath shoko-bootstrap.service)")
        script = machine.succeed("cat $(systemctl show -P ExecStart shoko-bootstrap.service | grep -o '/nix/store/[^ ;]*')")
        for text in (unit, script):
            assert "s3cret" not in text
            assert "zz-anidb-secret-value" not in text
  '';
}
