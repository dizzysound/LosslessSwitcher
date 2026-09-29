#!/bin/bash
# menuclick.sh "<top item>" ["<submenu item prefix>"]: click an item in the Dev app's status menu.
# A submenu item matches by prefix, since some names carry state ("TPDF Dither (16-bit DAC)").
osascript - "$1" "$2" <<'EOF'
on run argv
  set top to item 1 of argv
  set sub to item 2 of argv
  tell application "System Events" to tell (first process whose bundle identifier is "com.dizzysound.LosslessSwitcher.dev")
    set mi to menu bar item 1 of menu bar 2
    click mi
    delay 0.4
    set t to menu item top of menu 1 of mi
    if sub is "" then
      click t
      return "clicked " & top
    end if
    click t
    delay 0.3
    repeat with s in menu items of menu 1 of t
      set n to name of s
      if n is not missing value and n starts with sub then
        click s
        return "clicked " & top & " > " & n
      end if
    end repeat
    key code 53
    return "not found: " & sub
  end tell
end run
EOF
