# Builds Corral's disk image with dmgbuild, with two changes to what dmgbuild writes, for Finder
# on macOS 26:
#
# - No pBBk bookmark for the background. Finder trusts the bookmark over the classic alias, and
#   the bookmark it resolves doesn't find the picture, so the window stayed blank.
# - The window's background colour is the picture's own dark ink rather than dmgbuild's white.
#   Finder picks the icon labels' colour from it, so the labels come out light.
#
# Usage: build.py <settings.py> <volume name> <image.dmg> key=value...   (the -D defines)
import contextlib
import sys

import dmgbuild
import dmgbuild.core

INK = (0x14 / 255, 0x14 / 255, 0x14 / 255)

dmgbuild.core.Bookmark.for_file = staticmethod(lambda path: None)

_store = dmgbuild.core.DSStore


class _InkStore:
    @staticmethod
    @contextlib.contextmanager
    def open(path, mode="r+"):
        with _store.open(path, mode) as store:
            yield store
            view = store["."]
            icvp = view["icvp"]
            icvp["backgroundColorRed"], icvp["backgroundColorGreen"], icvp["backgroundColorBlue"] = INK
            view["icvp"] = icvp


dmgbuild.core.DSStore = _InkStore

settings, volume, image, *pairs = sys.argv[1:]
dmgbuild.build_dmg(image, volume, settings_file=settings, defines=dict(pair.split("=", 1) for pair in pairs))
