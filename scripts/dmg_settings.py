# dmgbuild settings for the 盘屿 installer window (used by package-local-candidate.py).
# Pass the staged folder and the background with -D stage=<dir> -D background=<tiff>
# (dmgbuild runs this file without __file__). Icon centres must match the layout
# drawn in assets/brand/dmg/background.html; change both together.
import os.path

stage = defines['stage']  # noqa: F821 (dmgbuild provides `defines`)

format = 'UDZO'
filesystem = 'HFS+'
files = [os.path.join(stage, name) for name in ('Volisle.app', '开始使用.md', 'LICENSE.txt')]
symlinks = {'Applications': '/Applications'}
icon_locations = {
    'Volisle.app': (180, 200),
    'Applications': (480, 200),
    '开始使用.md': (270, 360),
    'LICENSE.txt': (390, 360),
}
hide_extension = ['Volisle.app', '开始使用.md', 'LICENSE.txt']

background = defines['background']  # noqa: F821
window_rect = ((200, 160), (660, 440))
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
arrange_by = None
icon_size = 96
text_size = 13
label_pos = 'bottom'
