# Package

version       = "0.2.1"
author        = "Jonathan Bernard"
description   = "Personal Time Keeper"
license       = "MIT"
bin           = @["ptk"]

# Dependencies

requires @["nim >= 0.15.0", "docopt >= 0.6.4", "uuids", "langutils", "tempfile", "timeutils"]

