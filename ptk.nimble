# Package

version       = "0.12.2"
author        = "Jonathan Bernard"
description   = "Personal Time Keeper"
license       = "MIT"
bin           = @["ptk"]

# Dependencies

requires @["nim >= 0.18.0", "docopt >= 0.6.4", "uuids", "langutils", "tempfile", "timeutils >= 0.2.2", "isaac >= 0.1.2"]

