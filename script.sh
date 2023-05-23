#!/usr/bin/env -S bash -e

setfont ter-v22b
clear

setenforce 0

timedatectl set-ntp true

echo -e "\nmax_parallel_downloads=10\nfastestmirror=True\ndefaultyes=True\n" >> /etc/dnf/dnf.conf




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
# Deleting old partition scheme.
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
    sgdisk -n 1:0:+600M ${DISK} # partition 1 (UEFI), default start block, 1024MB
    sgdisk -n 2:0:+1G ${DISK} # partition 2 (UEFI), default start block, 1024MB  
    sgdisk -n 3:0:+${home_size} ${DISK} # partition 3 (Home), default start block, $home_size
    sgdisk -n 4:0:0 ${DISK} # partition 4 (Root), default start block, remaining
    
    # set partition types
    sgdisk -t 1:ef00 ${DISK}
    sgdisk -t 2:8300 ${DISK}
    sgdisk -t 3:8300 ${DISK}
    sgdisk -t 4:8300 ${DISK}

    # label partitions
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


