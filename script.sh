#!/usr/bin/env -S bash -e

setfont ter-v22b
clear

setenforce 0

timedatectl set-ntp true

echo -e "\nmax_parallel_downloads=10\nfastestmirror=True\ndefaultyes=True\n" >> /etc/dnf/dnf.conf

userinfo () {
# Enter username

read -p "Please enter your username: " username

#Enter password for root & $username
echo -ne "Please enter your password for $username: \n"
read -s password # read password without echo

echo -ne "Please enter your password for root account: \n"
read -s root_password

# Enter hostname
read -rep "Please enter your hostname: " hostname
}

userinfo

clear

timezone () {
# Added this from arch wiki https://wiki.archlinux.org/title/System_time
time_zone="$(curl --fail https://ipapi.co/timezone)"
echo -ne "System detected your timezone to be '$time_zone' \n"
echo -ne "Is this correct? yes/no:" 
read answer
case $answer in
    y|Y|yes|Yes|YES)
    $time_zone;;
    n|N|no|NO|No)
    echo "Please enter your desired timezone e.g. Asia/Kolkata :" 
    read new_timezone;;
    *) echo "Wrong option. Try again";timezone;;
esac
}
timezone
clear

keymap () {
# These are default key maps as presented in official arch repo archinstall
echo -ne "
Please select key board layout from this list
    -by
    -ca
    -cf
    -cz
    -de
    -dk
    -es
    -et
    -fa
    -fi
    -fr
    -gr
    -hu
    -il
    -it
    -lt
    -lv
    -mk
    -nl
    -no
    -pl
    -ro
    -ru
    -sg
    -ua
    -uk
    -us
"
read -p "Your key boards layout:" keymap
}

keymap

clear

# Enter locale
read -r -p "Please insert the locale you use (in this format: en_US): " locale



echo -ne "
-------------------------------------------------------------------------
                          Disk Preparation
-------------------------------------------------------------------------
"

# Selecting the target for the installation.
lsblk -n --output TYPE,KNAME,SIZE | awk '$1=="disk"{print NR,"/dev/"$2" - "$3}'
echo -ne "
------------------------------------------------------------------------
    THIS WILL FORMAT AND DELETE ALL DATA ON THE DISK             
    Please make sure you know what you are doing because         
    after formating your disk there is no way to get data back      
------------------------------------------------------------------------
"
read -p "Please enter full path to disk: (example /dev/sda or /dev/nvme0n1 or /dev/vda): " DISK


# disk prep
echo "Deleting old partition scheme."
read -r -p "This will delete the current partition table on $DISK. Do you agree [y/N]? " response
response=${response,,}
if [[ "$response" =~ ^(yes|y)$ ]]; then
    echo -ne "
    -------------------------------------------------------------------------
                                Formating Disk
    -------------------------------------------------------------------------
    "
    wipefs -af $DISK &>/dev/null
    sgdisk -Zo $DISK &>/dev/null
    sgdisk --zap-all $DISK &>/dev/null
    
    read -r -p "Type Home partition size (example: 400G), remaining partition size will be allocated to the ROOT partition: " home_size
    
    # create partitions
    echo "create partitions"
    sgdisk -n 1:0:+600M ${DISK} # partition 1 (UEFI), default start block, 1024MB
    sgdisk -n 2:0:+1G ${DISK} # partition 2 (UEFI), default start block, 1024MB  
    sgdisk -n 3:0:+${home_size} ${DISK} # partition 3 (Home), default start block, $home_size
    sgdisk -n 4:0:0 ${DISK} # partition 4 (Root), default start block, remaining
    
    # set partition types
    echo "set partition types"
    sgdisk -t 1:ef00 ${DISK}
    sgdisk -t 2:8300 ${DISK}
    sgdisk -t 3:8300 ${DISK}
    sgdisk -t 4:8300 ${DISK}

    # label partitions
    echo "label partitions"
    sgdisk -c 1:"ESP" ${DISK}
    sgdisk -c 2:"BOOT" ${DISK}
    sgdisk -c 3:"HOME" ${DISK}
    sgdisk -c 4:"ROOT" ${DISK}
else
    echo "Quitting."
    exit
fi

# make filesystems
echo -ne "
-------------------------------------------------------------------------
                          Creating Filesystems
-------------------------------------------------------------------------
"
partprobe "$DISK"

if [[ "${DISK}" =~ "nvme" ]]; then
    ESP=${DISK}p1
    BOOT=${DISK}p2
    HOME=${DISK}p3
    ROOT=${DISK}p4
else
    ESP=${DISK}1
    BOOT=${DISK}2
    HOME=${DISK}3
    ROOT=${DISK}4
fi

# Formatting the ESP as FAT32
echo -e "\nFormatting the EFI Partition as FAT32.\n$HR"
mkfs.fat -F 32 -n EFI $ESP &>/dev/null

# Formatting the BOOT as ext4
echo -e "\nFormatting the Boot Partition as ext4.\n$HR"
mkfs.ext4 -F -L EFI $BOOT &>/dev/null

# Formatting the partition as ROOT
echo "Formatting the Root & Home partition as btrfs."
mkfs.btrfs -L "ROOT" -f -n 32k $ROOT &>/dev/null
mkfs.btrfs -L "HOME" -f -n 32k $HOME &>/dev/null

mount -t btrfs $ROOT /mnt

# Creating ROOT subvolumes

echo -ne "
-------------------------------------------------------------------------
                      Creating ROOT subvolumes
-------------------------------------------------------------------------
"
btrfs subvolume create /mnt/@ &>/dev/null
btrfs subvolume create /mnt/@/.snapshots &>/dev/null
mkdir /mnt/@/.snapshots/1 &>/dev/null
btrfs subvolume create /mnt/@/.snapshots/1/snapshot &>/dev/null
mkdir /mnt/@/boot &>/dev/null
btrfs subvolume create /mnt/@/boot/grub &>/dev/null
btrfs subvolume create /mnt/@/tmp &>/dev/null
mkdir /mnt/@/var &>/dev/null
btrfs subvolume create /mnt/@/var/log &>/dev/null
btrfs subvolume create /mnt/@/var/cache &>/dev/null
btrfs subvolume create /mnt/@/var/tmp &>/dev/null
mkdir -p /mnt/@/var/lib/libvirt &>/dev/null
btrfs subvolume create /mnt/@/var/lib/libvirt/images &>/dev/null
btrfs subvolume create /mnt/@/var/lib/machines &>/dev/null

chattr +C /mnt/@/var/log
chattr +C /mnt/@/var/cache
chattr +C /mnt/@/var/tmp
chattr +C /mnt/@/var/lib/libvirt/images
chattr +C /mnt/@/var/lib/machines

#Set the default ROOT Subvol to Snapshot 1 before pacstrapping
echo "Set the default ROOT Subvol to Snapshot 1 before pacstrapping"
btrfs subvolume set-default "$(btrfs subvolume list /mnt | grep "@/.snapshots/1/snapshot" | grep -oP '(?<=ID )[0-9]+')" /mnt

DATE=`date +"%Y-%m-%d %H:%M:%S"`

cat << EOF >> /mnt/@/.snapshots/1/info.xml
<?xml version="1.0"?>
<snapshot>
  <type>single</type>
  <num>1</num>
  <date>$DATE</date>
  <description>First Root Filesystem</description>
  <cleanup>number</cleanup>
</snapshot>
EOF

chmod 600 /mnt/@/.snapshots/1/info.xml

# Mounting the newly created subvolumes
umount /mnt

echo -ne "
-------------------------------------------------------------------------
                Mounting the newly created subvolumes
-------------------------------------------------------------------------
"
mount -o lazytime,relatime,compress=zstd,space_cache=v2,ssd $ROOT /mnt
mkdir -p /mnt/{boot/grub,home,.snapshots,tmp,/var/log,/var/cache,/var/tmp,/var/lib/libvirt/images,/var/lib/machines}
mount -o lazytime,relatime,compress=zstd,space_cache=v2,ssd $HOME /mnt/home
mount -o lazytime,relatime,compress=zstd,space_cache=v2,autodefrag,ssd,discard=async,nodev,nosuid,noexec,subvol=@/boot/grub $ROOT /mnt/boot/grub
mount -o lazytime,relatime,compress=zstd,space_cache=v2,autodefrag,ssd,discard=async,subvol=@/.snapshots $ROOT /mnt/.snapshots
mount -o lazytime,relatime,compress=zstd,space_cache=v2,autodefrag,ssd,discard=async,subvol=@/tmp $ROOT /mnt/tmp
mount -o lazytime,relatime,compress=zstd,space_cache=v2,autodefrag,ssd,discard=async,nodatacow,nodev,nosuid,noexec,subvol=@/var/log $ROOT /mnt/var/log
mount -o lazytime,relatime,compress=zstd,space_cache=v2,autodefrag,ssd,discard=async,nodatacow,nodev,nosuid,noexec,subvol=@/var/cache $ROOT /mnt/var/cache
mount -o lazytime,relatime,compress=zstd,space_cache=v2,autodefrag,ssd,discard=async,nodatacow,nodev,nosuid,subvol=@/var/tmp $ROOT /mnt/var/tmp
mount -o lazytime,relatime,compress=zstd,space_cache=v2,autodefrag,ssd,discard=async,nodatacow,nodev,nosuid,noexec,subvol=@/var/lib/libvirt/images $ROOT /mnt/var/lib/libvirt/images
mount -o lazytime,relatime,compress=zstd,space_cache=v2,autodefrag,ssd,discard=async,nodatacow,nodev,nosuid,noexec,subvol=@/var/lib/machines $ROOT /mnt/var/lib/machines

mount -o nodev,nosuid,noexec $BOOT /mnt/boot
mkdir -p /mnt/boot/efi

mount -o nodev,nosuid,noexec $ESP /mnt/boot/efi

udevadm trigger

mkdir -p /mnt/{proc,sys,dev/pts}
mount -t proc proc /mnt/proc
mount -t sysfs sys /mnt/sys
mount -B /dev /mnt/dev
mount -t devpts pts /mnt/dev/pts


source /etc/os-release
export VERSION_ID="$VERSION_ID"

echo "Install Fedora Core"
dnf --installroot=/mnt --releasever=$VERSION_ID groupinstall -y core

echo "Install glibc-langpack-en"
dnf --installroot=/mnt install -y glibc-langpack-en

mv /mnt/etc/resolv.conf /mnt/etc/resolv.conf.orig
cp -L /etc/resolv.conf /mnt/etc

echo "Install arch-install-scripts"
dnf install -y arch-install-scripts

echo -e "# Booting with ROOT subvolume\nGRUB_ROOT_OVERRIDE_BOOT_PARTITION_DETECTION=true" >> /mnt/etc/default/grub
sed -i 's#rootflags=subvol=${rootsubvol}##g' /mnt/etc/grub.d/10_linux
sed -i 's#rootflags=subvol=${rootsubvol}##g' /mnt/etc/grub.d/20_linux_xen

# Disable su for non-wheel users
echo "Disable su for non-wheel users"
bash -c 'cat > /mnt/etc/pam.d/su' <<-'EOF'
#%PAM-1.0
auth		sufficient	pam_rootok.so
# Uncomment the following line to implicitly trust users in the "wheel" group.
#auth		sufficient	pam_wheel.so trust use_uid
# Uncomment the following line to require a user to be in the "wheel" group.
auth		required	pam_wheel.so use_uid
auth		required	pam_unix.so
account		required	pam_unix.so
session		required	pam_unix.so
EOF

# Randomize Mac Address
echo "Randomize Mac Address"
bash -c 'cat > /mnt/etc/NetworkManager/conf.d/00-macrandomize.conf' <<-'EOF'
[device]
wifi.scan-rand-mac-address=yes
[connection]
wifi.cloned-mac-address=random
ethernet.cloned-mac-address=random
connection.stable-id=${CONNECTION}/${BOOT}
EOF

chmod 600 /mnt/etc/NetworkManager/conf.d/00-macrandomize.conf

# Disable Connectivity Check.
echo "Disable Connectivity Check"
bash -c 'cat > /mnt/etc/NetworkManager/conf.d/20-connectivity.conf' <<-'EOF'
[connectivity]
uri=http://www.archlinux.org/check_network_status.txt
interval=0
EOF

chmod 600 /mnt/etc/NetworkManager/conf.d/20-connectivity.conf


# Disable NetworkManager Wait Service (due to long boot times). You might want to ignore this if you are a laptop user.
sudo systemctl disable NetworkManager-wait-online.service

echo "Generate fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# Setting hostname
echo -ne "
-------------------------------------------------------------------------
                     	 Setting hostname
-------------------------------------------------------------------------
"
echo "$hostname" > /mnt/etc/hostname

# Setting hosts file
echo "Setting hosts file."
cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain   $hostname
EOF

# Setting up locales
echo "Setting up locales"
echo "$locale.UTF-8 UTF-8"  > /mnt/etc/locale.gen
echo "LANG=$locale.UTF-8" > /mnt/etc/locale.conf

# Setting up keyboard layout.
echo "Setting up keyboard layout"
echo "KEYMAP=$keymap" > /mnt/etc/vconsole.conf

echo -e "# Booting with ROOT subvolume\nGRUB_ROOT_OVERRIDE_BOOT_PARTITION_DETECTION=true" >> /mnt/etc/default/grub
sed -i 's#rootflags=subvol=${rootsubvol}##g' /mnt/etc/grub.d/10_linux
sed -i 's#rootflags=subvol=${rootsubvol}##g' /mnt/etc/grub.d/20_linux_xen

# Remove /dev/zram0 partition from /mnt/etc/fstab

echo "Chroot"
chroot /mnt /bin/bash -e <<EOF

  mount -a

  mount -t efivarfs efivarfs /sys/firmware/efi/efivars
  fixfiles -F onboot
  echo "Install grub packages"
  dnf install -y btrfs-progs efi-filesystem efibootmgr fwupd grub2-common grub2-efi-ia32 grub2-efi-x64 grub2-pc grub2-pc-modules grub2-tools grub2-tools-efi grub2-tools-extra grub2-tools-minimal grubby kernel mactel-boot mokutil shim-ia32 shim-x64 snapper
  
  # Setting up timezone
  echo "Setting up timezone"
  ln -sf /usr/share/zoneinfo/$time_zone /etc/localtime &>/dev/null
  
  # Snapper configuration
  echo "Configuring Snapper"
  umount /.snapshots
  rm -r /.snapshots
  snapper --no-dbus -c root create-config /
  btrfs subvolume delete /.snapshots
  mkdir /.snapshots
  mount -a
  chmod 750 /.snapshots
  
  rm -f /etc/localtime
  
  echo "Set shutdown timeout"
  sed -i 's/.*DefaultTimeoutStopSec=.*$/DefaultTimeoutStopSec=5s/g' /etc/systemd/system.conf
  
  echo -ne "
  -------------------------------------------------------------------------
                      Setting root & user password
  -------------------------------------------------------------------------
  "
   
  # Giving wheel user sudo access
  echo -e "$root_password\n$root_password" | passwd root
  usermod -aG wheel root
  useradd -m $username
  usermod -aG wheel $username
  #gpasswd -a $username libvirt
  #usermod -aG libvirt -s /bin/bash $username
  usermod -a -G wheel "$username" && mkdir -p /home/"$username" && chown "$username":wheel /home/"$username"
  echo -e "$password\n$password" | passwd $username
  groupadd -r audit
  usermod -aG audit $username
  gpasswd -a $username audit
  sed -i 's/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/g' /etc/sudoers
  echo "$username ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
  chown $username:$username /home/$username
  
  echo -e "\n#GTK_USE_PORTAL=1\n" >> /etc/environment
  # Enabling audit service
  echo "Enabling audit service"
  systemctl enable auditd &>/dev/null

  # Enabling auto-trimming service
  echo "Enabling auto-trimming service"
  systemctl enable fstrim.timer &>/dev/null

  # Enabling NetworkManager
  echo "Enabling NetworkManager"
  systemctl enable NetworkManager &>/dev/null
  systemctl enable systemd-resolved &>/dev/nul
    
  # Setting umask to 077
  sed -i 's/022/077/g' /etc/profile
  echo "" >> /etc/bash.bashrc
  echo "umask 077" >> /etc/bash.bashrc
  echo "Setting umask to 077 - Done"
    
  # Enabling systemd-oomd
  systemctl enable systemd-oomd &>/dev/null
  echo "Enabled systemd-oomd."
  
  echo "install dnf-plugins-core"
  sudo dnf -y install dnf-plugins-core
  sudo dnf config-manager \
      --add-repo \
      		https://download.docker.com/linux/fedora/docker-ce.repo
    
  sudo dnf install docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo systemctl start docker
    
  # Install third-party repositories (Via RPMFusion).
  sudo dnf install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm -y
  sudo dnf group update core -y

  # Enable Flatpaks.
  sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo && sudo flatpak remote-add --if-not-exists flathub-beta https://flathub.org/beta-repo/flathub-beta.flatpakrepo

  # Enable System Theming with Flatpak (That way, theming is more consistent between native apps and flatpaks).
  sudo flatpak override --filesystem=xdg-config/gtk-3.0
  
  # Install fastfetch.
  sudo dnf install fastfetch -y
  mkdir ~/.config/fastfetch

  # Set up fastfetch with my preferred configuration.
  wget -O ~/.config/fastfetch/config.conf https://github.com/KingKrouch/Fedora-InstallScripts/raw/main/.config/fastfetch/config.conf
  wget -O ~/.config/fastfetch/uoh.ascii https://github.com/KingKrouch/Fedora-InstallScripts/raw/main/.config/fastfetch/uoh.ascii

  # Install exa and lsd, which should replace lsd and dir. Also install thefuck for terminal command corrections, and fzf.
  sudo dnf install exa lsd thefuck fzf htop cmatrix -y

  # Install zsh, alongside setting up oh-my-zsh, and powerlevel10k.
  sudo dnf install zsh -y && chsh -s $(which zsh) && sudo chsh -s $(which zsh)
  sudo dnf install git git-lfs -y && sh -c "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)"c
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k
  wget -O ~/.p10k.zsh https://github.com/KingKrouch/Fedora-InstallScripts/raw/main/p10k.zsh

  # Set up Powerlevel10k as the default zsh theme, alongside enabling some tweaks.
  sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="powerlevel10k/powerlevel10k"/g' ~/.zshrc
  echo "# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
  [[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh" >> tee -a ~/.zshrc
  echo "typeset -g POWERLEVEL9K_INSTANT_PROMPT=off" >> tee -a ~/.zshrc

  # Set up some ZSH plugins
  git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
  git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
  sed -i 's/plugins=(git)/plugins=(git emoji zsh-syntax-highlighting zsh-autosuggestions)/g' ~/.zshrc

  ## Add nerd-fonts for Noto and SourceCodePro font families. This will just install everything together, but I give no fucks at this point, just want things a little easier to set up.
  git clone https://github.com/ryanoasis/nerd-fonts.git && cd nerd-fonts && ./install.sh && cd .. && sudo rm -rf nerd-fonts

  # Append exa and lsd aliases, and neofetch alias to both the bashrc and zshrc.
  echo "if [ -x /usr/bin/lsd ]; then
    alias ls='lsd'
    alias dir='lsd -l'
    alias lah='lsd -lah'
    alias lt='lsd --tree'
  fi" >> tee -a ~/.bashrc ~/.zshrc
  echo "eval $(thefuck --alias)
  eval $(thefuck --alias fix) # Allows triggering thefuck using the keyword 'fix'." >> tee -a ~/.bashrc ~/.zshrc
  echo "alias neofetch='fastfetch'
  neofetch" >> tee -a ~/.bashrc ~/.zshrc
  
  #echo "systemd-firstboot"
  #systemd-firstboot --prompt

  
EOF

 echo "Remove default grub packages"
 rm /mnt/boot/efi/EFI/fedora/grub.cfg -f
 rm /mnt/boot/grub2/grub.cfg -f
  
 echo "Reinstall grub packages"
 dnf reinstall -y shim-* grub2-efi-* grub2-common

 bash -c "cat > /mnt/etc/default/grub" <<-'EOF'
 GRUB_TIMEOUT=5
 GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"
 GRUB_DEFAULT=saved
 GRUB_DISABLE_SUBMENU=true
 GRUB_TERMINAL_OUTPUT="console"
 GRUB_CMDLINE_LINUX="rhgb"
 GRUB_DISABLE_RECOVERY="true"
 GRUB_ENABLE_BLSCFG=true
 EOF


 #efibootmgr -c -d $DISK -p 1 -L "Fedora (Custom)" -l \\EFI\\FEDORA\\SHIMX64.EFI

 grub2-mkconfig -o /mnt/boot/grub2/grub.cfg
