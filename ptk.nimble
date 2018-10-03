# Package
include "private/version.nim"

version       = PTK_VERSION
author        = "Jonathan Bernard"
description   = "Personal Time Keeper"
license       = "MIT"
bin           = @["ptk"]

# Dependencies

requires @["nim >= 0.18.0", "docopt >= 0.6.4", "uuids", "langutils", "tempfile", "timeutils >= 0.2.2", "isaac >= 0.1.2", "bcrypt", "cliutils >= 0.5.0", "jester 0.2.0"]

