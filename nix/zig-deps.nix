{
  fetchurl,
  gzip,
  gnutar,
  linkFarm,
  runCommand,
}:

let
  # Zig's --system directory is a flat directory whose entries use the package
  # identity from build.zig.zon.  Fetch the archives as fixed-output files and
  # unpack them separately so builds never need network access.
  unpackZigPackage =
    {
      name,
      url,
      hash,
    }:
    runCommand "${name}-source"
      {
        src = fetchurl { inherit url hash; };
        nativeBuildInputs = [
          gzip
          gnutar
        ];
      }
      ''
        mkdir -p "$out"
        tar -xzf "$src" --strip-components=1 -C "$out"
      '';

  packages = [
    {
      name = "pixman-0.4.0-LClMn_eWAAAa2zACATDpPwjuI5fWlO5cBp_F_M33hnNZ";
      url = "https://codeberg.org/ifreund/zig-pixman/archive/v0.4.0.tar.gz";
      hash = "sha256-zTDg7gqmWM9e5458+6EU1pHY7DYq6TLY8Yl3IdGewHQ=";
    }
    {
      name = "wayland-0.7.0-lQa1kuP8AQD5dW7_o-VKLVD_QbqXe7Zob78r2su7Pyex";
      url = "https://codeberg.org/ifreund/zig-wayland/archive/v0.7.0.tar.gz";
      hash = "sha256-brMxhLUvS4+DTJD1Od+y/A7HzlkxiW+ttMPqtyC4ybg=";
    }
    {
      name = "wlroots-0.20.2-jmOlcnNzBABWqu98eO4JyEcBzw0ktfhwn-G7hNuWS91i";
      url = "https://codeberg.org/ifreund/zig-wlroots/archive/v0.20.2.tar.gz";
      hash = "sha256-CzMSrWDr78x7g3M2KdmFLSx6H9cD6pTzl40/FKo1ltM=";
    }
    {
      name = "xkbcommon-0.5.0-VDqIe8y3AgDU-cGL02xZplwABH3WbpTimrrgbgTgD_3g";
      url = "https://codeberg.org/ifreund/zig-xkbcommon/archive/v0.5.0.tar.gz";
      hash = "sha256-yP6Y7XfZLW6oqlYBfuHam7UEpOFBm8OC0Pn7C8w5Ih8=";
    }
    {
      name = "translate_c-2.0.2-Q_BUWvBNBwBgPKQJPblip6M7AHNK_IPNPmyv4rSIQMQc";
      url = "https://codeberg.org/ziglang/translate-c/archive/2.0.2.tar.gz";
      hash = "sha256-AFW/jpYInsyyvSMXmNJlJrjJm7D4w4coL3EVB7ZIE8g=";
    }
    {
      name = "aro-0.0.0-JSD1QvCRNwC2O1Jkop9TO6sXb1U1vhrH8FnYK1VdEMKn";
      url = "https://codeberg.org/ziglang/arocc/archive/630d99ed60fe61ccabe721f1af60881f8b2adde3.tar.gz";
      hash = "sha256-BAXVntWJTLVJvCbqSE+ifEjfNNcDslo8uHilDCmbJgk=";
    }
  ];
in
linkFarm "aqueous-zig-dependencies" (
  map (package: {
    inherit (package) name;
    path = unpackZigPackage package;
  }) packages
)
