{
  description = "A cookie jar full of flakes.";

  inputs = {
    # Nixpkgs
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11";
    unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    # Snowfall.org Lib for Flake structure
    snowfall-lib.url = "github:snowfallorg/lib";
    snowfall-lib.inputs.nixpkgs.follows = "nixpkgs";

    # Home manager
    home-manager.url = "github:nix-community/home-manager/release-23.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Plasma manager
    plasma-manager.url = "github:pjones/plasma-manager";
    plasma-manager.inputs.nixpkgs.follows = "nixpkgs";
    plasma-manager.inputs.home-manager.follows = "home-manager";

    # Use sops-nix for secret management
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # NixOS Hardware Configurations for specific devices
    nixos-hardware.url = "github:nixos/nixos-hardware";

    # Mirror of vscode marketplace and open-vsx.org
    nix-vscode-extensions.url = "github:nix-community/nix-vscode-extensions";
    nix-vscode-extensions.inputs.nixpkgs.follows = "nixpkgs";

    # In order to build system images and artifacts supported by nixos-generators.
    nixos-generators.url = "github:nix-community/nixos-generators";
    nixos-generators.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs:
    inputs.snowfall-lib.mkFlake {
      inherit inputs;
      src = ./.;

      # Configure Snowfall Lib, all of these settings are optional.
      snowfall = {
        # Choose a namespace to use for your flake's packages, library,
        # and overlays.
        #namespace = "my-namespace";

        # Add flake metadata that can be processed by tools like Snowfall Frost.
        meta = {
          name = "lordkekz-dotfiles";
          title = "LordKekz's Dotflies";
        };
      };

      # The outputs builder receives an attribute set of your available NixPkgs channels.
      # These are every input that points to a NixPkgs instance (even forks). In this
      # case, the only channel available in this flake is `channels.nixpkgs`.
      outputs-builder = channels: {
        formatter = channels.nixpkgs.alejandra;
        packages =
          {
            hm = channels.nixpkgs.home-manager;
          }
          // (
            # This is needed because plasma-manager doesn't have a nix-darwin version.
            if (channels.nixpkgs.lib.attrsets.hasAttrByPath [channels.nixpkgs.system] inputs.plasma-manager.packages)
            then {pm = inputs.plasma-manager.packages.${channels.nixpkgs.system}.rc2nix;}
            else {}
          );
      };
    };
}
