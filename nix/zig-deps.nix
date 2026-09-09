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
      name = "quark-0.2.0-Uqg3xpBHCQDmN0ctA7UhteVoZ88LIxJTVMloQ6S4mkfu";
      url = "https://codeberg.org/pparaxan/quark/archive/c104e1c953347d677fb1b363260854842217d967.tar.gz";
      hash = "sha256-wBXvdA3Dd02KfSW+j3GzXo66UzS1prkMCbHZfl9Ca1Q=";
    }
    {
      name = "N-V-__8AAOTNEADZkChhsSciYizE4kIbZsozjDZXVeG5R_uY";
      url = "https://gitlab.freedesktop.org/wayland/wayland-protocols/-/archive/1.49/wayland-protocols-1.49.tar.gz";
      hash = "sha256-jZTu4UjbTYERzMDUMx3i+C1LKMOOMOrOnwUohkgPfYY=";
    }
    {
      name = "N-V-__8AACIvTgCTqOj6KM32YnqNx1bcsaMuGAeKQEIWZ8Ph";
      url = "https://github.com/nothings/stb/archive/fede005abaf93d9d7f3a679d1999b2db341b360f.tar.gz";
      hash = "sha256-PEXpqxI5MydK14Lhn8QClES/4m4KXupIPDCoK4gLikI=";
    }
    {
      name = "zinfo-0.1.0-YDUPMiRwAACjmbWSJgANRyyDdnj9Oa2C4JuOB4YFu6Qo";
      url = "https://codeberg.org/pparaxan/zinfo/archive/aa19e2eb06cb7fdc1c77917a318054869e53a605.tar.gz";
      hash = "sha256-ri4QNby2xrh0IEEj37seKVsbQgaWJfHmFvB5rKW9qYg=";
    }
    {
      name = "pixman-0.3.0-LClMnz2VAAAs7QSCGwLimV5VUYx0JFnX5xWU6HwtMuDX";
      url = "https://codeberg.org/ifreund/zig-pixman/archive/v0.3.0.tar.gz";
      hash = "sha256-SwtXzjf3uzosL8du7JPQYIMNLJIVW/KmuqQ9Ya0FSZ4=";
    }
    {
      name = "wayland-0.6.0-lQa1kqz8AQADQmdNJsNhLoNHcnEGEUjrOaPV-dtEnEmX";
      url = "https://codeberg.org/ifreund/zig-wayland/archive/v0.6.0.tar.gz";
      hash = "sha256-dZpjLjapSODkEtLXSkOmnS805l1AKJoWr3qjclhS7yU=";
    }
    {
      name = "wlroots-0.20.1-jmOlcqNVBAB3uB5oqBTzpRlwu-FmMyyZMVAWCe5kmcSt";
      url = "https://codeberg.org/ifreund/zig-wlroots/archive/v0.20.1.tar.gz";
      hash = "sha256-1PXRYozSqB6ol+omOIcgZKuIAHxXEako4LN5wnBDoXU=";
    }
    {
      name = "xkbcommon-0.4.0-VDqIe0i2AgDRsok2GpMFYJ8SVhQS10_PI2M_CnHXsJJZ";
      url = "https://codeberg.org/ifreund/zig-xkbcommon/archive/v0.4.0.tar.gz";
      hash = "sha256-zB+INa1uUNXNTagqXRdBID89e0fHREGBZ7pgLnW4tcc=";
    }
    {
      name = "translate_c-0.0.0-Q_BUWlX1BgCD1wo6uo97prlp9VJ4gxAjwN_vZ7nsSjGN";
      url = "https://codeberg.org/ziglang/translate-c/archive/57c559cf581b1fcad90494eda219f98abeb155ce.tar.gz";
      hash = "sha256-uapd8zFqR2RbMCfEqnwQqyqJUZ9pQjUhACjLYM2dxl4=";
    }
    {
      # Transitive dependency of translate-c.
      name = "aro-0.0.0-JSD1Qi7QNgDnfcrdEJf82v3o6MhZySjYVrtdfEf3E4Se";
      url = "https://github.com/Vexu/arocc/archive/5f5a050569a95ecc40a426f0c3666ae7ef987ede.tar.gz";
      hash = "sha256-4gtJoTBJ6O9aodeYpw2PwCtpH+RMfHiSiq49Njod634=";
    }
  ];
in
linkFarm "aqueous-zig-dependencies" (
  map (package: {
    inherit (package) name;
    path = unpackZigPackage package;
  }) packages
)
