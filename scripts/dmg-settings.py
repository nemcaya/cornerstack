# dmgbuild settings for the Cornerstack disk image. dmgbuild runs this file
# with `defines` filled from the -D options scripts/make-dmg.sh passes: the
# app and the window background.
import os.path

application = defines["app"]
appname = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}

# The window frame, title bar included, fits the 600 x 380 background from
# scripts/make-dmg-background.swift: the app on the left, Applications on the
# right, its arrow and caption in between.
background = defines["background"]
window_rect = ((200, 120), (600, 408))
icon_locations = {appname: (160, 178), "Applications": (440, 178)}
default_view = "icon-view"
icon_size = 112
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
