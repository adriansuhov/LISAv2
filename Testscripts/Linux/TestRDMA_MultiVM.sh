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

	# This is common space for all three types of MPI testing
	# Verify if ib_nic got IP address on All VMs in current cluster.
	# ib_nic comes from constants.sh. where get those values from XML tags.
	final_ib_nic_status=0
	total_virtual_machines=0
	err_virtual_machines=0
	slaves_array=$(echo ${slaves} | tr ',' ' ')

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
	fi

	## Verify Intel MPI Tests
	non_shm_mpi_settings=$(echo $mpi_settings | sed 's/shm://')

	if [[ $mpi_type == "intel" ]]; then

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

		for vm in $master $slaves_array; do
			LogMsg "$mpi_run_path -hosts $vm -ppn $mpi1_ppn -n $(($mpi1_ppn * $total_virtual_machines)) $non_shm_mpi_settings $imb_mpi1_path pingpong"
			LogMsg "Checking IMB-MPI1 IntraNode status in $vm"
			ssh root@${vm} "$mpi_run_path -hosts $vm -ppn $mpi1_ppn -n $(($mpi1_ppn * $total_virtual_machines)) $non_shm_mpi_settings $imb_mpi1_path pingpong \
				> IMB-MPI1-IntraNode-pingpong-output-$vm.txt"
			mpi_intranode_status=$?
			scp root@${vm}:IMB-MPI1-IntraNode-pingpong-output-$vm.txt .
			if [ $mpi_intranode_status -eq 0 ]; then
				LogMsg "IMB-MPI1 Intranode status in $vm - Succeeded."
			else
				LogErr "IMB-MPI1 Intranode status in $vm - Failed"
			fi
			final_mpi_intranode_status=$(($final_mpi_intranode_status + $mpi_intranode_status))
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

		# Verify Intel MPI PingPong Tests (InterNode).
		final_mpi_internode_status=0

		for vm in $slaves_array; do
			LogMsg "$mpi_run_path -hosts $master,$vm -ppn $mpi1_ppn -n $(($mpi1_ppn * $total_virtual_machines)) $non_shm_mpi_settings $imb_mpi1_path pingpong"
			LogMsg "Checking IMB-MPI1 InterNode status in $vm"
			$mpi_run_path -hosts $master,$vm -ppn $mpi1_ppn -n $(($mpi1_ppn * $total_virtual_machines)) $non_shm_mpi_settings $imb_mpi1_path pingpong \
				>IMB-MPI1-InterNode-pingpong-output-${master}-${vm}.txt
			mpi_internode_status=$?
			if [ $mpi_internode_status -eq 0 ]; then
				LogMsg "IMB-MPI1 Internode status in $vm - Succeeded."
			else
				LogErr "IMB-MPI1 Internode status in $vm - Failed"
			fi
			final_mpi_internode_status=$(($final_mpi_internode_status + $mpi_internode_status))
		done

		if [ $final_mpi_internode_status -ne 0 ]; then
			LogErr "IMB-MPI1 Internode test failed in somes VMs. Aborting further tests."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogErr "INFINIBAND_VERIFICATION_FAILED_MPI1_INTERNODE"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_MPI1_INTERNODE"
		fi

		# Verify Intel MPI IMB-MPI1 (pingpong & allreduce etc) tests.
		total_attempts=$(seq 1 1 $imb_mpi1_tests_iterations)
		imb_mpi1_final_status=0
		for attempt in $total_attempts; do
			if [[ $imb_mpi1_tests == "all" ]]; then
				LogMsg "$mpi_run_path -hosts $master,$slaves -ppn $mpi1_ppn -n $(($mpi1_ppn * $total_virtual_machines)) $mpi_settings $imb_mpi1_path"
				LogMsg "IMB-MPI1 test iteration $attempt - Running."
				$mpi_run_path -hosts $master,$slaves -ppn $mpi1_ppn -n $(($mpi1_ppn * $total_virtual_machines)) $mpi_settings $imb_mpi1_path \
					>IMB-MPI1-AllNodes-output-Attempt-${attempt}.txt
				mpi_status=$?
			else
				LogMsg "$mpi_run_path -hosts $master,$slaves -ppn $mpi1_ppn -n $(($mpi1_ppn * $total_virtual_machines)) $mpi_settings $imb_mpi1_path $imb_mpi1_tests"
				LogMsg "IMB-MPI1 test iteration $attempt - Running."
				$mpi_run_path -hosts $master,$slaves -ppn $mpi1_ppn -n $(($mpi1_ppn * $total_virtual_machines)) $mpi_settings $imb_mpi1_path $imb_mpi1_tests \
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
				LogMsg "$mpi_run_path -hosts $master,$slaves -ppn $rma_ppn -n $(($rma_ppn * $total_virtual_machines)) $mpi_settings $imb_rma_path"
				LogMsg "IMB-RMA test iteration $attempt - Running."
				$mpi_run_path -hosts $master,$slaves -ppn $rma_ppn -n $(($rma_ppn * $total_virtual_machines)) $mpi_settings $imb_rma_path \
					>IMB-RMA-AllNodes-output-Attempt-${attempt}.txt
				rma_status=$?
			else
				LogMsg "$mpi_run_path -hosts $master,$slaves -ppn $rma_ppn -n $(($rma_ppn * $total_virtual_machines)) $mpi_settings $imb_rma_path $imb_rma_tests"
				LogMsg "IMB-RMA test iteration $attempt - Running."
				$mpi_run_path -hosts $master,$slaves -ppn $rma_ppn -n $(($rma_ppn * $total_virtual_machines)) $mpi_settings $imb_rma_path $imb_rma_tests \
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
			if [[ $imb_nbc_tests == "all" ]]; then
				LogMsg "$mpi_run_path -hosts $master,$slaves -ppn $nbc_ppn -n $(($nbc_ppn * $total_virtual_machines)) $mpi_settings $imb_nbc_path"
				LogMsg "IMB-NBC test iteration $attempt - Running."
				$mpi_run_path -hosts $master,$slaves -ppn $nbc_ppn -n $(($nbc_ppn * $total_virtual_machines)) $mpi_settings $imb_nbc_path \
					>IMB-NBC-AllNodes-output-Attempt-${attempt}.txt
				nbc_status=$?
			else
				LogMsg "$mpi_run_path -hosts $master,$slaves -ppn $nbc_ppn -n $(($nbc_ppn * $total_virtual_machines)) $mpi_settings $imb_nbc_path $imb_nbc_tests"
				LogMsg "IMB-NBC test iteration $attempt - Running."
				$mpi_run_path -hosts $master,$slaves -ppn $nbc_ppn -n $(($nbc_ppn * $total_virtual_machines)) $mpi_settings $imb_nbc_path $imb_nbc_tests \
					>IMB-NBC-AllNodes-output-Attempt-${attempt}.txt
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

		if [ $imb_rma_tests_iterations -gt 5 ]; then
			mpi_status "IMB-NBC-AllNodes-output.tar.gz" "IMB-NBC-AllNodes-output-Attempt"
		fi

		if [ $imb_nbc_final_status -ne 0 ]; then
			LogErr "IMB-RMA tests returned non-zero exit code. Aborting further tests."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogErr "INFINIBAND_VERIFICATION_FAILED_NBC_ALLNODES"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_NBC_ALLNODES"
		fi

		Collect_Kernel_Logs_From_All_VMs

		finalStatus=$(($ib_nic_status + $final_mpi_intranode_status + $final_mpi_internode_status \
			+ $imb_mpi1_final_status + $imb_rma_final_status + $imb_nbc_final_status))

		if [ $finalStatus -ne 0 ]; then
			LogMsg "${ib_nic}_status: $ib_nic_status"
			LogMsg "final_mpi_intranode_status: $final_mpi_intranode_status"
			LogMsg "final_mpi_internode_status: $final_mpi_internode_status"
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

		# Search mpirun and benchmark testing files
		# mpirun -n <P> IMB-<component> [argement], where <P> is the number of processes. P=1 is recommended for 
		#				all I/O and message passing benchmarks except the single transfer ones.
		#				, where <component> is the component-specific suffix that can take MPI1, 
		#				EXT, IO, NBC, and RMA values.

		# mpirun binary location
		mpi_run_path=$(find / -name mpirun | grep platform_mpi/bin/mpirun)
		LogMsg "MPIRUN Path: $mpi_run_path"
		
		# IMB-MPI1 location
		imb_mpi1_path=$(find / -name IMB-MPI1)
		LogMsg "IMB-MPI1 Path: $imb_mpi1_path"
		
		# IMB-RMA location
		imb_rma_path=$(find / -name IMB-RMA)
		LogMsg "IMB-RMA Path: $imb_rma_path"
		
		# IMB-NBC location
		imb_nbc_path=$(find / -name IMB-NBC)
		LogMsg "IMB-NBC Path: $imb_nbc_path"

		# ping_pong binary in help directory
		imb_ping_pong_path=$(find / -name ping_pong)
		LogMsg "MPI ping_pong Path: $imb_ping_pong_path"

		# MPI-1
		# Verify IBM PingPong Tests (IntraNode).
		final_mpi_intranode_status=0

		for vm in $master $slaves_array; do
			LogMsg "$mpi_run_path -hostlist $vm:1,$master:1 -np $(($mpi1_ppn * $total_virtual_machines)) $imb_ping_pong_path 4096"
			LogMsg "Checking IMB-MPI1 IntraNode status in $vm"
			ssh root@${vm} "$mpi_run_path -hostlist $vm:1,$master:1 -np $(($mpi1_ppn * $total_virtual_machines)) $imb_ping_pong_path 4096 \
				> IMB-MPI1-IntraNode-output-$vm.txt"
			mpi_intranode_status=$?

			scp root@${vm}:IMB-MPI1-IntraNode-output-$vm.txt .

			if [ $mpi_intranode_status -eq 0 ]; then
				LogMsg "IMB-MPI1 IntraNode status in $vm - Succeeded."
			else
				LogErr "IMB-MPI1 IntraNode status in $vm - Failed"
			fi
			final_mpi_intranode_status=$(($final_mpi_intranode_status + $mpi_intranode_status))
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

		# Verify IBM PingPong Tests (InterNode).
		final_mpi_internode_status=0

		for vm in $slaves_array; do
			LogMsg "$mpi_run_path -hostlist $master:1,$vm:1 -np $(($mpi1_ppn * $total_virtual_machines)) $imb_ping_pong_path 4096"
			LogMsg "Checking IMB-MPI1 InterNode status in $vm"
			$mpi_run_path -hostlist $master:1,$vm:1 -np $(($mpi1_ppn * $total_virtual_machines)) $imb_ping_pong_path 4096 \
				> IMB-MPI1-InterNode-pingpong-output-${master}-${vm}.txt
			mpi_internode_status=$?

			if [ $mpi_internode_status -eq 0 ]; then
				LogMsg "IMB-MPI1 InterNode status in $vm - Succeeded."
			else
				LogErr "IMB-MPI1 InterNode status in $vm - Failed"
			fi
			final_mpi_internode_status=$(($final_mpi_internode_status + $mpi_internode_status))
		done

		if [ $final_mpi_internode_status -ne 0 ]; then
			LogErr "IMB-MPI1 InterNode test failed in somes VMs. Aborting further tests."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogErr "INFINIBAND_VERIFICATION_FAILED_MPI1_INTERNODE"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_MPI1_INTERNODE"
		fi

		# Verify IBM IMB-MPI1 tests.
		total_attempts=$(seq 1 1 $imb_mpi1_tests_iterations)
		imb_mpi1_final_status=0
		for attempt in $total_attempts; do
			LogMsg "$mpi_run_path -hostlist $master:1,$slaves:1 -np $(($mpi1_ppn * $total_virtual_machines)) $imb_mpi1_path $imb_mpi1_tests allreduce"
			LogMsg "IMB-MPI1 test iteration $attempt - Running."
			$mpi_run_path -hostlist $master:1,$slaves:1 -np $(($mpi1_ppn * $total_virtual_machines)) $imb_mpi1_path $imb_mpi1_tests allreduce \
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
			LogMsg "$mpi_run_path -hostlist $master:1,$slaves:1 -np $(($nbc_ppn * $total_virtual_machines)) $imb_nbc_path $imb_nbc_tests"
			LogMsg "IMB-NBC test iteration $attempt - Running."
			$mpi_run_path -hostlist $master:1,$slaves:1 -np $(($nbc_ppn * $total_virtual_machines)) $imb_nbc_path $imb_nbc_tests \
				> IMB-NBC-AllNodes-output-Attempt-${attempt}.txt
			nbc_status=$?
		
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
			mpi_status "IMB-NBC-AllNodes-output.tar.gz" "IMB-NBC-AllNodes-output-Attempt"
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

		# finalStatus=$(($ib_nic_status + $final_mpi_intranode_status + $final_mpi_internode_status + $imb_mpi1_final_status + $imb_rma_final_status + $imb_nbc_final_status))
		finalStatus=$(($ib_nic_status + $final_mpi_intranode_status + $final_mpi_internode_status + $imb_mpi1_final_status + $imb_nbc_final_status))
		
		if [ $finalStatus -ne 0 ]; then
			LogMsg "${ib_nic}_status: $ib_nic_status"
			LogMsg "final_mpi_intranode_status: $final_mpi_intranode_status"
			LogMsg "final_mpi_internode_status: $final_mpi_internode_status"
			LogMsg "imb_mpi1_final_status: $imb_mpi1_final_status"
			# LogMsg "imb_rma_final_status: $imb_rma_final_status"
			LogMsg "imb_nbc_final_status: $imb_nbc_final_status"
			LogErr "INFINIBAND_VERIFICATION_FAILED"
			SetTestStateFailed
		else
			LogMsg "INFINIBAND_VERIFIED_SUCCESSFULLY"
			SetTestStateCompleted
		fi

	else
		# OPEN MPI execution
		# Need exclusive word intel if it runs in HPC image. Both will conflict.
		mpi_run_path=$(find / -name mpirun | grep -v intel)
		LogMsg "MPIRUN Path: $mpi_run_path"
		
		imb_mpi1_path=$(find / -name IMB-MPI1)
		LogMsg "IMB-MPI1 Path: $imb_mpi1_path"
		
		imb_rma_path=$(find / -name IMB-RMA)
		LogMsg "IMB-RMA Path: $imb_rma_path"
		
		imb_nbc_path=$(find / -name IMB-NBC)
		LogMsg "IMB-NBC Path: $imb_nbc_path"

		#Verify PingPong Tests (IntraNode).
		final_mpi_intranode_status=0

		for vm in $master $slaves_array; do
			LogMsg "$mpi_run_path --allow-run-as-root $non_shm_mpi_settings -np $(($mpi1_ppn * $total_virtual_machines)) --host $vm,$master $imb_mpi1_path pingpong"
			LogMsg "Checking IMB-MPI1 Intranode status in $vm"
			ssh root@${vm} "$mpi_run_path --allow-run-as-root $non_shm_mpi_settings -np $(($mpi1_ppn * $total_virtual_machines)) --host $vm,$master $imb_mpi1_path pingpong \
				> IMB-MPI1-IntraNode-pingpong-output-$vm.txt"
			mpi_intranode_status=$?
			scp root@${vm}:IMB-MPI1-IntraNode-pingpong-output-$vm.txt .
			if [ $mpi_intranode_status -eq 0 ]; then
				LogMsg "IMB-MPI1 Intranode status in $vm - Succeeded."
			else
				LogErr "IMB-MPI1 Intranode status in $vm - Failed"
			fi
			final_mpi_intranode_status=$(($final_mpi_intranode_status + $mpi_intranode_status))
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

		#Verify PingPong Tests (InterNode).
		final_mpi_internode_status=0

		for vm in $slaves_array; do
			LogMsg "$mpi_run_path --allow-run-as-root $non_shm_mpi_settings -np $(($mpi1_ppn * $total_virtual_machines)) --host $master,$vm $imb_mpi1_path pingpong"
			LogMsg "Checking IMB-MPI1 InterNode status in $vm"
			$mpi_run_path --allow-run-as-root $non_shm_mpi_settings -np $(($mpi1_ppn * $total_virtual_machines)) --host $master,$vm $imb_mpi1_path pingpong \
				>IMB-MPI1-InterNode-pingpong-output-${master}-${vm}.txt
			mpi_internode_status=$?
			if [ $mpi_internode_status -eq 0 ]; then
				LogMsg "IMB-MPI1 Internode status in $vm - Succeeded."
			else
				LogErr "IMB-MPI1 Internode status in $vm - Failed"
			fi
			final_mpi_internode_status=$(($final_mpi_internode_status + $mpi_internode_status))
		done

		if [ $final_mpi_internode_status -ne 0 ]; then
			LogErr "IMB-MPI1 Internode test failed in somes VMs. Aborting further tests."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogErr "INFINIBAND_VERIFICATION_FAILED_MPI1_INTERNODE"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_MPI1_INTERNODE"
		fi

		#Verify IMB-MPI1 (pingpong & allreduce etc) tests.
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
				$mpi_run_path --allow-run-as-root --host $master,$slaves -n	$(($mpi1_ppn * $total_virtual_machines)) $mpi_settings $imb_mpi1_path $imb_mpi1_tests \
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
			else
				LogErr "IMB-NBC test iteration $attempt - Failed."
				imb_nbc_final_status=$(($imb_nbc_final_status + $nbc_status))
				sleep 1
			fi
		done

		if [ $imb_rma_tests_iterations -gt 5 ]; then
			mpi_status "IMB-NBC-AllNodes-output.tar.gz" "IMB-NBC-AllNodes-output-Attempt"
		fi

		if [ $imb_nbc_final_status -ne 0 ]; then
			LogErr "IMB-RMA tests returned non-zero exit code. Aborting further tests."
			SetTestStateFailed
			Collect_Kernel_Logs_From_All_VMs
			LogErr "INFINIBAND_VERIFICATION_FAILED_NBC_ALLNODES"
			exit 0
		else
			LogMsg "INFINIBAND_VERIFICATION_SUCCESS_NBC_ALLNODES"
		fi

		Collect_Kernel_Logs_From_All_VMs

		finalStatus=$(($ib_nic_status + $final_mpi_intranode_status + $final_mpi_internode_status + $imb_mpi1_final_status + $imb_rma_final_status + $imb_nbc_final_status))

		if [ $finalStatus -ne 0 ]; then
			LogMsg "${ib_nic}_status: $ib_nic_status"
			LogMsg "final_mpi_intranode_status: $final_mpi_intranode_status"
			LogMsg "final_mpi_internode_status: $final_mpi_internode_status"
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