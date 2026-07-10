# CI entry point, following the nix/ci.nix pattern from
# jappeace/prrrrrrrrr and hatter.
#
#   nix-build nix/ci.nix -A all-builds     # everything CI compiles
#   nix-build nix/ci.nix -A native         # desktop build + unit tests
#   nix-build nix/ci.nix -A emulator-ui    # BLE UI test runner (then
#                                          # run ./result/bin/test-ui)
#
# The emulator runner is not part of all-builds: it needs KVM and a
# dedicated CI job (like hatter's emulator jobs).
{ sources ? import ./sources }:
let
  isDarwin = builtins.currentSystem == "aarch64-darwin"
          || builtins.currentSystem == "x86_64-darwin";
  pkgs = import sources.nixpkgs {};

  buildTargets = {
    # Desktop build with hatter's C stubs; runs the unit tests
    # (protocol codec, auth vectors, JSON) as its check phase.
    native = import ./native.nix { inherit sources; };
    android-aarch64 = import ../default.nix { inherit sources; };
    android-armv7a = import ../default.nix { inherit sources; androidArch = "armv7a"; };
    apk = import ./apk.nix { inherit sources; };
  } // (if isDarwin then {
    ios-lib = import ./ios.nix { inherit sources; };
    ios-simulator = import ./ios.nix { inherit sources; simulator = true; };
    ios-app = import ./ios-app.nix { inherit sources; };
  } else {});

  testScripts = builtins.path { path = ../test; name = "kbeacon-test-scripts"; };
  hatterTestScripts = builtins.path {
    path = "${sources.hatter}/test";
    name = "hatter-test-scripts";
  };

  # Lint the test shell scripts. helpers.sh comes from hatter, so its
  # directory is on the source path for the sourced-file check.
  shellcheckTarget = pkgs.runCommand "ci-shellcheck" {
    nativeBuildInputs = [ pkgs.shellcheck ];
  } ''
    shellcheck -x \
      --source-path=${hatterTestScripts}/android \
      ${testScripts}/android/kbeacon.sh
    echo "All shell scripts passed shellcheck."
    touch $out
  '';

  # Byte-compile the python test helpers so syntax errors fail CI even
  # though the scripts only run inside the emulator job.
  pythonCheckTarget = pkgs.runCommand "ci-python-check" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    python3 -m py_compile \
      ${testScripts}/android/kbeacon_peripheral.py \
      ${testScripts}/android/report_server.py
    echo "Python test helpers compile."
    touch $out
  '';

  checkTargets = buildTargets // {
    shellcheck = shellcheckTarget;
    python-check = pythonCheckTarget;
  };

in
checkTargets // {
  # Emulator UI test runner. Deliberately NOT in all-builds: it drags
  # in the multi-GB SDK + system image and needs KVM, so it gets a
  # dedicated CI job (same split as hatter's emulator jobs).
  emulator-ui = import ./emulator-ui.nix { inherit sources; };

  # Meta-target: builds every compilation target plus the linters.
  # Adding an attr to buildTargets automatically includes it here.
  all-builds = pkgs.runCommand "ci-all-builds" {} ''
    mkdir -p $out
    ${builtins.concatStringsSep "\n" (
      builtins.map (name: "ln -s ${checkTargets.${name}} $out/${name}")
        (builtins.attrNames checkTargets)
    )}
  '';
}
