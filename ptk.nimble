# Package

version       = "1.0.5"
author        = "Jonathan Bernard"
description   = "Personal Time Keeper"
license       = "MIT"
bin           = @["ptk"]

# Dependencies

requires @[
  "nim >= 1.0.0",
  "docopt >= 0.6.8",
  "uuids",
  "tempfile",
  "isaac >= 0.1.3",
  "bcrypt",
  "jester 0.4.1",
  "https://git.jdb-labs.com/jdb/nim-lang-utils.git",
  "https://git.jdb-labs.com/jdb/nim-cli-utils.git",
  "https://git.jdb-labs.com/jdb/nim-time-utils.git >= 0.5.2",
  "https://git.jdb-labs.com/jdb/update-nim-package-version"
]

task updateVersion, "Update the version of this package.":
  exec "update_nim_package_version ptk 'private/version.nim'"