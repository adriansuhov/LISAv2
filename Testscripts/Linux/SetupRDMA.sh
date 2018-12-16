#!/bin/bash
#
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
# This script will set up RDMA over IB environment.
# To run this script following things are must.
# 1. constants.sh
# 2. All VMs in cluster have infiniband hardware.
# 3. This script should run for MPI setup prior to running MPI testing. 
# 	mpi_type: ibm, open, intel
########################################################################################################
# Source utils.sh
. utils.sh || {
	echo "Error: unable to source utils.sh!"
	echo "TestAborted" >state.txt
	exit 0
}

# Source constants file and initialize most common variables
UtilsInit

# Constants/Globals
HOMEDIR="/root"
# constants.sh has all information required
CONSTANTS_FILE="$HOMEDIR/constants.sh"

# Get distro information
GetDistro
Debug_Msg "Found distro name: $DISTRO"

# debug msg flag; 1 generates /tmp/debug.log
debug=1

# functions
function Debug_Msg {
	if [ $debug -eq 1 ]; then
		echo
		echo "******** DEBUG ********" $1
		echo $1 >> /tmp/debug.log
		echo
	fi
}

function Verify_File {
	# Verify if the file exists or not. 
	# The first parameter is absolute path
	if [ -e $1 ]; then
		Debug_Msg "File found $1"
	else
		Debug_Msg "File not found $1"
	fi
}

function Found_File {
	# The first parameter is file name, the second parameter is filtering
	target_path=$(find / -name $1 | grep $2)
	if [ -n $target_path ]; then
		Debug_Msg "Verified $1 binary in $target_path successfully"
	else
		Debug_Msg "Could not verify $1 binary in the system"
	fi
}

function Verify_Result {
	if [ $? -eq 0 ]; then
		Debug_Msg "OK"
	else
		Debug_Msg "FAIL"
fi
}

function Main() {
	Debug_Msg "Starting RDMA required packages and software setup in VM"

	# identify VM from constants file
	if [ -e ${CONSTANTS_FILE} ]; then
		source ${CONSTANTS_FILE}
		Debug_Msg "Sourced constants.sh file"
	else
		error_message="missing ${CONSTANTS_FILE} file"
		LogErr "${error_message}"
		SetTestStateFailed
		exit 1
	fi

	case $DISTRO in
		redhat_7|centos_7)
			# install required packages regardless VM types.
			Debug_Msg "This is RHEL or CentOS"
			Debug_Msg "Installing required packages ..."
			yum install -y kernel-devel-3.10.0-862.9.1.el7.x86_64 python-devel valgrind-devel
			Verify_Result
			Debug_Msg "Installed packages - kernel-devel-3.10.0-862.9.1.el7.x86_64 python-devel valgrind-devel"
			yum install -y redhat-rpm-config rpm-build gcc-gfortran libdb-devel gcc-c++
			Verify_Result
			Debug_Msg "Installed packages - redhat-rpm-config rpm-build gcc-gfortran libdb-devel gcc-c++"
			yum install -y glibc-devel zlib-devel numactl-devel libmnl-devel binutils-devel
			Verify_Result
			Debug_Msg "Installed packages - glibc-devel zlib-devel numactl-devel libmnl-devel binutils-devel"
			yum install -y iptables-devel libstdc++-devel libselinux-devel gcc elfutils-devel
			Verify_Result
			Debug_Msg "Installed packages - iptables-devel libstdc++-devel libselinux-devel gcc elfutils-devel"
			yum install -y libtool libnl3-devel git java libstdc++.i686 dapl python-setuptools
			Verify_Result
			Debug_Msg "Installed packages - libtool libnl3-devel git java libstdc++.i686 dapl python-setuptools"
			yum -y groupinstall "InfiniBand Support"
			Verify_Result
			Debug_Msg "Installed group packages for InfiniBand Support"
			yum -y install gtk2 atk cairo tcl tk createrepo
			Verify_Result
			Debug_Msg "Installed gtk2 atk cairo tcl tk createrepo"
			# this is required for specific MLX driver installation 
			yum -y install kernel-devel-3.10.0-862.11.6.el7.x86_64
			Verify_Result
			Debug_Msg "Installed kernel-devel-3.10.0-862.11.6.el7.x86_64"

			Debug_Msg "Completed the required packages installation"

			Debug_Msg "Enabling rdma service"
			systemctl enable rdma
			Verify_Result
			Debug_Msg "Enabled rdma service"

			# This is required for new HPC VM HB- and HC- size deployment, Dec/2018
			cd

			Debug_Msg "Downloading MLX driver"
			wget http://content.mellanox.com/ofed/MLNX_OFED-4.5-1.0.1.0/MLNX_OFED_LINUX-4.5-1.0.1.0-rhel7.5-x86_64.tgz
			Verify_Result
			Debug_Msg "Downloaded MLNX_OFED_LINUX-4.5-1.0.1.0-rhel7.5-x86_64.tgz"

			Debug_Msg "Opening MLX OFED driver tar ball file"
			tar zxvf MLNX_OFED_LINUX-4.5-1.0.1.0-rhel7.5-x86_64.tgz
			Verify_Result
			Debug_Msg "Untar MLX driver tar ball file"
			
			Debug_Msg "Installing MLX OFED driver"
			./MLNX_OFED_LINUX-4.5-1.0.1.0-rhel7.5-x86_64/mlnxofedinstall --add-kernel-support
			Verify_Result
			Debug_Msg "Installed MLX OFED driver with kernel support modules"

			# Restart IB driver after enabling the eIPoIB Driver
			Debug_Msg "Changing LOAD_EIPOIB to yes"
			sed -i -e 's/LOAD_EIPOIB=no/LOAD_EIPOIB=yes/g' /etc/infiniband/openib.conf
			Verify_Result
			Debug_Msg "Configured openib.conf file"

			Debug_Msg "Unloading ib_isert rpcrdma ib_Srpt services"
			modprobe -rv ib_isert rpcrdma ib_srpt
			Verify_Result
			Debug_Msg "Removed ib_isert rpcrdma ib_srpt services"

			Debug_Msg "Restarting openibd service"
			/etc/init.d/openibd restart
			Verify_Result
			Debug_Msg "Restarted Open IB Driver"

			# remove or disable firewall and selinux services, if needed
			Debug_Msg "Disabling Firewall and SELinux services"
			systemctl stop iptables.service
			systemctl disable iptables.service
			systemctl mask firewalld
			systemctl stop firewalld.service
			Verify_Result
			systemctl disable firewalld.service 
			Verify_Result
			iptables -nL
			Verify_Result
			sed -i -e 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
			Verify_Result
			Debug_Msg "Completed RHEL Firewall and SELinux disabling"

			# enable OS.EnableRDMA=y in waagent.conf
			Debug_Msg "Changing waagent conf file"
			sed -i -e 's/# OS.EnableRDMA=y/OS.EnableRDMA=y/g' /etc/waagent.conf ### TODO find the bug.
			Debug_Msg "Restarting waagent service"
			service waagent restart
			;;
		suse*)
			# install required packages
			Debug_Msg "This is SUSE"
			Debug_Msg "Installing required packages ..."
			zypper install -y glibc-32bit glibc-devel libgcc_s1 libgcc_s1-32bit make gcc gcc-c++ gcc-fortran
			Verify_Result
			Debug_Msg "Installed packages - glibc-32bit glibc-devel libgcc_s1 libgcc_s1-32bit make gcc gcc-c++ gcc-fortran"
			zypper install -y net-tools-deprecated
			Verify_Result
			Debug_Msg "Installed packages - net-tools-deprecated"
			;;
			# Need to find alternative MLX driver package installation
		*)
			msg="ERROR: Distro '$DISTRO' not supported or not implemented"
			LogMsg "${msg}"
			SetTestStateFailed
			exit 0
			;;
	esac

	Debug_Msg "Proceeding to MPI installation"

	# install MPI packages
	if [ $mpi_type == "ibm" ]; then
		Debug_Msg "IBM Platform MPI installation running ..."
		srcblob=https://partnerpipelineshare.blob.core.windows.net/mpi/platform_mpi-09.01.04.03r-ce.bin

		#IBM platform MPI installation
		cd ~
		Debug_Msg "Downloading bin file"
		wget $srcblob
		Verify_Result
		Debug_Msg "Downloaded IBM Platform MPI bin file"
		Debug_Msg "$(ls)"
		chmod +x $HOMEDIR/$(echo $srcblob | cut -d'/' -f5)
		Verify_Result
		Debug_Msg "Added the execution mode to BIN file"

		# create a temp file for key stroke event handle
		keystrok_filename=$HOMEDIR/ibm_keystroke
		Debug_Msg "Building keystrok event file for IBM Platform MPI silent installation"
		echo '\n' > $keystrok_filename
		echo 1 >> /$keystrok_filename
		echo /opt/ibm/platform_mpi/ >> $keystrok_filename
		echo Y >> $keystrok_filename
		echo '\n' >> $keystrok_filename
		echo '\n' >> $keystrok_filename
		echo '\n' >> $keystrok_filename
		echo '\n' >> $keystrok_filename
		Debug_Msg "$(cat $keystrok_filename)"

		Debug_Msg "Executing silient installation"
		cat ibm_keystroke | $HOMEDIR/$(echo $srcblob | cut -d'/' -f5)
		Verify_Result
		Debug_Msg "Completed IBM Platform MPI installation"

		#Find the correct partition key for IB communicating with other VM
		firstkey=$(cat /sys/class/infiniband/mlx5_0/ports/1/pkeys/0)
		Debug_Msg "Getting the first key $firstkey"
		secondkey=$(cat /sys/class/infiniband/mlx5_0/ports/1/pkeys/1)
		Debug_Msg "Getting the second key $secondkey"

		# Assign the bigger number to MPI_IB_PKEY
		if [ $((firstkey - secondkey)) -gt 0 ]; then 
			export MPI_IB_PKEY=$firstkey
			echo "MPI_IB_PKEY=$firstkey" >> constants.sh
		else
			export MPI_IB_PKEY=$secondkey
			echo "MPI_IB_PKEY=$secondkey" >> constants.sh
		fi
		Debug_Msg "Setting MPI_IB_PKEY to $MPI_IB_PKEY and copying it into constants.sh file"

		# set path string to verify IBM MPI binaries
		target_bin=/opt/ibm/platform_mpi/bin/mpirun
		ping_pong_help=/opt/ibm/platform_mpi/help
		ping_pong_bin=/opt/ibm/platform_mpi/help/ping_pong

		# file validation
		Verify_File $target_bin

		# compile ping_pong
		cd $ping_pong_help
		Debug_Msg "Compiling ping_pong binary in Platform help directory"
		make
		Verify_Result
		Debug_Msg "Ping-pong compilation completed"

		# verify ping_pong binary
		Verify_File $ping_pong_bin

		# add IBM Platform MPI path to PATH
		export PATH=$PATH:/opt/ibm/platform_mpi/bin

		# Install stable WALA agent and apply 3 patches
		# This is customized part for RHEL 7.5 Standard_HB60rs
		cd

		Debug_Msg "Download WALA agent repo"
		git clone https://github.com/Azure/WALinuxAgent.git
		Verify_Result

		cd WALinuxAgent
		
		Debug_Msg "Download 1365.patch"
		wget https://patch-diff.githubusercontent.com/raw/Azure/WALinuxAgent/pull/1365.patch
		Verify_Result
		
		Debug_Msg "Download 1375.patch"
		wget https://patch-diff.githubusercontent.com/raw/Azure/WALinuxAgent/pull/1375.patch
		Verify_Result
		
		Debug_Msg "Download 1389.patch"
		wget https://patch-diff.githubusercontent.com/raw/Azure/WALinuxAgent/pull/1389.patch
		Verify_Result
		
		Debug_Msg "Reset to commit 72b643ea93e5258c3cec0e778017936806111f15"
		git reset --hard 72b643ea93e5258c3cec0e778017936806111f15
		Verify_Result

		Debug_Msg "Apply 1365 patch"
		git am 1365.patch
		Verify_Result
		
		Debug_Msg "Apply 1375 patch"
		git am 1375.patch
		Verify_Result
		
		Debug_Msg "Apply 1389 patch"
		git am 1389.patch
		Verify_Result
		
		Debug_Msg "Eanble EnableRDMA parameter in waagent.config"
		sed -i -e 's/# OS.EnableRDMA=y/OS.EnableRDMA=y/g' config/waagent.conf
		Verify_Result

		Debug_Msg "Disable AutoUpdate parameter in waagent.config"
		sed -i -e 's/AutoUpdate.Enabled=y/# AutoUpdate.Enabled=y/g' config/waagent.conf
		Verify_Result
		
		Debug_Msg "Compile WALA"
		python setup.py install --register-service  --force
		Verify_Result

		Debug_Msg "Restart waagent service"
		service waagent restart
		Verify_Result

	elif [ $mpi_type == "intel" ]; then
		# if HPC images comes with MPI binary pre-installed, (CentOS HPC) 
		#	there is no action required except binay verification
		mpirun_path=$(find / -name mpirun | grep intel64)		# $mpirun_path is not empty or null and file path should exists
		if [[ -f $mpirun_path && ! -z "$mpirun_path" ]]; then
			Debug_Msg "Found pre-installed mpirun binary"

			# mostly IMB-MPI1 comes with mpirun binary, but verify its existence
			Found_File "IMB-MPI1" "intel64"
		# if this is HPC images with MPI installer rpm files, (SUSE HPC)
		#	then it sould be install those rpm files
		elif [ -d /opt/intelMPI ]; then
			Debug_Msg "Found intelMPI directory. This has an installable rpm ready image"
			Debug_Msg "Installing all rpm files in /opt/intelMPI/intel_mpi_packages/"

			rpm -v -i --nodeps /opt/intelMPI/intel_mpi_packages/*.rpm
			Verify_Result

			mpirun_path=$(find / -name mpirun | grep intel64)

			Found_File "mpirun" "intel64"
			Found_File "IMB-MPI1" "intel64"
		else
			# none HPC image case, need to install Intel MPI
			# Intel MPI installation of tarball file
			Debug_Msg="Intel MPI installation running ..."
			srcblob=https://partnerpipelineshare.blob.core.windows.net/mpi/l_mpi_2018.3.222.tgz

			Debug_Msg "Downloading Intel MPI source code"
			wget $srcblob

			tar xvzf $(echo $srcblob | cut -d'/' -f5)
			cd $(echo "${srcblob%.*}" | cut -d'/' -f5)

			Debug_Msg "Executing silient installation"
			sed -i -e 's/ACCEPT_EULA=decline/ACCEPT_EULA=accept/g' silent.cfg 
			./install.sh -s silent.cfg
			Verify_Result
			Debug_Msg "Completed Intel MPI installation"

			mpirun_path=$(find / -name mpirun | grep intel64)

			Found_File "mpirun" "intel64"
			Found_File "IMB-MPI1" "intel64"
		fi

		# file validation
		Verify_File $mpirun_path

		# add Intel MPI path to PATH
		export PATH=$PATH:"${mpirun_path%/*}"

	else 
		# Open MPI installation
		Debug_Msg "Open MPI installation running ..."
		srcblob=https://partnerpipelineshare.blob.core.windows.net/mpi/openmpi-3.1.2.tar.gz

		Debug_Msg "Downloading the target openmpi source code"
		wget $srcblob
		Verify_Result

		tar xvzf $(echo $srcblob | cut -d'/' -f5)
		cd $(echo "${srcblob%.*}" | cut -d'/' -f5 | sed -n '/\.tar$/s///p')

		Debug_Msg "Running configuration"
		./configure --enable-mpirun-prefix-by-default
		Verify_Result

		Debug_Msg "Compiling Open MPI"
		make
		Verify_Result

		Debug_Msg "Installing new binaries in /usr/local/bin directory"
		make install
		Verify_Result

		Debug_Msg "Reloading config"
		ldconfig
		Verify_Result

		Debug_Msg "Adding default installed path to system path"
		export PATH=$PATH:/usr/local/bin

		# set path string to verify IBM MPI binaries
		target_bin=/usr/local/bin/mpirun

		# file validation
		Verify_File $target_bin
	fi
	
	cd ~
	
	Debug_Msg "Proceeding Intel MPI Benchmark test installation"

	# install Intel MPI benchmark package
	cd ~
	Debug_Msg "Cloning mpi-benchmarks repo"
	git clone https://github.com/intel/mpi-benchmarks
	Verify_Result
	Debug_Msg "Cloned Intel MPI Benchmark gitHub repo"
	cd mpi-benchmarks/src_c
	Debug_Msg "Building Intel MPI Benchmarks tests"
	make
	Debug_Msg "Completed Intel MPI Benchmarks"
	Verify_Result
	Debug_Msg "Intel Benchmark test installation completed"

	# set string to verify Intel Benchmark binary
	benchmark_bin=$HOMEDIR/mpi-benchmarks/src_c/IMB-MPI1

	# verify benchmark binary
	Verify_File $benchmark_bin

	Debug_Msg "Main function completed"
}

function post_verification() {
	# Assumption: all paths are default setting
	Debug_Msg "Post_verification starting"

	# Validate if the platform MPI binaries work in the system.
	_hostname=$(cat /etc/hostname)
	_ipaddress=$(hostname -i | awk '{print $1}')
	Debug_Msg "Found hostname from system - $_hostname"
	Debug_Msg "Found _ipaddress from system - $_ipaddress"

	# MPI hostname cmd for initial test
	if [ $mpi_type == "ibm" ]; then
		_res_hostname=$(/opt/ibm/platform_mpi/bin/mpirun -TCP -hostlist $_ipaddress:1 hostname)
	elif [ $mpi_type == "intel" ]; then
		_res_hostname=$(mpirun --host $_ipaddress hostname)
	else
		_res_hostname=$(mpirun --allow-run-as-root -np 1 --host $_ipaddress hostname)
	fi
	Debug_Msg "_res_hostname $_res_hostname"

	if [ $_hostname = $_res_hostname ]; then
		Debug_Msg "PASSED: Verified hostname from MPI successfully"
		echo "Found hostname matching from system info"
	else 
		Debug_Msg "FAILED: Verification of hostname failed."
	fi

	# MPI ping_pong cmd for initial test
	if [ $mpi_type == "ibm" ]; then
		Debug_Msg "Running ping_pong testing ..."
		_res_pingpong=$(/opt/ibm/platform_mpi/bin/mpirun -TCP -hostlist $_ipaddress:1,$_ipaddress:1 /opt/ibm/platform_mpi/help/ping_pong 4096)
		Debug_Msg "_res_pingpong $_res_pingpong"

		_res_tx=$(echo $_res_pingpong | cut -d' ' -f7)
		_res_rx=$(echo $_res_pingpong | cut -d' ' -f11)
		Debug_Msg "_res_tx $_res_tx"
		Debug_Msg "_res_rx $_res_rx"

		if [[ "$_res_tx" != "0" && "$_res_rx" != "0" ]]; then
			Debug_Msg "PASSED: Found non-zero value in self ping_pong test"
		else
			Debug_Msg "FAILED: Found zero ping_pong test result"
		fi

	elif [ $mpi_type == "intel" ]; then
		Debug_Msg "TBD: This is intel MPI and no verification defined yet"
	else
		Debug_Msg "TBD: This is Open MPI and no verification defined yet"
	fi
	Debug_Msg "Post_verification completed"
}

# main body
Main
post_verification $mpi_type