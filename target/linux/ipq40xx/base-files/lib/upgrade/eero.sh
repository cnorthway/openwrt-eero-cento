# Flashes upgrade package using eero's A/B partition scheme
# will leave most recent eero installation alone as a backup
platform_do_upgrade_eero_cento() {
	local tar_file="$1"

	local current_bootcmd
	local current_bootargs
	current_bootcmd=$(fw_printenv -n bootcmd)
	current_bootargs=$(fw_printenv -n bootargs)
	local first_install
	first_install=$(echo "$current_bootcmd" | grep -c "eero_kernel")
	if [ $first_install -eq 1 ]; then
		echo "first installation! backing up important stock env variables"
		fw_setenv -s - <<-EOF
			bootcmd_eero_backup $current_bootcmd
			bootargs_eero_backup $current_bootargs
		EOF
	fi

###
# Determine partitions
###
	local current_bootpart
	local current_rootpart
	current_bootpart=$(echo "$current_bootcmd" | sed -nr 's/.*ext2load mmc 0:([[:digit:]]).*/\1/p')
	current_rootpart=$(echo "$current_bootargs" | sed -nr 's/.*root=\/dev\/mmcblk0p([[:digit:]]).*/\1/p')

	# validate that they're sane; determine inactive partitions
	if [ "$current_bootpart" -eq 1 ] && [ "$current_rootpart" -eq 3 ]; then
		local inactive_bootpart=2
		local inactive_rootpart=4
		echo "currently booting from slot A"
	elif [ "$current_bootpart" -eq 2 ] && [ "$current_rootpart" -eq 4 ]; then
		local inactive_bootpart=1
		local inactive_rootpart=3
		echo "currently booting from slot B"
	else
		echo "invalid boot or root partitions"
		return 1
	fi

	# on the first install, we want to install to the inactive slot
	# (easier to recover to known-good, configured stock OS).
	# on subsequent installs, continue using the active slot to keep
	# the stock install intact.
	if $first_install; then
		local install_bootpart=$inactive_bootpart
		local install_rootpart=$inactive_rootpart
		echo "installing to inactive slot;"
	else
		local install_bootpart=$current_bootpart
		local install_rootpart=$current_rootpart
		echo "installing to currently booted slot;"
	fi
	echo "boot: $install_bootpart"
	echo "root: $install_rootpart"

###
# Install kernel to ext2 part
###
	local board_dir=$(tar tf $tar_file | grep -m 1 '^sysupgrade-.*/$')
	board_dir=${board_dir%/}

	# mount boot partition
	mkdir /mnt/bootpart &&
	mount -t ext2 /dev/mmcblk0p"$install_bootpart" /mnt/bootpart ||
	{ echo "unable to mount boot partition" && return 1 ; }

	# clean it out and install new kernel image
	rm -r /mnt/bootpart/* &&
	mkdir /mnt/bootpart/lost+found &&
	tar Oxf $tar_file ${board_dir}/kernel > /mnt/bootpart/kernel.itb ||
	{ echo "unable to install kernel image" && return 1 ; }

	echo "installed kernel image to /dev/mmcblk0p$install_bootpart"

###
# Install rootfs using emmc_do_upgrade
###
	EMMC_ROOT_DEV=/dev/mmcblk0p"$install_rootpart"
	emmc_do_upgrade $tar_file

	echo "done with emmc_do_upgrade, rootfs should be installed"

###
# Finalize env vars
###
	fw_setenv -s - <<-EOF
		bootcmd ext2load mmc 0:$install_bootpart 0x84000000 kernel.itb && bootm; reset
		bootargs root=/dev/mmcblk0p$install_rootpart rootwait
	EOF

	echo "new boot cmd/args set, install complete!"
}
