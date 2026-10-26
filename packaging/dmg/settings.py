# The disk image's window, for dmgbuild: Corral on the left, an arrow, Applications on the right,
# on Corral's background. scripts/build.sh --package runs it through build.py, which passes the
# paths in.
#
# The icon centres match InstallerBackground.iconCenters in Sources/CorralUI/Hero.swift, and the
# window's inside matches its 660 × 420 layout. Change them together.

app = defines["app"]  # noqa: F821, dmgbuild provides `defines`

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821
# background.png, with background@2x.png beside it for Retina screens.
background = defines["background"]  # noqa: F821

# The height includes the 32-point title bar. The picture runs 20 points past the window's
# bottom, so a shorter title bar on older macOS shows more picture rather than a gap.
window_rect = ((240, 160), (660, 452))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 112
text_size = 13
icon_locations = {
    "Corral.app": (180, 212),
    "Applications": (480, 212),
}
hide_extension = ["Corral.app"]
