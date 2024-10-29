{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils  }: {

    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            android_sdk.accept_license = true;
            allowUnfree = true;
          };
        };
        buildToolsVersion = "34.0.0";
        androidComposition = pkgs.androidenv.composeAndroidPackages {
          buildToolsVersions = [ buildToolsVersion "30.0.3" ];
          platformVersions = [ "31"  ];
          includeEmulator = true;
          includeSystemImages = true;
          useGoogleAPIs = true;
          abiVersions = [ "x86_64" ];
          systemImageTypes = [ "google_apis_playstore" ];
        };
        androidSdk = androidComposition.androidsdk;
        jdk = pkgs.jdk;
      in
      {
        pkgs = pkgs;
        inherit androidComposition;
        devShell =
          let
            ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
          in
          pkgs.mkShell {
            shellHook = ''
            if [ ! -d "android-sdk" ]; then
               cp -R ${ANDROID_SDK_ROOT} android-sdk
               chmod 774 -R android-sdk
            else
              echo "android-sdk directory already exists"
            fi
            export ANDROID_SDK_ROOT=$PWD/android-sdk;
            export ANDROID_NDK_ROOT=$ANDROID_NDK_ROOT/ndk-bundle;
            export ANDROID_SDK_HOME=$HOME/.android;
            '';

            JAVA_HOME = jdk.home;

            ANDROID_JAVA_HOME = "${jdk.home}";
            buildInputs = [
              pkgs.libsecret
              androidSdk
              pkgs.jdk17
              pkgs.libsecret
              pkgs.openssl
              pkgs.android-studio
              androidComposition.platform-tools
            ];
          };
      });

  };
}
