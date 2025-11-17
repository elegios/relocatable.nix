{ writeShellApplication, lib, closureInfo, runCommand,
  stdenv, darwin, jq, stdenvNoCC, coreutils,
}:
{
  # The derivation to extract to a self-contained, relocated nix store
  drv,
  # The path to the folder that will contain the relocated nix store
  # _including trailing slash_
  path ? "/tmp/${drv.name}/",
  # The compressed file will have name "${tarName}.tar.gz"
  tarName ? drv.name,
  # Whether to create a wrapper that adds all the content in the
  # relocated nix store to environment variables
  doWrap ? true,
  # Extra setup to do in the wrapper script, for variables other than
  # PATH and LIBRARY_PATH. Requires doWrap. Run once per (transitive)
  # dependency, in topological order, i.e., dependencies are processed
  # before their dependants.
  extraSetup ? depPath: "",
  # Extra inputs that are required at runtime, but not explicitly
  # referenced in the original derivation. Requires doWrap.
  runtimeInputs ? [],
}:

let
  tsortedPaths = stdenvNoCC.mkDerivation {
    name = "toposorted-paths";
    __structuredAttrs = true;
    exportReferencesGraph.closure = [drv] ++ runtimeInputs;
    preferLocalBuild = true;
    nativeBuildInputs = [coreutils jq];
    buildCommand = ''
      out=''${outputs[out]}

      jq -r '.closure[] | .references[] + " " + .path' < "$NIX_ATTRS_JSON_FILE" | tsort > $out
    '';
  };
  pkg =
    if doWrap then
      writeShellApplication {
        name = builtins.baseNameOf (lib.getExe drv);
        text = ''
          shopt -s nullglob

          while IFS= read -r dep; do
            if test -d "$dep"/bin; then
              PATH="$dep/bin"''${PATH:+:''${PATH}}
              export PATH
            fi

            if test -d "$dep"/lib; then
              LIBRARY_PATH="$dep/lib"''${LIBRARY_PATH:+:''${LIBRARY_PATH}}
              export LIBRARY_PATH
            fi

            ${extraSetup "\"$dep\""}
          done < ${tsortedPaths}

          exec -a "$0" "${lib.getExe drv}" "$@"
        '';
      }
    else drv;
  normalize = path: "${builtins.toPath path}/";
  storeDir = normalize builtins.storeDir;
  rstoreDir = lib.concatStrings (lib.reverseList (lib.stringToCharacters storeDir));
  storePaths = "${closureInfo { rootPaths = pkg; }}/store-paths";

  # NOTE(vipa, 2025-06-11): The `replace` command is used for the
  # content of files, `rxform` is used for file names, and `sxform` is
  # used for symlink targets
  sedCommands =
    let hashLengthN = 32; in
    if builtins.stringLength path > builtins.stringLength storeDir then
      let toRemoveN = builtins.stringLength path - builtins.stringLength storeDir;
          toKeepN = hashLengthN - toRemoveN;
          toRemove = builtins.toString toRemoveN;
          toKeep = builtins.toString toKeepN;
      in
      {
        replace = "s#(${storeDir}[0-9a-z]{${toRemove}})([0-9a-z]{${toKeep}})-#${path}\\2-#g";
        rxform = "s#${rstoreDir}[0-9a-z]{${toRemove}}#${builtins.baseNameOf path}/#";
        sxform = "s#(${rstoreDir}[0-9a-z]{${toRemove}})([0-9a-z]{${toKeep}})-#${path}\\2-#";
      }
    else
      let toAdd = builtins.stringLength storeDir - builtins.stringLength path;
          extras = lib.strings.fixedWidthString toAdd "e" "";
          hashLength = builtins.toString hashLengthN;
      in
      {
        replace = "s#(${storeDir})([0-9a-z]{${hashLength}})-#${path}${extras}\\2-#g";
        rxform = "s#${rstoreDir}([0-9a-z]{${hashLength}})#${builtins.baseNameOf path}/${extras}\\1#";
        sxform = "s#${rstoreDir}([0-9a-z]{${hashLength}})-#${path}${extras}\\1-#";
      };

  maybeCodesign = lib.optionalString stdenv.hostPlatform.isDarwin ''
    chmod -R +w ${builtins.baseNameOf path}
    CODESIGN_ALLOCATE=${darwin.cctools}/bin/${darwin.cctools.targetPrefix}codesign_allocate \
    find ${builtins.baseNameOf path}/*/{bin,lib,libexec} -type f \
      -exec ${darwin.sigtool}/bin/sigtool --file "{}" check-requires-signature \; \
      -exec ${darwin.sigtool}/bin/codesign -s - -f "{}" \;
  '';

  passthru = {
    path = path;
    tarName = "${tarName}.tar.gz";
  };
in

runCommand "${drv.name}.tar.gz" {inherit passthru;} ''
  mkdir -p $out
  tar c \
    --owner=0 \
    --group=0 \
    --mode=u+r,uga+r \
    --hard-dereference \
    -P --transform='s#${storeDir}#${rstoreDir}#g' \
    -T '${storePaths}' \
  | sed -r "${sedCommands.replace}" \
  | tar x \
    --xform='flags=r;${sedCommands.rxform}x' \
    --xform='flags=s;${sedCommands.sxform}x'

  ln -s $(echo "${lib.getExe pkg}" | sed -r "${sedCommands.replace}") ${builtins.baseNameOf path}/${builtins.baseNameOf (lib.getExe pkg)}

  ${maybeCodesign}

  tar c ${builtins.baseNameOf path} | gzip > $out/${tarName}.tar.gz
''
