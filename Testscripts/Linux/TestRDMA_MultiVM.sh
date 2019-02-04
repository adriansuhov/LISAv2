#!/bin/bash
#
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
# This script will run Infiniband test.
# To run this script following things are must.
# 1. constants.sh
# 2. passwordless authentication is setup in all VMs in current cluster.
# 3. All VMs in cluster have infiniband hardware.
# 4. Intel MPI binaries are installed in VM. If not, download and install trial version from :
#    https://software.intel.com/en-us/intel-mpi-library
# 5. VHD is prepared for Infiniband tests.

########################################################################################################
# Source utils.sh
. utils.sh || {
	echo "Error: unable to source utils.sh!"
	echo "TestAborted" >state.txt
	exit 0
}

# Source constants file and initialize most common variables
UtilsInit

HOMEDIR="/root"
#
# Constants/Globals
#
CONSTANTS_FILE="$HOMEDIR/constants.sh"

imb_mpi1_final_status=0
imb_rma_final_status=0
imb_nbc_final_status=0

# Get all the Kernel-Logs from all VMs.
function Collect_Kernel_Logs_From_All_VMs() {
	slaves_array=$(echo ${slaves} | tr ',' ' ')
	for vm in $master $slaves_array; do
		LogMsg "Getting kernel logs from $vm"
		ssh root@${vm} "dmesg > kernel-logs-${vm}.txt"
		scp root@${vm}:kernel-logs-${vm}.txt .
		if [ $? -eq 0 ]; then
			LogMsg "Kernel Logs collected successfully from ${vm}."
		else
			LogErr "Failed to collect kernel logs from ${vm}."
		fi
	done
}

# Compress the same pattern files to compressed_file_name
function Compress_Files() {
	compressed_file_name=$1
	pattern=$2
	LogMsg "Compressing ${pattern} files into ${compressed_file_name}"
	tar -cvzf temp-${compressed_file_name} ${pattern}*
	if [ $? -eq 0 ]; then
		mv temp-${compressed_file_name} ${compressed_file_name}
		LogMsg "${pattern}* files compresssed successfully."
		LogMsg "Deleting local copies of ${pattern}* files"
		rm -rvf ${pattern}*
	else
		LogErr "Failed to compress files."
		LogMsg "Don't worry. Your files are still here."
	fi
}

if [ -e ${CONSTANTS_FILE} ]; then
	source ${CONSTANTS_FILE}
else
	error_message="missing ${CONSTANTS_FILE} file"
	LogErr "${error_message}"
	SetTestStateFailed
	exit 1
fi

function Main() { 
	LogMsg "Starting $mpi_type MPI tests..."

	# ############################################################################################################
	# This is common space for all three types of MPI testing
	# Verify if ib_nic got IP address on All VMs in current cluster.
	# ib_nic comes from constants.sh. where get those values from XML tags.
	final_ib_nic_status=0
	total_virtual_machines=0
	err_virtual_machines=0
	slaves_array=$(echo ${slaves} | tr ',' ' ')
	nbc_benchmarks="Ibcast Iallgather Iallgatherv Igather Igatherv Iscatter Iscatterv Ialltoall Ialltoallv Ireduce Ireduce_scatter Iallreduce Ibarrier"

	for vm in $master $slaves_array; do
		LogMsg "Checking $ib_nic status in $vm"
		# Verify ib_nic exists or not.
		temp=$(ssh root@${vm} "ifconfig $ib_nic | grep 'inet '")
		ib_nic_status=$?
		ssh root@${vm} "ifconfig $ib_nic > $ib_nic-status-${vm}.txt"
		scp root@${vm}:${ib_nic}-status-${vm}.txt .
		if [ $ib_nic_status -eq 0 ]; then
			# Verify ib_nic has IP address, which means IB setup is ready
			LogMsg "${ib_nic} IP detected for ${vm}."
		else
			# Verify no IP address on ib_nic, which means IB setup is not ready
			LogErr "${ib_nic} failed to get IP address for ${vm}."
			err_virtual_machines=$(($err_virtual_machines+1))
		fi
		final_ib_nic_status=$(($final_ib_nic_status + $ib_nic_status))
		total_virtual_machines=$(($total_virtual_machines + 1))
	done

	if [ $final_ib_nic_status -ne 0 ]; then
		LogErr "$err_virtual_machines VMs out of $total_virtual_machines did get IP address for $ib_nic. Aborting Tests"
		SetTestStateFailed
		Collect_Kernel_Logs_From_All_VMs
		LogErr "INFINIBAND_VERIFICATION_FAILED_${ib_nic}"
		exit 0
	else
		# Verify all VM have ib_nic available for further testing
		LogMsg "INFINIBAND_VERIFICATION_SUCCESS_${ib_nic}"
		# Removing controller VM from total_virtual_machines count
		total_virtual_machines=$(($total_virtual_machines - 1))
	fi

	# ############################################################################################################
	# ib kernel modules verfication
	# mlx5_ib, rdma_cm, rdma_ucm, ib_ipoib shall be loaded in kernel
	final_module_load_status=0
	kernel_modules="mlx5_ib rdma_cm rdma_ucm ib_ipoib"

	for vm in $master $slaves_array; do
		LogMsg "Checking kernel modules in $vm"
			for k_mod in $kernel_modules; do
				temp=$(ssh root@${vm} "lsmod | grep $k_mod")
				k_mod_status=$?
				if [ $k_mod_status -eq 0 ]; then
					# Verify ib kernel module is loaded in the system
					LogMsg "${k_mod} module is loaded in ${vm}."
				else
					# Verify ib kernel module is not loaded in the system
					LogErr "${k_mod} module is not loaded in ${vm}."
					err_virtual_machines=$(($err_virtual_machines+1))
				fi
				final_module_load_status=$(($final_module_load_status + $k_mod_status))
			done
	done

	if [ $final_module_load_status -ne 0 ]; then
		LogErr "$err_virtual_machines VMs out of $total_virtual_machines did not load kernel modules successfully. Aborting Tests"
		SetTestStateFailed
		Collect_Kernel_Logs_From_All_VMs
		LogErr "INFINIBAND_VERIFICATION_FAILED_${kernel_modules}"
		exit 0
	else
		# Verify all VM have ib_nic available for further testing
		LogMsg "INFINIBAND_VERIFICATION_SUCCESS_${kernel_modules}"
	fi

	# ############################################################################################################
	# ibv_devinfo verifies PORT STATE
	# PORT_ACTIVE (4) is expected. If PORT_DOWN (1), it fails
	ib_port_state_down_cnt=0
	min_port_state_up_cnt=0
	for vm in $master $slaves_array; do
		min_port_state_up_cnt=$(($min_port_state_up_cnt + 1))
		ssh root@${vm} "ibv_devinfo > /root/IMB-PORT_STATE_${vm}"
		port_state=$(ssh root@${vm} "ibv_devinfo | grep -i state")
		port_state=$(echo $port_state | cut -d ' ' -f2)
		if [ "$port_state" == "PORT_ACTIVE" ]; then 
			LogMsg "$vm ib port is up - Succeeded; $port_state"
		else
			LogErr "$vm ib port is down; $port_state"
			LogErr "Will remove the VM with bad port from constants.sh"
			sed -i "s/${vm},\|,${vm}//g" ${CONSTANTS_FILE}
			ib_port_state_down_cnt=$(($ib_port_state_down_cnt + 1))
		fi
	done
	min_port_state_up_cnt=$((min_port_state_up_cnt / 2))
	# If half of the VMs (or more) are affected, the test will be failed
	if [ $ib_port_state_down_cnt -ge $min_port_state_up_cnt ]; then
		LogErr "IMB-MPI1 ib port state check failed in $ib_port_state_down_cnt VMs. Aborting further tests."
		SetTestStateFailed
		Collect_Kernel_Logs_From_All_VMs
		LogMsg "INFINIBAND_VERIFICATION_FAILED_MPI1_PORTSTATE"
		exit 0
	else
		LogMsg "INFINIBAND_VERIFICATION_SUCCESS_MPI1_PORTSTATE"
	fi
	# Refresh slave array and total_virtual_machines
	if [ $ib_port_state_down_cnt -gt 0 ]; then
		. ${CONSTANTS_FILE}
		slaves_array=$(echo ${slaves} | tr ',' ' ')
		total_virtual_machines=$(($total_virtual_machines - $ib_port_state_down_cnt))
		ib_port_state_down_cnt=0
	fi
	
	# ############################################################################################################
	# Verify if SetupRDMA completed all steps or not
	# IF completed successfully, constants.sh has setup_completed=0 
	setup_state_cnt=0
	for vm in $master $slaves_array; do
		setup_result=$(ssh root@${vm} "cat /root/constants.sh | grep -i setup_completed")
		setup_result=$(echo $setup_result | cut -d '=' -f 2)
		if [ "$setup_result" == "0" ]; then 
			LogMsg "$vm RDMA setup - Succeeded; $setup_result"
		else
			LogErr "$vm RDMA setup - Failed; $setup_result"
			setup_state_cnt=$(($setup_state_cnt + 1))
		fi 
	done
	
	if [ $setup_state_cnt -ne 0 ]; then
		LogErr "IMB-MPI1 SetupRDMA state check failed in $setup_state_cnt VMs. Aborting further tests."
		SetTestStateFailed
		Collect_Kernel_Logs_From_All_VMs
		LogMsg "INFINIBAND_VERIFICATION_FAILED_MPI1_SETUPSTATE"
		exit 0
	else
		LogMsg "INFINIBAND_VERIFICATION_SUCCESS_MPI1_SETUPSTATE"
	fi

	# ############################################################################################################
	# Remove bad node from the testing. There is known issue about Limit_UAR issue in mellanox driver.
	# Scanning dmesg to find ALLOC_UAR, and remove those bad node out of $slaves_array
	alloc_uar_limited_cnt=0

	echo $slaves_array > /root/tmp_slaves_array.txt

	for vm in $slaves_array; do
		ssh root@$i 'dmesg | grep ALLOC_UAR' > /dev/null 2>&1;
		
		if [ "$?" == "0" ]; then 
			LogErr "$vm RDMA state reach to limit of ALLOC_UAR - Failed and removed from target slaves."
			sed -i 's/$vm//g' /root/tmp_slaves_array.txt
			alloc_uar_limited_cnt=$(($alloc_uar_limited_cnt + 1))
		else
			LogMsg "$vm RDMA state verified healthy - Succeeded."
		fi 
	done
	# Refresh $slaves_array with healthy node
	slaves_array=$(cat /root/tmp_slaves_array.txt)

	# ############################################################################################################
	# Verify ibv_rc_pingpong, ibv_uc_pingpong and ibv_ud_pingpong and rping.
	final_pingpong_state=0

	# Define ibv_ pingpong commands in the array
	declare -a ping_cmds=("ibv_rc_pingpong" "ibv_uc_pingpong" "ibv_ud_pingpong")

	for ping_cmd in "${ping_cmds[@]}"; do
		for vm1 in $master $slaves_array; do
			for vm2 in $slaves_array $master; do
				if [[ "$vm1" == "$vm2" ]]; then
					# Skip self-ping test case
					break
				fi
				# Define pingpong test log file name
				log_file=IMB-"$ping_cmd"-output-$vm1-$vm2.txt
				LogMsg "Run $ping_cmd from $vm2 to $vm1"
				LogMsg "  Start $ping_cmd in server VM $vm1 first"
				retries=0
				while [ $retries -lt 3 ]; do
					ssh root@${vm1} "$ping_cmd" &
					sleep 1
					LogMsg "  Start $ping_cmd in client VM $vm2"
					ssh root@${vm2} "$ping_cmd $vm1 > /root/$log_file"
					pingpong_state=$?

					sleep 1
					scp root@${vm2}:/root/$log_file .
					pingpong_result=$(cat $log_file | grep -i Mbit | cut -d ' ' -f7)
					if [ $pingpong_state -eq 0 ] && [ $pingpong_result > 0 ]; then
						LogMsg "$ping_cmd test execution successful"
						LogMsg "$ping_cmd result $pingpong_result in $vm1-$vm2 - Succeeded."
						retries=4
					else
						sleep 10
						let retries=retries+1
					fi
				done
				if [ $pingpong_state -ne 0 ] || (($(echo "$pingpong_result <= 0" | bc -l))); then
					LogErr "$ping_cmd test execution failed"
					LogErr "$ping_cmd result $pingpong_result in $vm1-$vm2 - Failed"
					final_pingpong_state=$(($final_pingpong_state + 1))
				fi
			done
		done
	done

	if [ $final_pingpong_state -ne 0 ]; then
		LogErr "ibv_ping_pong test failed in somes VMs. Aborting further tests."
		SetTestStateFailed
		Collect_Kernel_Logs_From_All_VMs
		LogErr "INFINIBAND_VERIFICATION_FAILED_IBV_PINGPONG"
		exit 0
	else
		LogMsg "INFINIBAND_VERIFICATION_SUCCESS_IBV_PINGPONG"
	fi
	
	## Verify Intel MPI Tests
	non_shm_mpi_settings=$(echo $mpi_settings | sed 's/shm://')

	if [[ $mpi_type == "intel" ]]; then
		# ############################################################################################################
		mpi_run_path=$(find / -name mpirun | grep intel64)
		LogMsg "MPIRUN Path: $mpi_run_path"
		
		imb_mpi1_path=$(find / -name IMB-MPI1 | grep intel64)
		LogMsg "IMB-MPI1 Path: $imb_mpi1_path"
		
		imb_rma_path=$(find / -name IMB-RMA | grep intel64)
		LogMsg "IMB-RMA Path: $imb_rma_path"
		
		imb_nbc_path=$(find / -name IMB-NBC | grep intel64)
		LogMsg "IMB-NBC Path: $imb_nbc_path"

		# Verify Intel MPI PingPong Tests (IntraNode).
		final_mpi_intranode_status=0

		for vm1 in $master $slaves_array; do
			# Manual running needs to clean up the old log files.
			if [ -f ./IMB-MPI1-IntraNode-output-$vm1.txt ]; then
				rm -f ./IMB-MPI1-IntraNode-output-$vm1*.txt
				LogMsg "Removed the old log files"
			fi
			for vm2 in $master $slaves_array; do
				log_file=IMB-MPI1-IntraNode-output-$vm1-$vm2.txt
				LogMsg "$mpi_run_path -hosts $vm1,$vm2 -ppn 2 -n 2 $non_shm_mpi_settings $imb_mpi1_path pingpong"
				LogMsg "Checking IMB-MPI1 IntraNode status in $vm1"
				retries=0
				while [ $retries -lt 3 ]; do
					ssh root@${vm1} "$mpi_run_path -hosts $vm1,$vm2 -ppn 2 -n 2 $non_shm_mpi_settings $imb_mpi1_path pingpong \
						>> $log_file"
					mpi_intranode_status=$?
					scp root@${vm1}:$log_file .
					if [ $mpi_intranode_status -eq 0 ]; then
						LogMsg "IMB-MPI1 IntraNode status in $vm1 - Succeeded."
						retries=4
					else
						sleep 10
						let retries=retries+1
					fi
				done
				if [ $mpi_intranode_status -ne 0 ]; then
					LogErr "IMB-MPI1 IntraNode status in $vm1 - Failed"
					final_mpi_intranode_status=$(($final_mpi_intranode_status + $mpi_intranode_status))
				fi
			done
		done

		if [ $final_mpi_intranode_status -ne 0 ]; then
			LogErr "IMB-MPI1 Intranode test failed in somes VMs. Aborting further tests."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogErr "INFINIBAND_VERIFICATION_FAILED_MPI1_INTRANODE"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_MPI1_INTRANODE"
		fi

		# Verify Intel MPI IMB-MPI1 (pingpong & allreduce etc) tests.
		total_attempts=$(seq 1 1 $imb_mpi1_tests_iterations)
		modified_slaves=${slaves//,/:$VM_Size,}
		imb_mpi1_final_status=0
		for attempt in $total_attempts; do
			if [[ $imb_mpi1_tests == "all" ]]; then
				LogMsg "$mpi_run_path -hosts $master,$modified_slaves -ppn $mpi1_ppn -n $(($VM_Size * $total_virtual_machines)) $mpi_settings $imb_mpi1_path"
				LogMsg "IMB-MPI1 test iteration $attempt - Running."
				$mpi_run_path -hosts $master,$modified_slaves -ppn $mpi1_ppn -n $(($VM_Size * $total_virtual_machines)) $mpi_settings $imb_mpi1_path \
					>IMB-MPI1-AllNodes-output-Attempt-${attempt}.txt
				mpi_status=$?
			else
				LogMsg "$mpi_run_path -hosts $master,$modified_slaves -ppn $mpi1_ppn -n $(($VM_Size * $total_virtual_machines)) $mpi_settings $imb_mpi1_path $imb_mpi1_tests"
				LogMsg "IMB-MPI1 test iteration $attempt - Running."
				$mpi_run_path -hosts $master,$modified_slaves -ppn $mpi1_ppn -n $(($VM_Size * $total_virtual_machines)) $mpi_settings $imb_mpi1_path $imb_mpi1_tests \
					>IMB-MPI1-AllNodes-output-Attempt-${attempt}.txt
				mpi_status=$?
			fi
			if [ $mpi_status -eq 0 ]; then
				LogMsg "IMB-MPI1 test iteration $attempt - Succeeded."
				sleep 1
			else
				LogErr "IMB-MPI1 test iteration $attempt - Failed."
				imb_mpi1_final_status=$(($imb_mpi1_final_status + $mpi_status))
				sleep 1
			fi
		done

		if [ $imb_mpi1_tests_iterations -gt 5 ]; then
			Compress_Files "IMB-MPI1-AllNodes-output.tar.gz" "IMB-MPI1-AllNodes-output-Attempt"
		fi

		if [ $imb_mpi1_final_status -ne 0 ]; then
			LogErr "IMB-MPI1 tests returned non-zero exit code."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogErr "INFINIBAND_VERIFICATION_FAILED_MPI1_ALLNODES"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_MPI1_ALLNODES"

		fi

		# Verify Intel MPI IMB-RMA tests.
		total_attempts=$(seq 1 1 $imb_rma_tests_iterations)
		imb_rma_final_status=0
		for attempt in $total_attempts; do
			if [[ $imb_rma_tests == "all" ]]; then
				LogMsg "$mpi_run_path -hosts $master,$modified_slaves -ppn $rma_ppn -n $(($VM_Size * $total_virtual_machines)) $mpi_settings $imb_rma_path"
				LogMsg "IMB-RMA test iteration $attempt - Running."
				$mpi_run_path -hosts $master,$modified_slaves -ppn $rma_ppn -n $(($VM_Size * $total_virtual_machines)) $mpi_settings $imb_rma_path \
					>IMB-RMA-AllNodes-output-Attempt-${attempt}.txt
				rma_status=$?
			else
				LogMsg "$mpi_run_path -hosts $master,$modified_slaves -ppn $rma_ppn -n $(($VM_Size * $total_virtual_machines)) $mpi_settings $imb_rma_path $imb_rma_tests"
				LogMsg "IMB-RMA test iteration $attempt - Running."
				$mpi_run_path -hosts $master,$modified_slaves -ppn $rma_ppn -n $(($VM_Size * $total_virtual_machines)) $mpi_settings $imb_rma_path $imb_rma_tests \
					>IMB-RMA-AllNodes-output-Attempt-${attempt}.txt
				rma_status=$?
			fi
			if [ $rma_status -eq 0 ]; then
				LogMsg "IMB-RMA test iteration $attempt - Succeeded."
				sleep 1
			else
				LogErr "IMB-RMA test iteration $attempt - Failed."
				imb_rma_final_status=$(($imb_rma_final_status + $rma_status))
				sleep 1
			fi
		done

		if [ $imb_rma_tests_iterations -gt 5 ]; then
			Compress_Files "IMB-RMA-AllNodes-output.tar.gz" "IMB-RMA-AllNodes-output-Attempt"
		fi

		if [ $imb_rma_final_status -ne 0 ]; then
			LogErr "IMB-RMA tests returned non-zero exit code. Aborting further tests."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogErr "INFINIBAND_VERIFICATION_FAILED_RMA_ALLNODES"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_RMA_ALLNODES"
		fi

		# Verify Intel MPI IMB-NBC tests.
		total_attempts=$(seq 1 1 $imb_nbc_tests_iterations)
		imb_nbc_final_status=0
		for attempt in $total_attempts; do
			retries=0
			while [ $retries -lt 3 ]; do
				if [[ $imb_nbc_tests == "all" ]]; then
					LogMsg "$mpi_run_path -hosts $master,$modified_slaves -ppn $nbc_ppn -n $(($VM_Size * $total_virtual_machines)) $mpi_settings $imb_nbc_path"
					LogMsg "IMB-NBC test iteration $attempt - Running."
					$mpi_run_path -hosts $master,$modified_slaves -ppn $nbc_ppn -n $(($VM_Size * $total_virtual_machines)) $mpi_settings $imb_nbc_path \
						>IMB-NBC-AllNodes-output-Attempt-${attempt}.txt
					nbc_status=$?
				else
					LogMsg "$mpi_run_path -hosts $master,$modified_slaves -ppn $nbc_ppn -n $(($VM_Size * $total_virtual_machines)) $mpi_settings $imb_nbc_path $imb_nbc_tests"
					LogMsg "IMB-NBC test iteration $attempt - Running."
					$mpi_run_path -hosts $master,$modified_slaves -ppn $nbc_ppn -n $(($VM_Size * $total_virtual_machines)) $mpi_settings $imb_nbc_path $imb_nbc_tests \
						>IMB-NBC-AllNodes-output-Attempt-${attempt}.txt
					nbc_status=$?
				fi
				if [ $nbc_status -eq 0 ]; then
					LogMsg "IMB-NBC test iteration $attempt - Succeeded."
					sleep 1
					retries=4
				else
					sleep 10
					let retries=retries+1
					failed_nbc=$(cat IMB-NBC-AllNodes-output-Attempt-${attempt}.txt | grep Benchmarking | tail -1| awk '{print $NF}')
					nbc_benchmarks=$(echo $nbc_benchmarks | sed "s/^.*${failed_nbc}//")
					imb_nbc_tests=$nbc_benchmarks
				fi
			done
			if [ $nbc_status -eq 0 ]; then
				LogMsg "IMB-NBC test iteration $attempt - Succeeded."
				sleep 1
			else
				LogErr "IMB-NBC test iteration $attempt - Failed."
				imb_nbc_final_status=$(($imb_nbc_final_status + $nbc_status))
				sleep 1
			fi
		done

		if [ $imb_nbc_tests_iterations -gt 5 ]; then
			  Compress_Files "IMB-NBC-AllNodes-output.tar.gz" "IMB-NBC-AllNodes-output-Attempt"
		fi

		if [ $imb_nbc_final_status -ne 0 ]; then
			LogErr "IMB-NBC tests returned non-zero exit code. Aborting further tests."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogErr "INFINIBAND_VERIFICATION_FAILED_NBC_ALLNODES"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_NBC_ALLNODES"
		fi

		Collect_Kernel_Logs_From_All_VMs

		finalStatus=$(($final_ib_nic_status + $ib_port_state_down_cnt + $alloc_uar_limited_cnt + $final_mpi_intranode_status + $imb_mpi1_final_status + $imb_rma_final_status + $imb_nbc_final_status))

		if [ $finalStatus -ne 0 ]; then
			LogMsg "${ib_nic}_status: $final_ib_nic_status"
			LogMsg "ib_port_state_down_cnt: $ib_port_state_down_cnt"
			LogMsg "alloc_uar_limited_cnt: $alloc_uar_limited_cnt"
			LogMsg "final_mpi_intranode_status: $final_mpi_intranode_status"
			LogMsg "imb_mpi1_final_status: $imb_mpi1_final_status"
			LogMsg "imb_rma_final_status: $imb_rma_final_status"
			LogMsg "imb_nbc_final_status: $imb_nbc_final_status"			
			LogErr "INFINIBAND_VERIFICATION_FAILED"
			SetTestStateFailed
		else
			LogMsg "INFINIBAND_VERIFIED_SUCCESSFULLY"
			SetTestStateCompleted
		fi

	elif [[ $mpi_type == "ibm" ]]; then
		# ############################################################################################################
		# Search mpirun and benchmark testing files
		# mpirun -n <P> IMB-<component> [argement], where <P> is the number of processes. P=1 is recommended for 
		#				all I/O and message passing benchmarks except the single transfer ones.
		#				, where <component> is the component-specific suffix that can take MPI1, 
		#				EXT, IO, NBC, and RMA values.

		# mpirun binary location
		mpi_run_path=$(find / -name mpirun | grep -i ibm | grep -v ia)
		LogMsg "MPIRUN Path: $mpi_run_path"
		
		# IMB-MPI1 location
		imb_mpi1_path=$(find / -name IMB-MPI1 | head -n 1)
		LogMsg "IMB-MPI1 Path: $imb_mpi1_path"
		
		# IMB-RMA location
		imb_rma_path=$(find / -name IMB-RMA | head -n 1)
		LogMsg "IMB-RMA Path: $imb_rma_path"
		
		# IMB-NBC location
		imb_nbc_path=$(find / -name IMB-NBC | head -n 1)
		LogMsg "IMB-NBC Path: $imb_nbc_path"

		# ping_pong binary in help directory
		imb_ping_pong_path=$(find / -name ping_pong)
		LogMsg "MPI ping_pong Path: $imb_ping_pong_path"

		# MPI-1
		# Verify IBM PingPong Tests (IntraNode).
		final_mpi_intranode_status=0

		# Ping_Pong test runs from all to all VM and find the bad node.
		for vm1 in $master $slaves_array; do
			# Manual running needs to clean up the old log files.
			if [ -f ./IMB-MPI1-IntraNode-output-$vm1.txt ]; then
				rm -f ./IMB-MPI1-IntraNode-output-$vm1*.txt
				LogMsg "Removed the old log files"
			fi
			for vm2 in $master $slaves_array; do
				log_file=IMB-MPI1-IntraNode-output-$vm1-$vm2.txt
				LogMsg "$mpi_run_path -hostlist $vm1:1,$vm2:1 -np 2 -e MPI_IB_PKEY=$MPI_IB_PKEY -ibv $imb_ping_pong_path 4096"
				LogMsg "Checking IMB-MPI1 IntraNode status in $vm1"
				retries=0
				while [ $retries -lt 3 ]; do
					ssh root@${vm1} "$mpi_run_path -hostlist $vm1:1,$vm2:1 -np 2 -e MPI_IB_PKEY=$MPI_IB_PKEY -ibv $imb_ping_pong_path 4096 >> $log_file"
					mpi_intranode_status=$?
					scp root@${vm1}:$log_file .
					if [ $mpi_intranode_status -eq 0 ]; then
						LogMsg "IMB-MPI1 IntraNode status in $vm1 - Succeeded."
						retries=4
					else
						sleep 10
						let retries=retries+1
					fi
				done
				if [ $mpi_intranode_status -ne 0 ]; then
					LogErr "IMB-MPI1 IntraNode status in $vm1 - Failed"
					final_mpi_intranode_status=$(($final_mpi_intranode_status + $mpi_intranode_status))
				fi
			done
		done

		if [ $final_mpi_intranode_status -ne 0 ]; then
			LogErr "IMB-MPI1 Intranode ping_pong test failed in somes VMs. Aborting further tests."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogMsg "INFINIBAND_VERIFICATION_FAILED_MPI1_INTRANODE"
			exit 0
		else
			LogErr "INFINIBAND_VERIFICATION_SUCCESS_MPI1_INTRANODE"
		fi

		# Verify IBM IMB-MPI1 tests.
		total_attempts=$(seq 1 1 $imb_mpi1_tests_iterations)
		imb_mpi1_final_status=0
		modified_slaves=${slaves//,/:$VM_Size,}

		for attempt in $total_attempts; do
			LogMsg "$mpi_run_path -hostlist $modified_slaves:$VM_Size -np $(($VM_Size * $total_virtual_machines)) -e MPI_IB_PKEY=$MPI_IB_PKEY $imb_mpi1_path allreduce"
			LogMsg "IMB-MPI1 test iteration $attempt - Running."
			$mpi_run_path -hostlist $modified_slaves:$VM_Size -np $(($VM_Size * $total_virtual_machines)) -e MPI_IB_PKEY=$MPI_IB_PKEY $imb_mpi1_path allreduce \
				> IMB-MPI1-AllNodes-output-Attempt-${attempt}.txt
			mpi_status=$?
			
			if [ $mpi_status -eq 0 ]; then
				LogMsg "IMB-MPI1 test iteration $attempt - Succeeded."
				sleep 1
			else
				LogErr "IMB-MPI1 test iteration $attempt - Failed."
				imb_mpi1_final_status=$(($imb_mpi1_final_status + $mpi_status))
				sleep 1
			fi
		done

		if [ $imb_mpi1_tests_iterations -gt 5 ]; then
			Compress_Files "IMB-MPI1-AllNodes-output.tar.gz" "IMB-MPI1-AllNodes-output-Attempt"
		fi

		if [ $imb_mpi1_final_status -ne 0 ]; then
			LogErr "IMB-MPI1 tests returned non-zero exit code."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogErr "INFINIBAND_VERIFICATION_FAILED_MPI1_ALLNODES"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_MPI1_ALLNODES"

		fi

		# TODO: Add MPI-2
		# IMB-EXT
		# IMB-IO Blocking
		# IMB-IO Nonblocking

		# MPI-3
		# Verify IBM IMB-RMA tests 
		# Remote memory access (RMA) benchmarks use the passive target communication mode 
		#	- measure one-sided operations compliant with the MPI-3 standard
		# TODO: Long Li said IMB-RMA may not work with IBM Platform MPI. Comment out for future work.
		#    error: "MPI_Win_create: One-Sided Communication is not turned on"
		#
		# total_attempts=$(seq 1 1 $imb_rma_tests_iterations)
		imb_rma_final_status=0
		# for attempt in $total_attempts; do
		# 	LogMsg "$mpi_run_path -hostlist $master,$slaves -np $(($rma_ppn * $total_virtual_machines))	$imb_rma_path $imb_rma_tests"
		# 	LogMsg "IMB-RMA test iteration $attempt - Running."
		# 	$mpi_run_path -hostlist $master,$slaves -np $(($rma_ppn * $total_virtual_machines)) $imb_rma_path $imb_rma_tests \
		# 		> IMB-RMA-AllNodes-output-Attempt-${attempt}.txt
		# 
		# 	rma_status=$?
		# 
		# 	if [ $rma_status -eq 0 ]; then
		# 		LogMsg "IMB-RMA test iteration $attempt - Succeeded."
		# 		sleep 1
		# 	else
		# 		LogErr "IMB-RMA test iteration $attempt - Failed."
		# 		imb_rma_final_status=$(($imb_rma_final_status + $rma_status))
		# 		sleep 1
		# 	fi
		# done
		# 
		# if [ $imb_rma_tests_iterations -gt 5 ]; then
		# 	Compress_Files "IMB-RMA-AllNodes-output.tar.gz" "IMB-RMA-AllNodes-output-Attempt"
		# fi
		# 
		# if [ $imb_rma_final_status -ne 0 ]; then
		# 	LogErr "IMB-RMA tests returned non-zero exit code. Aborting further tests."
		# 	SetTestStateFailed
		# 	Collect_Kernel_Logs_From_All_VMs
		# 	LogErr "INFINIBAND_VERIFICATION_FAILED_RMA_ALLNODES"
		# 	exit 0
		# else
		# 	LogMsg "INFINIBAND_VERIFICATION_SUCCESS_RMA_ALLNODES"
		# fi
		# 
		# Verify IBM IMB-NBC tests.
		# Nonblocking collective (NBC) routines conform to 2 MPI-3 standards:
		#	- measuring the overlap of communication and computation
		# 	- measuring pure communication time

		# DEMO only. This if statement should not check in
		total_attempts=$(seq 1 1 $imb_nbc_tests_iterations)
		imb_nbc_final_status=0
		for attempt in $total_attempts; do
			retries=0
			while [ $retries -lt 3 ]; do
				LogMsg "$mpi_run_path -hostlist $modified_slaves:$VM_Size -np $(($VM_Size * $total_virtual_machines)) -e MPI_IB_PKEY=$MPI_IB_PKEY $imb_nbc_path $imb_nbc_tests"
				LogMsg "IMB-NBC test iteration $attempt - Running."
				$mpi_run_path -hostlist $modified_slaves:$VM_Size -np $(($VM_Size * $total_virtual_machines)) -e MPI_IB_PKEY=$MPI_IB_PKEY $imb_nbc_path $imb_nbc_tests \
					> IMB-NBC-AllNodes-output-Attempt-${attempt}.txt
				nbc_status=$?
			
				if [ $nbc_status -eq 0 ]; then
					LogMsg "IMB-NBC test iteration $attempt - Succeeded."
					sleep 1
					retries=4
				else
					sleep 10
					let retries=retries+1
					failed_nbc=$(cat IMB-NBC-AllNodes-output-Attempt-${attempt}.txt | grep Benchmarking | tail -1| awk '{print $NF}')
					nbc_benchmarks=$(echo $nbc_benchmarks | sed "s/^.*${failed_nbc}//")
					imb_nbc_tests=$nbc_benchmarks
				fi
			done
			if [ $nbc_status -eq 0 ]; then
				LogMsg "IMB-NBC test iteration $attempt - Succeeded."
				sleep 1
			else
				LogErr "IMB-NBC test iteration $attempt - Failed."
				imb_nbc_final_status=$(($imb_nbc_final_status + $nbc_status))
				sleep 1
			fi
		done

		if [ $imb_nbc_tests_iterations -gt 5 ]; then
			Compress_Files "IMB-NBC-AllNodes-output.tar.gz" "IMB-NBC-AllNodes-output-Attempt"
		fi

		if [ $imb_nbc_final_status -ne 0 ]; then
			LogErr "IMB-NBC tests returned non-zero exit code. Aborting further tests."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogErr "INFINIBAND_VERIFICATION_FAILED_NBC_ALLNODES"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_NBC_ALLNODES"
		fi

		Collect_Kernel_Logs_From_All_VMs

		finalStatus=$(($final_ib_nic_status + $ib_port_state_down_cnt + $alloc_uar_limited_cnt + $final_mpi_intranode_status + $imb_mpi1_final_status + $imb_nbc_final_status))
		
		if [ $finalStatus -ne 0 ]; then
			LogMsg "${ib_nic}_status: $final_ib_nic_status"
			LogMsg "ib_port_state_down_cnt: $ib_port_state_down_cnt"
			LogMsg "alloc_uar_limited_cnt: $alloc_uar_limited_cnt"
			LogMsg "final_mpi_intranode_status: $final_mpi_intranode_status"
			LogMsg "imb_mpi1_final_status: $imb_mpi1_final_status"
			# LogMsg "imb_rma_final_status: $imb_rma_final_status"
			LogMsg "imb_nbc_final_status: $imb_nbc_final_status"
			LogErr "INFINIBAND_VERIFICATION_FAILED"
			SetTestStateFailed
		else
			LogMsg "INFINIBAND_VERIFIED_SUCCESSFULLY"
			SetTestStateCompleted
		fi

	elif [ $mpi_type == "open" ]; then
		# ############################################################################################################
		# OPEN MPI execution
		# Need exclusive word intel if it runs in HPC image. Both will conflict.
		mpi_run_path=$(find / -name mpirun | head -n 1)
		LogMsg "MPIRUN Path: $mpi_run_path"
		
		imb_mpi1_path=$(find / -name IMB-MPI1 | head -n 1)
		LogMsg "IMB-MPI1 Path: $imb_mpi1_path"
		
		imb_rma_path=$(find / -name IMB-RMA | head -n 1)
		LogMsg "IMB-RMA Path: $imb_rma_path"
		
		imb_nbc_path=$(find / -name IMB-NBC | head -n 1)
		LogMsg "IMB-NBC Path: $imb_nbc_path"

		#Verify PingPong Tests (IntraNode).
		final_mpi_intranode_status=0

		for vm1 in $master $slaves_array; do
			# Manual running needs to clean up the old log files.
			if [ -f ./IMB-MPI1-IntraNode-output-$vm1.txt ]; then
				rm -f ./IMB-MPI1-IntraNode-output-$vm1*.txt
				LogMsg "Removed the old log files"
			fi
			for vm2 in $master $slaves_array; do
				log_file=IMB-MPI1-IntraNode-output-$vm1-$vm2.txt
				LogMsg "$mpi_run_path --allow-run-as-root $non_shm_mpi_settings -np 2 --host $vm1,$vm2 $imb_mpi1_path pingpong"
				LogMsg "Checking IMB-MPI1 IntraNode status in $vm1"
				retries=0
				while [ $retries -lt 3 ]; do
					ssh root@${vm1} "$mpi_run_path --allow-run-as-root $non_shm_mpi_settings -np 2 --host $vm1,$vm2 $imb_mpi1_path pingpong \
						>> $log_file"
					mpi_intranode_status=$?

					scp root@${vm1}:$log_file .
					if [ $mpi_intranode_status -eq 0 ]; then
						LogMsg "IMB-MPI1 IntraNode status in $vm1 - Succeeded."
						retries=4
					else
						sleep 10
						let retries=retries+1
					fi
				done
				if [ $mpi_intranode_status -ne 0 ]; then
					LogErr "IMB-MPI1 IntraNode status in $vm1 - Failed"
					final_mpi_intranode_status=$(($final_mpi_intranode_status + $mpi_intranode_status))
				fi
			done
		done
		if [ $final_mpi_intranode_status -ne 0 ]; then
			LogErr "IMB-MPI1 Intranode ping_pong test failed in somes VMs. Aborting further tests."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogMsg "INFINIBAND_VERIFICATION_FAILED_MPI1_INTRANODE"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_MPI1_INTRANODE"
		fi

		#Verify IMB-MPI1 (pingpong & allreduce etc) tests.
		total_virtual_machines=$(($total_virtual_machines + 1))
		total_attempts=$(seq 1 1 $imb_mpi1_tests_iterations)
		imb_mpi1_final_status=0
		for attempt in $total_attempts; do
			if [[ $imb_mpi1_tests == "all" ]]; then
				LogMsg "$mpi_run_path --allow-run-as-root --host $master,$slaves -n $(($mpi1_ppn * $total_virtual_machines)) $mpi_settings $imb_mpi1_path"
				LogMsg "IMB-MPI1 test iteration $attempt - Running."
				$mpi_run_path --allow-run-as-root --host $master,$slaves -n $(($mpi1_ppn * $total_virtual_machines)) $mpi_settings $imb_mpi1_path \
					>IMB-MPI1-AllNodes-output-Attempt-${attempt}.txt
				mpi_status=$?
			else
				LogMsg "$mpi_run_path --allow-run-as-root --host $master,$slaves -n $(($mpi1_ppn * $total_virtual_machines)) $mpi_settings $imb_mpi1_path $imb_mpi1_tests"
				LogMsg "IMB-MPI1 test iteration $attempt - Running."
				$mpi_run_path --allow-run-as-root --host $master,$slaves -n $(($mpi1_ppn * $total_virtual_machines)) $mpi_settings $imb_mpi1_path $imb_mpi1_tests \
					>IMB-MPI1-AllNodes-output-Attempt-${attempt}.txt
				mpi_status=$?
			fi
			if [ $mpi_status -eq 0 ]; then
				LogMsg "IMB-MPI1 test iteration $attempt - Succeeded."
				sleep 1
			else
				LogErr "IMB-MPI1 test iteration $attempt - Failed."
				imb_mpi1_final_status=$(($imb_mpi1_final_status + $mpi_status))
				sleep 1
			fi
		done

		if [ $imb_mpi1_tests_iterations -gt 5 ]; then
			Compress_Files "IMB-MPI1-AllNodes-output.tar.gz" "IMB-MPI1-AllNodes-output-Attempt"
		fi

		if [ $imb_mpi1_final_status -ne 0 ]; then
			LogErr "IMB-MPI1 tests returned non-zero exit code."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogErr "INFINIBAND_VERIFICATION_FAILED_MPI1_ALLNODES"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_MPI1_ALLNODES"

		fi

		#Verify IMB-RMA tests.
		total_attempts=$(seq 1 1 $imb_rma_tests_iterations)
		imb_rma_final_status=0
		for attempt in $total_attempts; do
			if [[ $imb_rma_tests == "all" ]]; then
				LogMsg "$mpi_run_path --allow-run-as-root --host $master,$slaves -n $(($rma_ppn * $total_virtual_machines)) $mpi_settings $imb_rma_path"
				LogMsg "IMB-RMA test iteration $attempt - Running."
				$mpi_run_path --allow-run-as-root --host $master,$slaves -n $(($rma_ppn * $total_virtual_machines)) $mpi_settings $imb_rma_path \
					>IMB-RMA-AllNodes-output-Attempt-${attempt}.txt
				rma_status=$?
			else
				LogMsg "$mpi_run_path --allow-run-as-root --host $master,$slaves -n $(($rma_ppn * $total_virtual_machines)) $mpi_settings $imb_rma_path $imb_rma_tests"
				LogMsg "IMB-RMA test iteration $attempt - Running."
				$mpi_run_path --allow-run-as-root --host $master,$slaves -n $(($rma_ppn * $total_virtual_machines)) $mpi_settings $imb_rma_path $imb_rma_tests \
					>IMB-RMA-AllNodes-output-Attempt-${attempt}.txt
				rma_status=$?
			fi
			if [ $rma_status -eq 0 ]; then
				LogMsg "IMB-RMA test iteration $attempt - Succeeded."
				sleep 1
			else
				LogErr "IMB-RMA test iteration $attempt - Failed."
				imb_rma_final_status=$(($imb_rma_final_status + $rma_status))
				sleep 1
			fi
		done

		if [ $imb_rma_tests_iterations -gt 5 ]; then
			Compress_Files "IMB-RMA-AllNodes-output.tar.gz" "IMB-RMA-AllNodes-output-Attempt"
		fi

		if [ $imb_rma_final_status -ne 0 ]; then
			LogErr "IMB-RMA tests returned non-zero exit code. Aborting further tests."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogErr "INFINIBAND_VERIFICATION_FAILED_RMA_ALLNODES"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_RMA_ALLNODES"
		fi

		#Verify IMB-NBC tests.
		total_attempts=$(seq 1 1 $imb_nbc_tests_iterations)
		imb_nbc_final_status=0
		for attempt in $total_attempts; do
			retries=0
			while [ $retries -lt 3 ]; do
				if [[ $imb_nbc_tests == "all" ]]; then
					LogMsg "$mpi_run_path --allow-run-as-root --host $master,$slaves -n $(($nbc_ppn * $total_virtual_machines)) $mpi_settings $imb_nbc_path"
					LogMsg "IMB-NBC test iteration $attempt - Running."
					$mpi_run_path --allow-run-as-root --host $master,$slaves -n $(($nbc_ppn * $total_virtual_machines)) $mpi_settings $imb_nbc_path \
						>IMB-NBC-AllNodes-output-Attempt-${attempt}.txt
					nbc_status=$?
				else
					LogMsg "$mpi_run_path --allow-run-as-root --host $master,$slaves -n $(($nbc_ppn * $total_virtual_machines)) $mpi_settings $imb_nbc_path $imb_nbc_tests"
					LogMsg "IMB-NBC test iteration $attempt - Running."
					$mpi_run_path --allow-run-as-root --host $master,$slaves -n $(($nbc_ppn * $total_virtual_machines)) $mpi_settings $imb_nbc_path $imb_nbc_tests \
						>IMB-NBC-AllNodes-output-Attempt-${attempt}.txt
					nbc_status=$?
				fi
				if [ $nbc_status -eq 0 ]; then
					LogMsg "IMB-NBC test iteration $attempt - Succeeded."
					sleep 1
					retries=4
				else
					sleep 10
					let retries=retries+1
					failed_nbc=$(cat IMB-NBC-AllNodes-output-Attempt-${attempt}.txt | grep Benchmarking | tail -1| awk '{print $NF}')
					nbc_benchmarks=$(echo $nbc_benchmarks | sed "s/^.*${failed_nbc}//")
					imb_nbc_tests=$nbc_benchmarks
				fi
			done
			if [ $nbc_status -eq 0 ]; then
				LogMsg "IMB-NBC test iteration $attempt - Succeeded."
				sleep 1
			else
				LogErr "IMB-NBC test iteration $attempt - Failed."
				imb_nbc_final_status=$(($imb_nbc_final_status + $nbc_status))
				sleep 1
			fi
		done

		if [ $imb_nbc_tests_iterations -gt 5 ]; then
			Compress_Files "IMB-NBC-AllNodes-output.tar.gz" "IMB-NBC-AllNodes-output-Attempt"
		fi

		if [ $imb_nbc_final_status -ne 0 ]; then
			LogErr "IMB-NBC tests returned non-zero exit code. Aborting further tests."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogErr "INFINIBAND_VERIFICATION_FAILED_NBC_ALLNODES"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_NBC_ALLNODES"
		fi

		Collect_Kernel_Logs_From_All_VMs

		finalStatus=$(($final_ib_nic_status + $ib_port_state_down_cnt + $alloc_uar_limited_cnt + $final_mpi_intranode_status + $imb_mpi1_final_status + $imb_rma_final_status + $imb_nbc_final_status))

		if [ $finalStatus -ne 0 ]; then
			LogMsg "${ib_nic}_status: $final_ib_nic_status"
			LogMsg "ib_port_state_down_cnt: $ib_port_state_down_cnt"
			LogMsg "alloc_uar_limited_cnt: $alloc_uar_limited_cnt"
			LogMsg "final_mpi_intranode_status: $final_mpi_intranode_status"
			LogMsg "imb_mpi1_final_status: $imb_mpi1_final_status"
			LogMsg "imb_rma_final_status: $imb_rma_final_status"
			LogMsg "imb_nbc_final_status: $imb_nbc_final_status"
			LogErr "INFINIBAND_VERIFICATION_FAILED"
			SetTestStateFailed
		else
			LogMsg "INFINIBAND_VERIFIED_SUCCESSFULLY"
			SetTestStateCompleted
		fi
	else
		# ############################################################################################################
		# MVAPICH MPI execution
		mpi_run_path=$(find / -name mpirun_rsh | tail -n 1)
		LogMsg "MPIRUN_RSH Path: $mpi_run_path"
		
		imb_mpi1_path=$(find / -name IMB-MPI1 | head -n 1)
		LogMsg "IMB-MPI1 Path: $imb_mpi1_path"
		
		imb_rma_path=$(find / -name IMB-RMA | head -n 1)
		LogMsg "IMB-RMA Path: $imb_rma_path"
		
		imb_nbc_path=$(find / -name IMB-NBC | head -n 1)
		LogMsg "IMB-NBC Path: $imb_nbc_path"

		#Verify PingPong Tests (IntraNode).
		final_mpi_intranode_status=0

		for vm1 in $master $slaves_array; do
			# Manual running needs to clean up the old log files.
			if [ -f ./IMB-MPI1-IntraNode-output-$vm1.txt ]; then
				rm -f ./IMB-MPI1-IntraNode-output-$vm1*.txt
				LogMsg "Removed the old log files"
			fi
			for vm2 in $master $slaves_array; do
				log_file=IMB-MPI1-IntraNode-output-$vm1-$vm2.txt
				LogMsg "$mpi_run_path -n 2 $vm1 $vm2 $imb_mpi1_path pingpong"
				LogMsg "Checking IMB-MPI1 IntraNode status in $vm1"
				ssh root@${vm1} "$mpi_run_path -n 2 $vm1 $vm2 $imb_mpi1_path pingpong >> $log_file"
				mpi_intranode_status=$?

				scp root@${vm1}:$log_file .

				if [ $mpi_intranode_status -eq 0 ]; then
					LogMsg "IMB-MPI1 IntraNode status in $vm1 - Succeeded."
				else
					LogErr "IMB-MPI1 IntraNode status in $vm1 - Failed"
				fi
				final_mpi_intranode_status=$(($final_mpi_intranode_status + $mpi_intranode_status))
			done
		done
		if [ $final_mpi_intranode_status -ne 0 ]; then
			LogErr "IMB-MPI1 Intranode ping_pong test failed in somes VMs. Aborting further tests."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogMsg "INFINIBAND_VERIFICATION_FAILED_MPI1_INTRANODE"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_MPI1_INTRANODE"
		fi

		#Verify IMB-MPI1 (pingpong & allreduce etc) tests.
		total_attempts=$(seq 1 1 $imb_mpi1_tests_iterations)
		imb_mpi1_final_status=0
		for attempt in $total_attempts; do
			if [[ $imb_mpi1_tests == "all" ]]; then
				LogMsg "$mpi_run_path -n $(($mpi1_ppn * $total_virtual_machines)) $master $slaves_array $mpi_settings $imb_mpi1_path"
				LogMsg "IMB-MPI1 test iteration $attempt - Running."
				$mpi_run_path -n $(($mpi1_ppn * $total_virtual_machines)) $master $slaves_array $mpi_settings $imb_mpi1_path > IMB-MPI1-AllNodes-output-Attempt-${attempt}.txt
				mpi_status=$?
			else
				LogMsg "$mpi_run_path -n $(($mpi1_ppn * $total_virtual_machines)) $master $slaves_array $mpi_settings $imb_mpi1_path $imb_mpi1_tests"
				LogMsg "IMB-MPI1 test iteration $attempt - Running."
				$mpi_run_path -n $(($mpi1_ppn * $total_virtual_machines)) $master $slaves_array $mpi_settings $imb_mpi1_path $imb_mpi1_tests > IMB-MPI1-AllNodes-output-Attempt-${attempt}.txt
				mpi_status=$?
			fi
			if [ $mpi_status -eq 0 ]; then
				LogMsg "IMB-MPI1 test iteration $attempt - Succeeded."
				sleep 1
			else
				LogErr "IMB-MPI1 test iteration $attempt - Failed."
				imb_mpi1_final_status=$(($imb_mpi1_final_status + $mpi_status))
				sleep 1
			fi
		done

		if [ $imb_mpi1_tests_iterations -gt 5 ]; then
			Compress_Files "IMB-MPI1-AllNodes-output.tar.gz" "IMB-MPI1-AllNodes-output-Attempt"
		fi

		if [ $imb_mpi1_final_status -ne 0 ]; then
			LogErr "IMB-MPI1 tests returned non-zero exit code."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogErr "INFINIBAND_VERIFICATION_FAILED_MPI1_ALLNODES"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_MPI1_ALLNODES"

		fi

		#Verify IMB-RMA tests.
		total_attempts=$(seq 1 1 $imb_rma_tests_iterations)
		imb_rma_final_status=0
		for attempt in $total_attempts; do
			if [[ $imb_rma_tests == "all" ]]; then
				LogMsg "$mpi_run_path -n $(($rma_ppn * $total_virtual_machines)) $master $slaves_array $mpi_settings $imb_rma_path"
				LogMsg "IMB-RMA test iteration $attempt - Running."
				$mpi_run_path -n $(($rma_ppn * $total_virtual_machines)) $master $slaves_array $mpi_settings $imb_rma_path > IMB-RMA-AllNodes-output-Attempt-${attempt}.txt
				rma_status=$?
			else
				LogMsg "$mpi_run_path -n $(($rma_ppn * $total_virtual_machines)) $master $slaves_array $mpi_settings $imb_rma_path $imb_rma_tests"
				LogMsg "IMB-RMA test iteration $attempt - Running."
				$mpi_run_path -n $(($rma_ppn * $total_virtual_machines)) $master $slaves_array $mpi_settings $imb_rma_path $imb_rma_tests > IMB-RMA-AllNodes-output-Attempt-${attempt}.txt
				rma_status=$?
			fi
			if [ $rma_status -eq 0 ]; then
				LogMsg "IMB-RMA test iteration $attempt - Succeeded."
				sleep 1
			else
				LogErr "IMB-RMA test iteration $attempt - Failed."
				imb_rma_final_status=$(($imb_rma_final_status + $rma_status))
				sleep 1
			fi
		done

		if [ $imb_rma_tests_iterations -gt 5 ]; then
			Compress_Files "IMB-RMA-AllNodes-output.tar.gz" "IMB-RMA-AllNodes-output-Attempt"
		fi

		if [ $imb_rma_final_status -ne 0 ]; then
			LogErr "IMB-RMA tests returned non-zero exit code. Aborting further tests."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogErr "INFINIBAND_VERIFICATION_FAILED_RMA_ALLNODES"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_RMA_ALLNODES"
		fi

		#Verify IMB-NBC tests.
		total_attempts=$(seq 1 1 $imb_nbc_tests_iterations)
		imb_nbc_final_status=0
		for attempt in $total_attempts; do
			if [[ $imb_nbc_tests == "all" ]]; then
				LogMsg "$mpi_run_path -n $(($nbc_ppn * $total_virtual_machines)) $master $slaves_array $mpi_settings $imb_nbc_path"
				LogMsg "IMB-NBC test iteration $attempt - Running."
				$mpi_run_path -n $(($nbc_ppn * $total_virtual_machines)) $master $slaves_array $mpi_settings $imb_nbc_path > IMB-NBC-AllNodes-output-Attempt-${attempt}.txt
				nbc_status=$?
			else
				LogMsg "$mpi_run_path -n $(($nbc_ppn * $total_virtual_machines)) $master $slaves_array $mpi_settings $imb_nbc_path $imb_nbc_tests"
				LogMsg "IMB-NBC test iteration $attempt - Running."
				$mpi_run_path -n $(($nbc_ppn * $total_virtual_machines)) $master $slaves_array $mpi_settings $imb_nbc_path $imb_nbc_tests > IMB-NBC-AllNodes-output-Attempt-${attempt}.txt
				nbc_status=$?
			fi
			if [ $nbc_status -eq 0 ]; then
				LogMsg "IMB-NBC test iteration $attempt - Succeeded."
				sleep 1
			else
				LogErr "IMB-NBC test iteration $attempt - Failed."
				imb_nbc_final_status=$(($imb_nbc_final_status + $nbc_status))
				sleep 1
			fi
		done

		if [ $imb_nbc_tests_iterations -gt 5 ]; then
			Compress_Files "IMB-NBC-AllNodes-output.tar.gz" "IMB-NBC-AllNodes-output-Attempt"
		fi

		if [ $imb_nbc_final_status -ne 0 ]; then
			LogErr "IMB-NBC tests returned non-zero exit code. Aborting further tests."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogErr "INFINIBAND_VERIFICATION_FAILED_NBC_ALLNODES"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_NBC_ALLNODES"
		fi

		Collect_Kernel_Logs_From_All_VMs

		finalStatus=$(($final_ib_nic_status + $ib_port_state_down_cnt + $alloc_uar_limited_cnt + $final_mpi_intranode_status + $imb_mpi1_final_status + $imb_rma_final_status + $imb_nbc_final_status))

		if [ $finalStatus -ne 0 ]; then
			LogMsg "${ib_nic}_status: $final_ib_nic_status"
			LogMsg "ib_port_state_down_cnt: $ib_port_state_down_cnt"
			LogMsg "alloc_uar_limited_cnt: $alloc_uar_limited_cnt"
			LogMsg "final_mpi_intranode_status: $final_mpi_intranode_status"
			LogMsg "imb_mpi1_final_status: $imb_mpi1_final_status"
			LogMsg "imb_rma_final_status: $imb_rma_final_status"
			LogMsg "imb_nbc_final_status: $imb_nbc_final_status"
			LogErr "INFINIBAND_VERIFICATION_FAILED"
			SetTestStateFailed
		else
			LogMsg "INFINIBAND_VERIFIED_SUCCESSFULLY"
			SetTestStateCompleted
		fi
	fi
	#It is important to exit with zero. Otherwise, Autmatinon will try to run the scrtipt again.
	#Result analysis is already done in the script with be checked by automation as well.
	exit 0
}

Main