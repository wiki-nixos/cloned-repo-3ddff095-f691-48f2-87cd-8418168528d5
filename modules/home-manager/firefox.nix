{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  cfg = config.programs.firefox;

  jsonFormat = pkgs.formats.json {};

  mozillaConfigPath =
    if isDarwin
    then "Library/Application Support/Mozilla"
    else ".mozilla";

  firefoxConfigPath =
    if isDarwin
    then "Library/Application Support/Firefox"
    else "${mozillaConfigPath}/firefox";

  profilesPath =
    if isDarwin
    then "${firefoxConfigPath}/Profiles"
    else firefoxConfigPath;

  nativeMessagingHostsPath =
    if isDarwin
    then "${mozillaConfigPath}/NativeMessagingHosts"
    else "${mozillaConfigPath}/native-messaging-hosts";

  nativeMessagingHostsJoined = pkgs.symlinkJoin {
    name = "ff_native-messaging-hosts";
    paths =
      [
        # Link a .keep file to keep the directory around
        (pkgs.writeTextDir "lib/mozilla/native-messaging-hosts/.keep" "")
        # Link package configured native messaging hosts (entire Firefox actually)
        cfg.finalPackage
      ]
      # Link user configured native messaging hosts
      ++ cfg.nativeMessagingHosts;
  };

  # The extensions path shared by all profiles; will not be supported
  # by future Firefox versions.
  extensionPath = "extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}";

  profiles =
    flip mapAttrs' cfg.profiles (_: profile:
      nameValuePair "Profile${toString profile.id}" {
        Name = profile.name;
        Path =
          if isDarwin
          then "Profiles/${profile.path}"
          else profile.path;
        IsRelative = 1;
        Default =
          if profile.isDefault
          then 1
          else 0;
      })
    // {
      General = {StartWithLastProfile = 1;};
    };

  profilesIni = generators.toINI {} profiles;

  userPrefValue = pref:
    builtins.toJSON (
      if isBool pref || isInt pref || isString pref
      then pref
      else builtins.toJSON pref
    );

  mkUserJs = prefs: extraPrefs: bookmarks: let
    prefs' =
      lib.optionalAttrs ([] != bookmarks) {
        "browser.bookmarks.file" = toString (firefoxBookmarksFile bookmarks);
        "browser.places.importBookmarksHTML" = true;
      }
      // prefs;
  in ''
    // Generated by Home Manager.

    ${concatStrings (mapAttrsToList (name: value: ''
        user_pref("${name}", ${userPrefValue value});
      '')
      prefs')}

    ${extraPrefs}
  '';

  mkContainersJson = containers: let
    containerToIdentity = _: container: {
      userContextId = container.id;
      name = container.name;
      icon = container.icon;
      color = container.color;
      public = true;
    };
  in ''
    ${builtins.toJSON {
      version = 4;
      lastUserContextId =
        elemAt (mapAttrsToList (_: container: container.id) containers) 0;
      identities =
        mapAttrsToList containerToIdentity containers
        ++ [
          {
            userContextId = 4294967294; # 2^32 - 2
            name = "userContextIdInternal.thumbnail";
            icon = "";
            color = "";
            accessKey = "";
            public = false;
          }
          {
            userContextId = 4294967295; # 2^32 - 1
            name = "userContextIdInternal.webextStorageLocal";
            icon = "";
            color = "";
            accessKey = "";
            public = false;
          }
        ];
    }}
  '';

  firefoxBookmarksFile = bookmarks: let
    indent = level:
      lib.concatStringsSep "" (map (lib.const "  ") (lib.range 1 level));

    bookmarkToHTML = indentLevel: bookmark: ''
      ${indent indentLevel}<DT><A HREF="${
        escapeXML bookmark.url
      }" ADD_DATE="1" LAST_MODIFIED="1"${
        lib.optionalString (bookmark.keyword != null)
        " SHORTCUTURL=\"${escapeXML bookmark.keyword}\""
      }${
        lib.optionalString (bookmark.tags != [])
        " TAGS=\"${escapeXML (concatStringsSep "," bookmark.tags)}\""
      }>${escapeXML bookmark.name}</A>'';

    directoryToHTML = indentLevel: directory: ''
      ${indent indentLevel}<DT>${
        if directory.toolbar
        then ''
          <H3 ADD_DATE="1" LAST_MODIFIED="1" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks Toolbar''
        else ''<H3 ADD_DATE="1" LAST_MODIFIED="1">${escapeXML directory.name}''
      }</H3>
      ${indent indentLevel}<DL><p>
      ${allItemsToHTML (indentLevel + 1) directory.bookmarks}
      ${indent indentLevel}</DL><p>'';

    itemToHTMLOrRecurse = indentLevel: item:
      if item ? "url"
      then bookmarkToHTML indentLevel item
      else directoryToHTML indentLevel item;

    allItemsToHTML = indentLevel: bookmarks:
      lib.concatStringsSep "\n"
      (map (itemToHTMLOrRecurse indentLevel) bookmarks);

    bookmarkEntries = allItemsToHTML 1 bookmarks;
  in
    pkgs.writeText "firefox-bookmarks.html" ''
      <!DOCTYPE NETSCAPE-Bookmark-file-1>
      <!-- This is an automatically generated file.
        It will be read and overwritten.
        DO NOT EDIT! -->
      <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
      <TITLE>Bookmarks</TITLE>
      <H1>Bookmarks Menu</H1>
      <DL><p>
      ${bookmarkEntries}
      </DL>
    '';

  mkNoDuplicateAssertion = entities: entityKind: (let
    # Return an attribute set with entity IDs as keys and a list of
    # entity names with corresponding ID as value. An ID is present in
    # the result only if more than one entity has it. The argument
    # entities is a list of AttrSet of one id/name pair.
    findDuplicateIds = entities:
      filterAttrs (_entityId: entityNames: length entityNames != 1)
      (zipAttrs entities);

    duplicates = findDuplicateIds (mapAttrsToList
      (entityName: entity: {"${toString entity.id}" = entityName;})
      entities);

    mkMsg = entityId: entityNames:
      "  - ID ${entityId} is used by " + concatStringsSep ", " entityNames;
  in {
    assertion = duplicates == {};
    message =
      ''
        Must not have a Firefox ${entityKind} with an existing ID but
      ''
      + concatStringsSep "\n" (mapAttrsToList mkMsg duplicates);
  });

  wrapPackage = package: let
    # The configuration expected by the Firefox wrapper.
    fcfg = {enableGnomeExtensions = cfg.enableGnomeExtensions;};

    # A bit of hackery to force a config into the wrapper.
    browserName =
      package.browserName or (builtins.parseDrvName package.name).name;

    # The configuration expected by the Firefox wrapper builder.
    bcfg = setAttrByPath [browserName] fcfg;
  in
    if package == null
    then null
    else if isDarwin
    then package
    else if versionAtLeast config.home.stateVersion "19.09"
    then
      package.override (old: {
        cfg = old.cfg or {} // fcfg;
        extraPolicies = (old.extraPolicies or {}) // cfg.policies;
      })
    else (pkgs.wrapFirefox.override {config = bcfg;}) package {};
in {
  disabledModules = ["programs/firefox.nix"];

  meta.maintainers = [maintainers.rycee maintainers.kira-bruneau];

  imports = [
    (mkRemovedOptionModule ["programs" "firefox" "extensions"] ''

      Extensions are now managed per-profile. That is, change from

        programs.firefox.extensions = [ foo bar ];

      to

        programs.firefox.profiles.myprofile.extensions = [ foo bar ];'')
    (mkRemovedOptionModule ["programs" "firefox" "enableAdobeFlash"]
      "Support for this option has been removed.")
    (mkRemovedOptionModule ["programs" "firefox" "enableGoogleTalk"]
      "Support for this option has been removed.")
    (mkRemovedOptionModule ["programs" "firefox" "enableIcedTea"]
      "Support for this option has been removed.")
  ];

  options = {
    programs.firefox = {
      enable = mkEnableOption "Firefox";

      package = mkOption {
        type = with types; nullOr package;
        default =
          if versionAtLeast config.home.stateVersion "19.09"
          then pkgs.firefox
          else pkgs.firefox-unwrapped;
        defaultText = literalExpression "pkgs.firefox";
        example = literalExpression ''
          pkgs.firefox.override {
            # See nixpkgs' firefox/wrapper.nix to check which options you can use
            nativeMessagingHosts = [
              # Gnome shell native connector
              pkgs.gnome-browser-connector
              # Tridactyl native connector
              pkgs.tridactyl-native
            ];
          }
        '';
        description = ''
          The Firefox package to use. If state version ≥ 19.09 then
          this should be a wrapped Firefox package. For earlier state
          versions it should be an unwrapped Firefox package.
          Set to `null` to disable installing Firefox.
        '';
      };

      nativeMessagingHosts = mkOption {
        type = types.listOf types.package;
        default = [];
        description = ''
          Additional packages containing native messaging hosts that should be
          made available to Firefox extensions.
        '';
      };

      finalPackage = mkOption {
        type = with types; nullOr package;
        readOnly = true;
        description = "Resulting Firefox package.";
      };

      policies = mkOption {
        type = types.attrsOf jsonFormat.type;
        default = {};
        description = "[See list of policies](https://mozilla.github.io/policy-templates/).";
        example = {
          DefaultDownloadDirectory = "\${home}/Downloads";
          BlockAboutConfig = true;
        };
      };

      profiles = mkOption {
        type = types.attrsOf (types.submodule ({
          config,
          name,
          ...
        }: {
          options = {
            name = mkOption {
              type = types.str;
              default = name;
              description = "Profile name.";
            };

            id = mkOption {
              type = types.ints.unsigned;
              default = 0;
              description = ''
                Profile ID. This should be set to a unique number per profile.
              '';
            };

            settings = mkOption {
              type = types.attrsOf (jsonFormat.type
                // {
                  description = "Firefox preference (int, bool, string, and also attrs, list, float as a JSON string)";
                });
              default = {};
              example = literalExpression ''
                {
                  "browser.startup.homepage" = "https://nixos.org";
                  "browser.search.region" = "GB";
                  "browser.search.isUS" = false;
                  "distribution.searchplugins.defaultLocale" = "en-GB";
                  "general.useragent.locale" = "en-GB";
                  "browser.bookmarks.showMobileBookmarks" = true;
                  "browser.newtabpage.pinned" = [{
                    title = "NixOS";
                    url = "https://nixos.org";
                  }];
                }
              '';
              description = ''
                Attribute set of Firefox preferences.

                Firefox only supports int, bool, and string types for
                preferences, but home-manager will automatically
                convert all other JSON-compatible values into strings.
              '';
            };

            extraConfig = mkOption {
              type = types.lines;
              default = "";
              description = ''
                Extra preferences to add to {file}`user.js`.
              '';
            };

            userChrome = mkOption {
              type = types.lines;
              default = "";
              description = "Custom Firefox user chrome CSS.";
              example = ''
                /* Hide tab bar in FF Quantum */
                @-moz-document url("chrome://browser/content/browser.xul") {
                  #TabsToolbar {
                    visibility: collapse !important;
                    margin-bottom: 21px !important;
                  }

                  #sidebar-box[sidebarcommand="treestyletab_piro_sakura_ne_jp-sidebar-action"] #sidebar-header {
                    visibility: collapse !important;
                  }
                }
              '';
            };

            userContent = mkOption {
              type = types.lines;
              default = "";
              description = "Custom Firefox user content CSS.";
              example = ''
                /* Hide scrollbar in FF Quantum */
                *{scrollbar-width:none !important}
              '';
            };

            bookmarks = mkOption {
              type = let
                bookmarkSubmodule =
                  types.submodule ({
                    config,
                    name,
                    ...
                  }: {
                    options = {
                      name = mkOption {
                        type = types.str;
                        default = name;
                        description = "Bookmark name.";
                      };

                      tags = mkOption {
                        type = types.listOf types.str;
                        default = [];
                        description = "Bookmark tags.";
                      };

                      keyword = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "Bookmark search keyword.";
                      };

                      url = mkOption {
                        type = types.str;
                        description = "Bookmark url, use %s for search terms.";
                      };
                    };
                  })
                  // {
                    description = "bookmark submodule";
                  };

                bookmarkType = types.addCheck bookmarkSubmodule (x: x ? "url");

                directoryType =
                  types.submodule ({
                    config,
                    name,
                    ...
                  }: {
                    options = {
                      name = mkOption {
                        type = types.str;
                        default = name;
                        description = "Directory name.";
                      };

                      bookmarks = mkOption {
                        type = types.listOf nodeType;
                        default = [];
                        description = "Bookmarks within directory.";
                      };

                      toolbar = mkOption {
                        type = types.bool;
                        default = false;
                        description = ''
                          Make this the toolbar directory. Note, this does _not_
                          mean that this directory will be added to the toolbar,
                          this directory _is_ the toolbar.
                        '';
                      };
                    };
                  })
                  // {
                    description = "directory submodule";
                  };

                nodeType = types.either bookmarkType directoryType;
              in
                with types;
                  coercedTo (attrsOf nodeType) attrValues (listOf nodeType);
              default = [];
              example = literalExpression ''
                [
                  {
                    name = "wikipedia";
                    tags = [ "wiki" ];
                    keyword = "wiki";
                    url = "https://en.wikipedia.org/wiki/Special:Search?search=%s&go=Go";
                  }
                  {
                    name = "kernel.org";
                    url = "https://www.kernel.org";
                  }
                  {
                    name = "Nix sites";
                    toolbar = true;
                    bookmarks = [
                      {
                        name = "homepage";
                        url = "https://nixos.org/";
                      }
                      {
                        name = "wiki";
                        tags = [ "wiki" "nix" ];
                        url = "https://nixos.wiki/";
                      }
                    ];
                  }
                ]
              '';
              description = ''
                Preloaded bookmarks. Note, this may silently overwrite any
                previously existing bookmarks!
              '';
            };

            path = mkOption {
              type = types.str;
              default = name;
              description = "Profile path.";
            };

            isDefault = mkOption {
              type = types.bool;
              default = config.id == 0;
              defaultText = "true if profile ID is 0";
              description = "Whether this is a default profile.";
            };

            search = {
              force = mkOption {
                type = with types; bool;
                default = false;
                description = ''
                  Whether to force replace the existing search
                  configuration. This is recommended since Firefox will
                  replace the symlink for the search configuration on every
                  launch, but note that you'll lose any existing
                  configuration by enabling this.
                '';
              };

              default = mkOption {
                type = with types; nullOr str;
                default = null;
                example = "DuckDuckGo";
                description = ''
                  The default search engine used in the address bar and search bar.
                '';
              };

              privateDefault = mkOption {
                type = with types; nullOr str;
                default = null;
                example = "DuckDuckGo";
                description = ''
                  The default search engine used in the Private Browsing.
                '';
              };

              order = mkOption {
                type = with types; uniq (listOf str);
                default = [];
                example = ["DuckDuckGo" "Google"];
                description = ''
                  The order the search engines are listed in. Any engines
                  that aren't included in this list will be listed after
                  these in an unspecified order.
                '';
              };

              engines = mkOption {
                type = with types; attrsOf (attrsOf jsonFormat.type);
                default = {};
                example = literalExpression ''
                  {
                    "Nix Packages" = {
                      urls = [{
                        template = "https://search.nixos.org/packages";
                        params = [
                          { name = "type"; value = "packages"; }
                          { name = "query"; value = "{searchTerms}"; }
                        ];
                      }];

                      icon = "''${pkgs.nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake.svg";
                      definedAliases = [ "@np" ];
                    };

                    "NixOS Wiki" = {
                      urls = [{ template = "https://nixos.wiki/index.php?search={searchTerms}"; }];
                      iconUpdateURL = "https://nixos.wiki/favicon.png";
                      updateInterval = 24 * 60 * 60 * 1000; # every day
                      definedAliases = [ "@nw" ];
                    };

                    "Bing".metaData.hidden = true;
                    "Google".metaData.alias = "@g"; # builtin engines only support specifying one additional alias
                  }
                '';
                description = ''
                  Attribute set of search engine configurations. Engines
                  that only have {var}`metaData` specified will
                  be treated as builtin to Firefox.

                  See [SearchEngine.jsm](https://searchfox.org/mozilla-central/rev/669329e284f8e8e2bb28090617192ca9b4ef3380/toolkit/components/search/SearchEngine.jsm#1138-1177)
                  in Firefox's source for available options. We maintain a
                  mapping to let you specify all options in the referenced
                  link without underscores, but it may fall out of date with
                  future options.

                  Note, {var}`icon` is also a special option
                  added by Home Manager to make it convenient to specify
                  absolute icon paths.
                '';
              };
            };

            containers = mkOption {
              type = types.attrsOf (types.submodule ({name, ...}: {
                options = {
                  name = mkOption {
                    type = types.str;
                    default = name;
                    description = "Container name, e.g., shopping.";
                  };

                  id = mkOption {
                    type = types.ints.unsigned;
                    default = 0;
                    description = ''
                      Container ID. This should be set to a unique number per container in this profile.
                    '';
                  };

                  # List of colors at
                  # https://searchfox.org/mozilla-central/rev/5ad226c7379b0564c76dc3b54b44985356f94c5a/toolkit/components/extensions/parent/ext-contextualIdentities.js#32
                  color = mkOption {
                    type = types.enum [
                      "blue"
                      "turquoise"
                      "green"
                      "yellow"
                      "orange"
                      "red"
                      "pink"
                      "purple"
                      "toolbar"
                    ];
                    default = "pink";
                    description = "Container color.";
                  };

                  icon = mkOption {
                    type = types.enum [
                      "briefcase"
                      "cart"
                      "circle"
                      "dollar"
                      "fence"
                      "fingerprint"
                      "gift"
                      "vacation"
                      "food"
                      "fruit"
                      "pet"
                      "tree"
                      "chill"
                    ];
                    default = "fruit";
                    description = "Container icon.";
                  };
                };
              }));
              default = {};
              example = {
                "shopping" = {
                  id = 1;
                  color = "blue";
                  icon = "cart";
                };
                "dangerous" = {
                  id = 2;
                  color = "red";
                  icon = "fruit";
                };
              };
              description = ''
                Attribute set of container configurations. See
                [Multi-Account
                Containers](https://support.mozilla.org/en-US/kb/containers)
                for more information.
              '';
            };

            extensions = mkOption {
              type = types.listOf types.package;
              default = [];
              example = literalExpression ''
                with pkgs.nur.repos.rycee.firefox-addons; [
                  privacy-badger
                ]
              '';
              description = ''
                List of Firefox add-on packages to install for this profile.
                Some pre-packaged add-ons are accessible from the
                [Nix User Repository](https://github.com/nix-community/NUR).
                Once you have NUR installed run

                ```console
                $ nix-env -f '<nixpkgs>' -qaP -A nur.repos.rycee.firefox-addons
                ```

                to list the available Firefox add-ons.

                Note that it is necessary to manually enable these extensions
                inside Firefox after the first installation.
              '';
            };

            desktopFile = {
              enable = mkOption {
                type = types.bool;
                default = false;
                example = mdDoc "true";
                description = mdDoc "If enabled, creates a distinct .desktop file for this profile. This makes it more convenient to launch different profiles, because they show up in the application launcher.";
              };
              icon = mkOption {
                type = with types; nullOr (either str path);
                default = "firefox";
                example = "/home/myuser/alternative-icon.png";
                description = mdDoc "Icon to display in file manager, menus, etc.";
              };
            };
          };
        }));
        default = {};
        description = "Attribute set of Firefox profiles.";
      };

      enableGnomeExtensions = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to enable the GNOME Shell native host connector. Note, you
          also need to set the NixOS option
          `services.gnome.gnome-browser-connector.enable` to
          `true`.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions =
      [
        (let
          defaults =
            catAttrs "name" (filter (a: a.isDefault) (attrValues cfg.profiles));
        in {
          assertion = cfg.profiles == {} || length defaults == 1;
          message =
            "Must have exactly one default Firefox profile but found "
            + toString (length defaults)
            + optionalString (length defaults > 1)
            (", namely " + concatStringsSep ", " defaults);
        })

        (let
          getContainers = profiles:
            flatten
            (mapAttrsToList (_: value: (attrValues value.containers)) profiles);

          findInvalidContainerIds = profiles:
            filter (container: container.id >= 4294967294)
            (getContainers profiles);
        in {
          assertion =
            cfg.profiles
            == {}
            || length (findInvalidContainerIds cfg.profiles) == 0;
          message = "Container id must be smaller than 4294967294 (2^32 - 2)";
        })

        (mkNoDuplicateAssertion cfg.profiles "profile")
      ]
      ++ (mapAttrsToList
        (_: profile: mkNoDuplicateAssertion profile.containers "container")
        cfg.profiles);

    warnings = optional (cfg.enableGnomeExtensions or false) ''
      Using 'programs.firefox.enableGnomeExtensions' has been deprecated and
      will be removed in the future. Please change to overriding the package
      configuration using 'programs.firefox.package' instead. You can refer to
      its example for how to do this.
    '';

    programs.firefox.finalPackage = wrapPackage cfg.package;

    home.packages = lib.optional (cfg.finalPackage != null) cfg.finalPackage;

    home.file = mkMerge ([
        {
          "${firefoxConfigPath}/profiles.ini" =
            mkIf (cfg.profiles != {}) {text = profilesIni;};

          "${nativeMessagingHostsPath}" = {
            source = "${nativeMessagingHostsJoined}/lib/mozilla/native-messaging-hosts";
            recursive = true;
          };
        }
      ]
      ++ flip mapAttrsToList cfg.profiles (_: profile: {
        "${profilesPath}/${profile.path}/.keep".text = "";

        "${profilesPath}/${profile.path}/chrome/userChrome.css" =
          mkIf (profile.userChrome != "") {text = profile.userChrome;};

        "${profilesPath}/${profile.path}/chrome/userContent.css" =
          mkIf (profile.userContent != "") {text = profile.userContent;};

        "${profilesPath}/${profile.path}/user.js" = mkIf (profile.settings
          != {}
          || profile.extraConfig != ""
          || profile.bookmarks != []) {
          text =
            mkUserJs profile.settings profile.extraConfig profile.bookmarks;
        };

        "${profilesPath}/${profile.path}/containers.json" = mkIf (profile.containers != {}) {
          text = mkContainersJson profile.containers;
        };

        "${profilesPath}/${profile.path}/search.json.mozlz4" =
          mkIf
          (profile.search.default
            != null
            || profile.search.privateDefault != null
            || profile.search.order != []
            || profile.search.engines != {}) {
            force = profile.search.force;
            source = let
              settings = {
                version = 6;
                engines = let
                  # Map of nice field names to internal field names.
                  # This is intended to be exhaustive and should be
                  # updated at every version bump.
                  internalFieldNames =
                    (genAttrs [
                      "name"
                      "isAppProvided"
                      "loadPath"
                      "hasPreferredIcon"
                      "updateInterval"
                      "updateURL"
                      "iconUpdateURL"
                      "iconURL"
                      "iconMapObj"
                      "metaData"
                      "orderHint"
                      "definedAliases"
                      "urls"
                    ] (name: "_${name}"))
                    // {
                      searchForm = "__searchForm";
                    };

                  processCustomEngineInput = input:
                    (removeAttrs input ["icon"])
                    // optionalAttrs (input ? icon) {
                      # Convenience to specify absolute path to icon
                      iconURL = "file://${input.icon}";
                    }
                    // (optionalAttrs (input ? iconUpdateURL) {
                        # Convenience to default iconURL to iconUpdateURL so
                        # the icon is immediately downloaded from the URL
                        iconURL = input.iconURL or input.iconUpdateURL;
                      }
                      // {
                        # Required for custom engine configurations, loadPaths
                        # are unique identifiers that are generally formatted
                        # like: [source]/path/to/engine.xml
                        loadPath = ''
                          [home-manager]/programs.firefox.profiles.${profile.name}.search.engines."${
                            replaceStrings ["\\"] ["\\\\"] input.name
                          }"'';
                      });

                  processEngineInput = name: input: let
                    requiredInput = {
                      inherit name;
                      isAppProvided =
                        input.isAppProvided or removeAttrs input
                        ["metaData"]
                        == {};
                      metaData = input.metaData or {};
                    };
                  in
                    if requiredInput.isAppProvided
                    then requiredInput
                    else processCustomEngineInput (input // requiredInput);

                  buildEngineConfig = name: input:
                    mapAttrs' (name: value: {
                      name = internalFieldNames.${name} or name;
                      inherit value;
                    }) (processEngineInput name input);

                  sortEngineConfigs = configs: let
                    buildEngineConfigWithOrder = order: name: let
                      config =
                        configs.${name}
                        or {
                          _name = name;
                          _isAppProvided = true;
                          _metaData = {};
                        };
                    in
                      config
                      // {
                        _metaData = config._metaData // {inherit order;};
                      };

                    engineConfigsWithoutOrder =
                      attrValues (removeAttrs configs profile.search.order);

                    sortedEngineConfigs =
                      (imap buildEngineConfigWithOrder profile.search.order)
                      ++ engineConfigsWithoutOrder;
                  in
                    sortedEngineConfigs;

                  engineInput =
                    profile.search.engines
                    // {
                      # Infer profile.search.default as an app provided
                      # engine if it's not in profile.search.engines
                      ${profile.search.default} =
                        profile.search.engines.${profile.search.default} or {};
                    }
                    // {
                      ${profile.search.privateDefault} =
                        profile.search.engines.${profile.search.privateDefault} or {};
                    };
                in
                  sortEngineConfigs (mapAttrs buildEngineConfig engineInput);

                metaData =
                  optionalAttrs (profile.search.default != null) {
                    current = profile.search.default;
                    hash = "@hash@";
                  }
                  // optionalAttrs (profile.search.privateDefault != null) {
                    private = profile.search.privateDefault;
                    privateHash = "@privateHash@";
                  }
                  // {
                    useSavedOrder = profile.search.order != [];
                  };
              };

              # Home Manager doesn't circumvent user consent and isn't acting
              # maliciously. We're modifying the search outside of Firefox, but
              # a claim by Mozilla to remove this would be very anti-user, and
              # is unlikely to be an issue for our use case.
              disclaimer = appName:
                "By modifying this file, I agree that I am doing so "
                + "only within ${appName} itself, using official, user-driven search "
                + "engine selection processes, and in a way which does not circumvent "
                + "user consent. I acknowledge that any attempt to change this file "
                + "from outside of ${appName} is a malicious act, and will be responded "
                + "to accordingly.";

              salt =
                if profile.search.default != null
                then profile.path + profile.search.default + disclaimer "Firefox"
                else null;

              privateSalt =
                if profile.search.privateDefault != null
                then
                  profile.path
                  + profile.search.privateDefault
                  + disclaimer "Firefox"
                else null;
            in
              pkgs.runCommand "search.json.mozlz4" {
                nativeBuildInputs = with pkgs; [mozlz4a openssl];
                json = builtins.toJSON settings;
                inherit salt privateSalt;
              } ''
                if [[ -n $salt ]]; then
                  export hash=$(echo -n "$salt" | openssl dgst -sha256 -binary | base64)
                  export privateHash=$(echo -n "$privateSalt" | openssl dgst -sha256 -binary | base64)
                  mozlz4a <(substituteStream json search.json.in --subst-var hash --subst-var privateHash) "$out"
                else
                  mozlz4a <(echo "$json") "$out"
                fi
              '';
          };

        "${profilesPath}/${profile.path}/extensions" = mkIf (profile.extensions != []) {
          source = let
            extensionsEnvPkg = pkgs.buildEnv {
              name = "hm-firefox-extensions";
              paths = profile.extensions;
            };
          in "${extensionsEnvPkg}/share/mozilla/${extensionPath}";
          recursive = true;
          force = true;
        };
      }));

    xdg.desktopEntries = mkMerge (flip mapAttrsToList cfg.profiles (_: profile:
      mkIf (profile.desktopFile.enable) {
        "firefox-profile-${profile.name}" = let
          wm_class =
            # To group windows of different profiles.
            # Set WM_CLASS on Xorg using --class, set app-id on Wayland using --name.
            #if profile.name == "default"
            #then "firefox"
            #else "firefox-${profile.name}";
            "firefox";
          ff-cmd-raw = ''${cfg.package}/bin/firefox'';
          ff-cmd = ''${ff-cmd-raw} -p "${profile.name}" --class="${wm_class}" --name="${wm_class}"'';
        in {
          actions = {
            new-private-window = {
              name = "New Private Window";
              exec = "${ff-cmd} --private-window %U";
            };
            new-window = {
              name = "New Window";
              exec = "${ff-cmd} --new-window %U";
            };
            profile-manager-window = {
              name = "Profile Manager";
              exec = "${ff-cmd-raw} --ProfileManager";
            };
          };
          categories = ["Network" "WebBrowser"];
          exec = "${ff-cmd} %U";
          genericName = "Web Browser";
          icon = mkMerge [
            # FIXME Is there a better way to get the value or - if none is set - the default?
            (mkIf (profile.desktopFile ? icon) profile.desktopFile.icon)
            (mkIf (! profile.desktopFile ? icon) "firefox")
          ];
          mimeType = [
            "text/html"
            "text/xml"
            "application/xhtml+xml"
            "application/vnd.mozilla.xul+xml"
            "x-scheme-handler/http"
            "x-scheme-handler/https"
          ];
          name = "Firefox (${profile.name} profile)";
          startupNotify = true;
          settings.StartupWMClass = wm_class;
          terminal = false;
          type = "Application";
        };
      }));
  };
}
