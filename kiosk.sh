#!/bin/bash
# --------------------------------------------------------------------------------
#  kiosk.sh
# --------------------------------------------------------------------------------
#  Raspberry Pi based Kiosks
# 
#  Configuration Script. Allows operator to configure actions of Pi
#  
#  Version 9.7
# --------------------------------------------------------------------------------
#  (C) Copyright Gareth Jones - gareth@gareth.com
# --------------------------------------------------------------------------------

# configuration parameters
WT_TITLE="Kelowna Curling Club Kiosk Management v9.7"
WT_COPYRIGHT="(c) Gareth Jones - gareth@gareth.com"
WT_HEIGHT=25
WT_WIDTH=80
WT_MENU_HEIGHT=$((WT_HEIGHT - 7))
ROTATION="H"

# --------------------------------------------------------------------------------
# menus
# --------------------------------------------------------------------------------
do_menu_main() {
  # display main menu
  while true; do
    # display menu
    FUN=$(whiptail --title "$WT_TITLE" --backtitle "$WT_COPYRIGHT" --menu "Setup Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT  --cancel-button Quit --ok-button Select \
    "P1"  "Club Cameras"      \
    "P2"  "Single Camera"     \
    "P3"  "Custom Cameras"    \
    "P4"  "Kiosk"             \
    "P5"  "Screen Rotation"   \
    "P6"  "Software Update"   \
    "P7"  "System Update"     \
    "P8"  "Raspberry Config"  \
    "P9"  "Install Kiosk"     \
    "P10" "Reboot"            \
    3>&1 1>&2 2>&3)
    RET=$?

    # process response
    if [ $RET -eq 0 ]; then
      # menu item was selected
      case "$FUN" in
        P1)  do_menu_club_cameras;;
        P2)  do_menu_single_camera;;
        P3)  do_menu_custom_cameras;;
        P4)  do_menu_kiosks;;
        P5)  do_menu_rotation;;
        P6)  do_auto_update;;
        P7)  do_apt;;
        P8)  do_raspi_config;;
        P9)  do_install;;
        P10) do_reboot;;
        *) whiptail --msgbox "Programmer error: unrecognized option" 20 60 1 ;;
      esac || whiptail --msgbox "There was an error running option $FUN" 20 60 1
    else
      # quit was selected
      whiptail --yesno "Are you sure you want to quit?" 20 60 2
      if [ $? -eq 0 ]; then exit 1; fi
    fi
  done
}


do_menu_club_cameras() {
  # display menu
  FUN=$(whiptail --title "$WT_TITLE" --backtitle "$WT_COPYRIGHT" --menu "Camera Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT  --cancel-button Back --ok-button Select \
  "C0102" "Cameras over sheets 1 & 2"       \
  "C0304" "Cameras over sheets 3 & 4"       \
  "C0506" "Cameras over sheets 5 & 6"       \
  "C0708" "Cameras over sheets 7 & 8"       \
  "C0910" "Cameras over sheets 9 & 10"      \
  "C1112" "Cameras over sheets 11 & 12"     \
  3>&1 1>&2 2>&3)
  RET=$?

  # process response
  if [ $RET -eq 0 ]; then
    do_write_config
  else
    return 0
  fi
}


do_menu_single_camera() {
  # display menu
  FUN=$(whiptail --title "$WT_TITLE" --backtitle "$WT_COPYRIGHT" --menu "Camera Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT  --cancel-button Back --ok-button Select \
  "S0101" "Camera over sheet 1"       \
  "S0202" "Camera over sheet 2"       \
  "S0303" "Camera over sheet 3"       \
  "S0404" "Camera over sheet 4"       \
  "S0505" "Camera over sheet 5"       \
  "S0606" "Camera over sheet 6"       \
  "S0707" "Camera over sheet 7"       \
  "S0808" "Camera over sheet 8"       \
  "S0909" "Camera over sheet 9"       \
  "S1010" "Camera over sheet 10"      \
  "S1111" "Camera over sheet 11"      \
  "S1212" "Camera over sheet 12"      \
  3>&1 1>&2 2>&3)
  RET=$?

  # process response
  if [ $RET -eq 0 ]; then
    do_write_config
  else
    return 0
  fi
}


do_menu_custom_cameras() {
  SHEET1=$(whiptail --inputbox "Enter bottom sheet:" 10 60 3>&1 1>&2 2>&3)
  SHEET2=$(whiptail --inputbox "Enter top sheet:" 10 60 3>&1 1>&2 2>&3)
  FUN="C${SHEET1}${SHEET2}"
  do_write_config
}


do_menu_kiosks() {
  # display menu
  FUN=$(whiptail --title "$WT_TITLE" --backtitle "$WT_COPYRIGHT" --menu "Kiosk Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT  --cancel-button Back --ok-button Select \
  "K01" "Kiosk Advertising (Upstairs)"    \
  "K02" "Kiosk Practice Ice (Downstairs)" \
  3>&1 1>&2 2>&3)
  RET=$?

  # process response
  if [ $RET -eq 0 ]; then
    do_write_config
  else
    return 0
  fi
}


do_menu_rotation() {
  # display menu
  ROTATION=$(whiptail --title "$WT_TITLE" --backtitle "$WT_COPYRIGHT" --menu "Screen Rotation" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT  --cancel-button Back --ok-button Select \
  "H" "Screen is Horizontal" \
  "V" "Screen is Vertical"   \
  3>&1 1>&2 2>&3)
  RET=$?

  # process response
  if [ $RET -eq 0 ]; then
    whiptail --msgbox "Screen rotation set to '$ROTATION'. Select a display mode to apply and reboot." 20 60
  else
    ROTATION="H"
  fi
}


# --------------------------------------------------------------------------------
#  functions for actions
# --------------------------------------------------------------------------------

# autoupdate from git
do_auto_update() {
  wget https://raw.githubusercontent.com/garjones/pi-kiosk/main/kiosk.service      --no-verbose -O /home/kcckiosk/kiosk.service
  wget https://raw.githubusercontent.com/garjones/pi-kiosk/main/kiosk.run.sh       --no-verbose -O /home/kcckiosk/kiosk.run.sh
  wget https://raw.githubusercontent.com/garjones/pi-kiosk/main/kiosk.env          --no-verbose -O /home/kcckiosk/kiosk.env
  wget https://raw.githubusercontent.com/garjones/pi-kiosk/main/wifi-watchdog.sh   --no-verbose -O /home/kcckiosk/wifi-watchdog.sh
  wget https://raw.githubusercontent.com/garjones/pi-kiosk/main/unclutter.service  --no-verbose -O /home/kcckiosk/unclutter.service
}

# apt
do_apt() {
  sudo apt autoremove -y
  sudo apt update
  sudo apt upgrade -y
  sudo apt install unclutter -y
}

# raspi-config
do_raspi_config() {
  sudo raspi-config
}

# install the kiosk application
do_install () {
  # only create unclutter service if the service doesn't already exist
  if [ ! -e /lib/systemd/system/unclutter.service ]; then
      # create service symlink
      sudo ln -s /home/kcckiosk/unclutter.service /lib/systemd/system/unclutter.service

      # enable the unclutter service
      sudo systemctl enable unclutter.service
  fi

  # only create kiosk service if the service doesn't already exist
  if [ ! -e /lib/systemd/system/kiosk.service ]; then
      # make kiosk.run.sh executable
      chmod u+x /home/kcckiosk/kiosk.run.sh

      # create service symlink
      sudo ln -s /home/kcckiosk/kiosk.service /lib/systemd/system/kiosk.service

      # enable the kiosk service
      sudo systemctl enable kiosk.service
  fi

  # add cron entries - daily reboot at 7am and wifi watchdog every 15 minutes
  (echo "0 7 * * * /sbin/shutdown -r now"; echo "*/15 * * * * /bin/bash /home/kcckiosk/wifi-watchdog.sh") | crontab -

  # enable & start the service
  sudo systemctl enable cron
  sudo systemctl start cron

  # disable desktop environment
  if [ -e /etc/xdg/labwc/autostart ]; then
      sudo mv /etc/xdg/labwc/autostart /etc/xdg/labwc/autostart.disabled
  fi

  # autorun the kiosk configuration on login
  if grep -Fxq '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/garjones/pi-kiosk/main/kiosk.sh)"' /home/kcckiosk/.bashrc; then
      # already exists do nothing
      echo "[Skipped] Kiosk configuration autorun"
  else
      echo "[Done] Kiosk configuration autorun"
      echo '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/garjones/pi-kiosk/main/kiosk.sh)"' >> /home/kcckiosk/.bashrc
  fi
}

# write the configuration file
do_write_config() {
    # check if sure, then write it out and reboot
    whiptail --yesno "Are you sure?" 20 60 2
    if [ $? -eq 0 ]; then # yes
      echo "$ROTATION$FUN" > /home/kcckiosk/kiosk.config
      echo "$ROTATION$FUN"
      sudo sync
      sudo reboot
    fi
}

# reboot
do_reboot() {
  sudo reboot
}

# --------------------------------------------------------------------------------
#  execute
# --------------------------------------------------------------------------------
do_menu_main
