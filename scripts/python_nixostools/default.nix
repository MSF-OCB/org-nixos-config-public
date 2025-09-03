{ lib
, python3Packages
, doCheck ? true
}:

let
  pyproject = lib.importTOML ./pyproject.toml;
  pname = pyproject.project.name;
  inherit (pyproject.project) version;
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./pyproject.toml
      ./nixostools
    ];
  };

  package =
    { buildPythonApplication
    , ansible-core
    , flit-core
    , mypy
    , pylint
    , pynacl
    , pyyaml
    , types-pyyaml
    , requests
    , types-requests
    , ruff
    }:
    buildPythonApplication {
      inherit pname version src doCheck;

      pyproject = true;

      nativeCheckInputs = [ mypy pylint ruff types-pyyaml types-requests ];
      propagatedBuildInputs = [ flit-core ansible-core pynacl pyyaml requests ];

      checkPhase = ''
        mypy ${src}/nixostools
        ruff check --no-cache ${src}/nixostools
        PYLINTHOME="$TMPDIR" pylint ${src}/nixostools
      '';

      meta = {
        description = ''
          Collection of useful python scripts.
        '';
      };
    };
in
python3Packages.callPackage package { }
