
function err_usage ()
{
	echo "usage: $1 list"
	echo "usage: $1 up name"
	echo "usage: $1 down name"
	echo "usage: $1 reset name"
	echo "usage: $1 reboot name"
	echo "usage: $1 pause name"
	echo "usage: $1 resume name"
	echo "usage: $1 wait name"
	echo "usage: $1 console name"
	echo "usage: $1 listsnap name"
	echo "usage: $1 addsnap name tag"
	echo "usage: $1 delsnap name tag"
	echo "usage: $1 runsnap name tag"
}

function err_vm ()
{
	echo "!!! Error with vm $1"

	case "$2" in
	${ERR_DIRDOESNOTEXIST})
		echo "Directory does not exist!"
		;;
	${ERR_CONFDOESNOTEXIST})
		echo "no configuration file found!"
		;;
	${ERR_COULDNOTGETFREEVNCDISPLAY})
		echo "could not get a free vnc display!"
		;;
	${ERR_VMALREADYRUNNING})
		echo "VM already running!"
		;;
	${ERR_VMNOTRUNNING})
		echo "VM not running!"
		;;
	${ERR_CANNOTCOMMUNICATETOVM})
		echo "cannot communicate to VM!"
		;;
	${ERR_NOSOCAT})
		echo "no socat - please install socat!"
		;;
	${ERR_MKFIFO})
		echo "could not create pipe!"
		;;
	*)
		echo "Error with vm $1: $2"
		;;
	esac
}

function vm_check ()
{
	[ -d "${IMAGE_BASEPATH}/$1" ] || return ${ERR_DIRDOESNOTEXIST}

	[ -f "${IMAGE_BASEPATH}/$1/vm.conf" ] || return ${ERR_CONFDOESNOTEXIST}

	[ -e "$(which socat)" ] || return ${ERR_NOSOCAT}
}

function vm_buildparam_hdX ()
{
	local VAL=$(eval echo \${VM_$1})

	[ -z "$VAL" ] && return 0

	echo -n \
		"-$1 " \
		${VAL} \
		" "
}

function vm_getnextfreevncdisplay ()
{
	netstat -pan |
	grep -E ":59[0-9][0-9][:space:]+" |
	awk '{ print($4); }' |
	cut -d':' -f2 |
	sort |
	tail -n 1 |
	{
		while read PORT; do
			echo $(($PORT - 5900 + 1))
		done
		echo 1
	}
}

function vm_buildparam ()
{
	########################################################################
	# name
	echo -n \
		"-name $VM_NAME" \
		" "

	########################################################################
	# images
	vm_buildparam_hdX "hda"
	vm_buildparam_hdX "hdb"
	vm_buildparam_hdX "hdc"
	vm_buildparam_hdX "hdd"

	########################################################################
	# machine parameters
	echo -n \
		"-M ${VM_MACHINE:=${DEF_VM_MACHINE}}" \
		" " \
		"-cpu ${VM_CPU:=${DEF_VM_CPU}}" \
		" "
	
	########################################################################
	# ram parameters
	echo -n \
		"-m ${VM_RAM:=${DEF_VM_RAM}}" \
		" "
	
	########################################################################
	# cpu parameters
	echo -n \
		"-smp ${VM_CPUS:=${DEF_VM_CPUS}}" \
		" "
	
	########################################################################
	# net parameters
	case "${VM_NET}" in
	local)
		echo \
			"-net nic,macaddr=${VM_NETMAC},model=${VM_NETMODEL:=${DEF_VM_NETMODEL}}" \
			" " \
			"-net tap,script=${VM_NET_LOCALSCRIPT:=${DEF_VM_NET_LOCALSCRIPT}},downscript=no" \
			" "
		;;
	global)
		echo \
			"-net nic,macaddr=${VM_NETMAC},model=${VM_NETMODEL:=${DEF_VM_NETMODEL}}" \
			" " \
			"-net tap,script=${VM_NET_GLOBALSCRIPT:=${DEF_VM_NET_GLOBALSCRIPT}},downscript=no" \
			" "
		;;
	global2)
		echo \
			"-net nic,macaddr=${VM_NETMAC},model=${VM_NETMODEL:=${DEF_VM_NETMODEL}}" \
			" " \
			"-net tap,script=${VM_NET_GLOBAL2SCRIPT:=${DEF_VM_NET_GLOBAL2SCRIPT}},downscript=no" \
			" "
		;;
	esac

	########################################################################
	# keymap parameters
	echo -n \
		"-k ${VM_KEYMAP:=${DEF_VM_KEYMAP}}" \
		" "

	########################################################################
	# graphic parameters
	case "${VM_GFX}" in
	vnc)
		VM_DISPLAY="$(vm_getnextfreevncdisplay)"
		if [ "${VM_DISPLAY}" = "-1" ]; then
			# TODO : what to do here ?!
#			err_vm ${ERR_COULDNOTGETFREEVNCDISPLAY}
#			exit ${ERR_COULDNOTGETFREEVNCDISPLAY}
			echo -n "-nographic "
		fi
		echo -n \
			"-vnc :${VM_DISPLAY}" \
			" "
		;;
	curses)
		echo -n \
			"-curses" \
			" "
		;;
	none|*)
		echo -n \
			"-nographic" \
			" "
		;;
	esac

	########################################################################
	# monitor parameters
	case "${VM_MONITOR:=${DEF_VM_MONITOR}}" in
	pipe)
		echo -n \
			"-monitor pipe:${IMAGE_BASEPATH}/${VM_NAME}/vm.pipe" \
			" "
		;;
	file)
		echo -n \
			"-monitor file:${IMAGE_BASEPATH}/${VM_NAME}/vm.file" \
			" "
		;;
	unix)
		echo -n \
			"-monitor unix:${IMAGE_BASEPATH}/${VM_NAME}/vm.unix,server,nowait" \
			" "
		;;
	pty|stdio|none|null)
		echo -n "-monitor ${VM_MONITOR} "
		;;
	esac
	return 0
}

################################################################################
# vm status

# VM_MONITOR
function vm_communicate ()
{
	local VM_MONITOR
	VM_MONITOR="$1"
	shift

	case "${VM_MONITOR}" in
	pipe)
		socat $@ stdio pipe:vm.pipe
		;;
	unix)
		socat $@ stdio unix:vm.unix
		;;
	esac
}

function vm_isrunning ()
{
	[ -f "${IMAGE_BASEPATH}/$1/vm.pid" ] || return 1

	local PID
	PID="$(cat ${IMAGE_BASEPATH}/$1/vm.pid)"

	[ -d /proc/"${PID}" ] || return 1
	[ -L /proc/"${PID}"/cwd ] || return 1

	TARGET="$(basename $(readlink -n -e /proc/${PID}/cwd))"
	if [ "$1" != "${TARGET}" ]; then
		return 1
	fi

	return 0
}

function vm_up ()
{
	cd "${IMAGE_BASEPATH}/${VM_NAME}"
	cp vm.conf vm.conf.running

	if [ "${VM_MONITOR:=${DEF_VM_MONITOR}}" = "pipe" -a ! -e vm.pipe ]; then
		mkfifo vm.pipe || {
			err_vm "${VM_NAME}" ${ERR_MKFIFO}
			exit ${ERR_MKFIFO}
		}
	fi

	echo "kvm $@" > vm.log
	kvm $@ 2>&1 1>>vm.log &
	VM_PID=$!
	echo ${VM_PID} > vm.pid

	echo "VM_PID=\"${VM_PID}\"" >> vm.conf.running
	echo "VM_MONITOR=\"${VM_MONITOR:=${DEF_VM_MONITOR}}\"" >> vm.conf.running

	cd "$OLDPWD"
}

function vm_down ()
{
	cd "${IMAGE_BASEPATH}/${VM_NAME}"

	[ -z "${VM_PID}" ] && VM_PID="$(cat vm.pid)"

	case "${VM_MONITOR}" in
	pipe|unix)
		echo system_powerdown | vm_communicate "${VM_MONITOR}"
		;;
	*)
		err_vm "${VM_NAME}"  ${ERR_CANNOTSTOPVM}
		;;
	esac

	cd "$OLDPWD"
}

function vm_reset ()
{
	cd "${IMAGE_BASEPATH}/${VM_NAME}"

	[ -z "${VM_PID}" ] && VM_PID="$(cat vm.pid)"

	case "${VM_MONITOR}" in
	pipe|unix)
		echo system_reset | vm_communicate "${VM_MONITOR}"
		;;
	*)
		err_vm "${VM_NAME}"  ${ERR_CANNOTSTOPVM}
		;;
	esac

	cd "$OLDPWD"
}

function vm_reboot ()
{
	cd "${IMAGE_BASEPATH}/${VM_NAME}"

	[ -z "${VM_PID}" ] && VM_PID="$(cat vm.pid)"

	case "${VM_MONITOR}" in
	pipe|unix)
		echo sendkey ctrl-alt-delete | vm_communicate "${VM_MONITOR}"
		;;
	*)
		err_vm "${VM_NAME}"  ${ERR_CANNOTCOMMUNICATETOVM}
		;;
	esac

	cd "$OLDPWD"
}

function vm_pause ()
{
	cd "${IMAGE_BASEPATH}/${VM_NAME}"

	[ -z "${VM_PID}" ] && VM_PID="$(cat vm.pid)"

	case "${VM_MONITOR}" in
	pipe|unix)
		echo stop | vm_communicate "${VM_MONITOR}"
		;;
	*)
		err_vm "${VM_NAME}"  ${ERR_CANNOTCOMMUNICATETOVM}
		;;
	esac

	cd "$OLDPWD"
}

function vm_resume ()
{
	cd "${IMAGE_BASEPATH}/${VM_NAME}"

	[ -z "${VM_PID}" ] && VM_PID="$(cat vm.pid)"

	case "${VM_MONITOR}" in
	pipe|unix)
		echo cont | vm_communicate "${VM_MONITOR}"
		;;
	*)
		err_vm "${VM_NAME}"  ${ERR_CANNOTCOMMUNICATETOVM}
		;;
	esac

	cd "$OLDPWD"
}

function vm_wait ()
{
	cd "${IMAGE_BASEPATH}/${VM_NAME}"

	echo -n "${VM_NAME}"
	while vm_isrunning ${VM_NAME}; do
		echo -n "."
		sleep 1
	done
	echo -n " "

	cd "$OLDPWD"
}

function vm_console ()
{
	cd "${IMAGE_BASEPATH}/${VM_NAME}"

	[ -z "${VM_PID}" ] && VM_PID="$(cat vm.pid)"

	case "${VM_MONITOR}" in
	pipe|unix)
		vm_communicate "${VM_MONITOR}"
		;;
	*)
		err_vm "${VM_NAME}"  ${ERR_CANNOTCOMMUNICATETOVM}
		;;
	esac

	cd "$OLDPWD"
}

function vm_listsnap ()
{
	cd "${IMAGE_BASEPATH}/${VM_NAME}"

	[ -z "${VM_PID}" ] && VM_PID="$(cat vm.pid)"

	case "${VM_MONITOR}" in
	pipe|unix)
		echo info snapshots | vm_communicate "${VM_MONITOR}" -T2 -t2
		;;
	*)
		err_vm "${VM_NAME}"  ${ERR_CANNOTCOMMUNICATETOVM}
		;;
	esac

	cd "$OLDPWD"
}

function vm_addsnap ()
{
	cd "${IMAGE_BASEPATH}/${VM_NAME}"

	[ -z "${VM_PID}" ] && VM_PID="$(cat vm.pid)"

	case "${VM_MONITOR}" in
	pipe|unix)
		echo savevm "${SNAPTAG}" | vm_communicate "${VM_MONITOR}"
		;;
	*)
		err_vm "${VM_NAME}"  ${ERR_CANNOTCOMMUNICATETOVM}
		;;
	esac

	cd "$OLDPWD"
}

function vm_delsnap ()
{
	cd "${IMAGE_BASEPATH}/${VM_NAME}"

	[ -z "${VM_PID}" ] && VM_PID="$(cat vm.pid)"

	case "${VM_MONITOR}" in
	pipe|unix)
		echo delvm "${SNAPTAG}" | vm_communicate "${VM_MONITOR}"
		;;
	*)
		err_vm "${VM_NAME}"  ${ERR_CANNOTCOMMUNICATETOVM}
		;;
	esac

	cd "$OLDPWD"
}

function vm_runsnap ()
{
	cd "${IMAGE_BASEPATH}/${VM_NAME}"

	[ -z "${VM_PID}" ] && VM_PID="$(cat vm.pid)"

	case "${VM_MONITOR}" in
	pipe|unix)
		echo loadvm "${SNAPTAG}" | vm_communicate "${VM_MONITOR}"
		;;
	*)
		err_vm "${VM_NAME}"  ${ERR_CANNOTCOMMUNICATETOVM}
		;;
	esac

	cd "$OLDPWD"
}
