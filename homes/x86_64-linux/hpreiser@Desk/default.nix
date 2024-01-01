# All my desktop-specific user configuration.
{
    # Snowfall Lib provides a customized `lib` instance with access to your flake's library
    # as well as the libraries available from your flake's inputs.
    lib,
    # An instance of `pkgs` with your overlays and packages applied is also available.
    pkgs,
    # You also have access to your flake's inputs.
    inputs,

    # Additional metadata is provided by Snowfall Lib.
    home, # The home architecture for this host (eg. `x86_64-linux`).
    target, # The Snowfall Lib target for this home (eg. `x86_64-home`).
    format, # A normalized name for the home target (eg. `home`).
    virtual, # A boolean to determine whether this home is a virtual target using nixos-generators.
    host, # The host name for this home.

    # All other arguments come from the home home.
    config,
    ...
}: if (true) then {
  nixpkgs.config = {
      # Disable if you don't want unfree packages
      allowUnfree = true;
      # Workaround for https://github.com/nix-community/home-manager/issues/2942
      allowUnfreePredicate = _: true;
    };
    home.packages = [pkgs.obsidian];
    home.stateVersion = "23.11"; } else {
  # Make autostart symlinks
  imports = [
    #./alacritty.nix
    #./desktop-autostart.nix
    #./mail.nix
    #./plasma-config.nix
  ];

  home = rec {
    username = "hpreiser";
    homeDirectory = "/home/${username}";
  };

  # Enable home-manager and git
  programs.home-manager.enable = true;

  # Nicely reload system units when changing configs
  # systemd.user.startServices = "sd-switch";

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  home.stateVersion = "23.11";

  # Make fonts from font packages available
  fonts.fontconfig.enable = true;

  home.packages = with pkgs; [
    # Nerdfonts
    (nerdfonts.override {fonts = ["JetBrainsMono"];})

    # OFFICE
    obsidian # Markdown-based Notes
    libreoffice
    pdfarranger # https://github.com/pdfarranger/pdfarranger
    diff-pdf # https://github.com/vslavik/diff-pdf

    # UTILITY
    syncthingtray # FIXME it autostarts itself without nix's help. It also has a plasmoid.
    anki # Spaced-repetition flashcards
    filezilla # FTP client
    filelight # A fancy directory size viewer by KDE
    meld # visual diff and merge tool
    kleopatra
    isoimagewriter # KDE's ISO Image Writer

    # MULTIMEDIA
    elisa
    vlc
    jellyfin-media-player
    audacity
    gimp
    (inkscape-with-extensions.override {inkscapeExtensions = with inkscape-extensions; [hexmap];})

    # GAMING AND WINE
    lutris # Open source gaming platform; use for GTA5
    prismlauncher
    #minecraft # official launcher is BROKEN, see https://github.com/NixOS/nixpkgs/issues/114732
    optifine
    #steam # steam gets enabled in NixOSConfig
    wineWowPackages.stable # support both 32- and 64-bit applications
    linux-wallpaperengine # Wallpaper Engine

    # COMMUNICATION
    birdtray
    telegram-desktop
    signal-desktop
    discord
    # FIXME There is also 'element-desktop-wayland', maybe we need to use that for screen sharing or sth.
    element-desktop
    # There is an unofficial whatsapp client: whatsapp-for-linux

    # PROGRAMMING
    jetbrains-toolbox
    sqlitebrowser
    # vscodium
    (vscode-with-extensions.override
      {
        vscode = vscodium;
        vscodeExtensions = with inputs.nix-vscode-extensions.extensions.${system}.vscode-marketplace; [
          jnoortheen.nix-ide
          thenuprojectcontributors.vscode-nushell-lang
          ms-azuretools.vscode-docker
          tecosaur.latex-utilities
          james-yu.latex-workshop
        ];
      })
  ];

  programs.firefox.enable = true;

  programs.texlive = {
    enable = true;
    extraPackages = tpkgs: {inherit (tpkgs) scheme-full;};
  };
  home.file.texmf.source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/DocumentsSynced/texmf";

  services.kdeconnect = {
    enable = true;
    indicator = true;
  };

  programs.obs-studio = {
    enable = true;
    plugins = with pkgs.obs-studio-plugins; [
      obs-pipewire-audio-capture
      obs-vkcapture
      input-overlay
    ];
  };

  # Declaratively configure connection of virt-manager to libvirtd QEMU/KVM
  # https://nixos.wiki/wiki/Virt-manager
  dconf.settings = {
    "org/virt-manager/virt-manager/connections" = {
      autoconnect = ["qemu:///system"];
      uris = ["qemu:///system"];
    };
  };
}
