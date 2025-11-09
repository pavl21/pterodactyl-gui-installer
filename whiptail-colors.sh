#!/bin/bash

# Whiptail Farbkonfiguration für GermanDactyl Setup
# Basierend auf NEWT_COLORS Environment Variable
# Kompatibel mit whiptail/newt seit Version 0.52.13

# Verfügbare Farben: black, red, green, yellow, blue, magenta, cyan, white
# Format: element=foreground,background

# Standard-Theme (Blau)
export_standard_colors() {
    export NEWT_COLORS='root=,blue
window=,blue
border=white,blue
title=white,blue
button=black,white
actbutton=white,black
checkbox=white,blue
actcheckbox=white,blue
entry=white,blue
label=white,blue
listbox=white,blue
actlistbox=white,black
textbox=white,blue
acttextbox=white,black
helpline=white,blue
roottext=white,blue'
}

# Erfolg-Theme (Grün)
export_success_colors() {
    export NEWT_COLORS='root=,green
window=,green
border=white,green
title=black,green
button=black,white
actbutton=white,black
checkbox=white,green
actcheckbox=white,green
entry=white,green
label=black,green
listbox=black,green
actlistbox=white,black
textbox=black,green
acttextbox=white,black
helpline=black,green
roottext=black,green'
}

# Warnung-Theme (Gelb)
export_warning_colors() {
    export NEWT_COLORS='root=,yellow
window=,yellow
border=black,yellow
title=black,yellow
button=black,white
actbutton=white,black
checkbox=black,yellow
actcheckbox=black,yellow
entry=black,yellow
label=black,yellow
listbox=black,yellow
actlistbox=white,black
textbox=black,yellow
acttextbox=white,black
helpline=black,yellow
roottext=black,yellow'
}

# Fehler-Theme (Rot)
export_error_colors() {
    export NEWT_COLORS='root=,red
window=,red
border=white,red
title=white,red
button=black,white
actbutton=white,black
checkbox=white,red
actcheckbox=white,red
entry=white,red
label=white,red
listbox=white,red
actlistbox=white,black
textbox=white,red
acttextbox=white,black
helpline=white,red
roottext=white,red'
}

# Info-Theme (Cyan)
export_info_colors() {
    export NEWT_COLORS='root=,cyan
window=,cyan
border=black,cyan
title=black,cyan
button=black,white
actbutton=white,black
checkbox=black,cyan
actcheckbox=black,cyan
entry=black,cyan
label=black,cyan
listbox=black,cyan
actlistbox=white,black
textbox=black,cyan
acttextbox=white,black
helpline=black,cyan
roottext=black,cyan'
}

# Wrapper-Funktionen für farbige Dialoge
whiptail_success() {
    export_success_colors
    whiptail "$@"
    local ret=$?
    export_standard_colors
    return $ret
}

whiptail_warning() {
    export_warning_colors
    whiptail "$@"
    local ret=$?
    export_standard_colors
    return $ret
}

whiptail_error() {
    export_error_colors
    whiptail "$@"
    local ret=$?
    export_standard_colors
    return $ret
}

whiptail_info() {
    export_info_colors
    whiptail "$@"
    local ret=$?
    export_standard_colors
    return $ret
}

# Standard-Farben beim Laden setzen
export_standard_colors
