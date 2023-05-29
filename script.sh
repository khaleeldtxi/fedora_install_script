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
  
  echo "Remove default grub packages"
  rm /boot/efi/EFI/fedora/grub.cfg -f
  rm /boot/grub2/grub.cfg -f
  
  echo "Reinstall grub packages"
  dnf reinstall -y shim-* grub2-efi-* grub2-common

  bash -c 'cat > /etc/default/grub' <<-'EOF'
  GRUB_TIMEOUT=5
  GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"
  GRUB_DEFAULT=saved
  GRUB_DISABLE_SUBMENU=true
  GRUB_TERMINAL_OUTPUT="console"
  GRUB_CMDLINE_LINUX="rhgb"
  GRUB_DISABLE_RECOVERY="true"
  GRUB_ENABLE_BLSCFG=true
  EOF

  efibootmgr -c -d $DISK -p 1 -L "Fedora (Custom)" -l \\EFI\\FEDORA\\SHIMX64.EFI

  grub2-mkconfig -o /boot/grub2/grub.cfg

  rm -f /etc/localtime
  
  echo "Set shutdown timeout"
  sed -i 's/.*DefaultTimeoutStopSec=.*$/DefaultTimeoutStopSec=5s/g' /etc/systemd/system.conf
  
  echo "systemd-firstboot"
  systemd-firstboot --prompt

  passwd

EOF
