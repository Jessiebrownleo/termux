#!/data/data/com.termux/files/usr/bin/bash -e

VERSION=2024022001
BASE_URL=https://kali.download/nethunter-images/current/rootfs
USERNAME=kali

function unsupported_arch() {
    printf "${red}"
    echo "[*] Unsupported Architecture\n\n"
    printf "${reset}"
    exit
}

function ask() {
    while true; do
        prompt="y/n"
        default=

        # Ask the question
        printf "${light_cyan}\n[?] "
        read -p "$1 [$prompt] " REPLY

        # Default?
        if [ -z "$REPLY" ]; then
            REPLY=$default
        fi

        printf "${reset}"

        # Check if the reply is valid
        case "$REPLY" in
            Y*|y*) return 0 ;;
            N*|n*) return 1 ;;
        esac
    done
}

function get_arch() {
    printf "${blue}[*] Checking device architecture ..."
    case $(getprop ro.product.cpu.abi) in
        arm64-v8a)
            SYS_ARCH=arm64
            ;;
        *)
            unsupported_arch
            ;;
    esac
}

function set_strings() {
    CHROOT=kali-${SYS_ARCH}
    IMAGE_NAME=kali-nethunter-rootfs-full-arm64.tar.xz
}

function prepare_fs() {
    unset KEEP_CHROOT
    if [ -d ${CHROOT} ]; then
        if ask "Existing rootfs directory found. Delete and create a new one?" "N"; then
            rm -rf ${CHROOT}
        else
            KEEP_CHROOT=1
        fi
    fi
}

function cleanup() {
    if [ -f ${IMAGE_NAME} ]; then
        if ask "Delete downloaded rootfs file?" "N"; then
            rm -f ${IMAGE_NAME}
        fi
    fi
}

function check_dependencies() {
    printf "${blue}\n[*] Checking package dependencies...${reset}\n"
    apt-get update -y &> /dev/null || apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" dist-upgrade -y &> /dev/null

    for i in proot tar wget; do
        if [ -e $PREFIX/bin/$i ]; then
            echo "  $i is OK"
        else
            printf "Installing ${i}...\n"
            apt install -y $i || {
                printf "${red}ERROR: Failed to install packages.\n Exiting.\n${reset}"
                exit
            }
        fi
    done
    apt upgrade -y
}

function get_rootfs() {
    unset KEEP_IMAGE
    if [ -f ${IMAGE_NAME} ]; then
        if ask "Existing image file found. Delete and download a new one?" "N"; then
            rm -f ${IMAGE_NAME}
        else
            printf "${yellow}[!] Using existing rootfs archive${reset}\n"
            KEEP_IMAGE=1
            return
        fi
    fi
    printf "${blue}[*] Downloading rootfs...${reset}\n\n"
    ROOTFS_URL="${BASE_URL}/${IMAGE_NAME}"
    wget ${EXTRA_ARGS} --continue "${ROOTFS_URL}"
}

function extract_rootfs() {
    if [ -z $KEEP_CHROOT ]; then
        printf "\n${blue}[*] Extracting rootfs... ${reset}\n\n"
        proot --link2symlink tar -xf $IMAGE_NAME 2> /dev/null || :
    else        
        printf "${yellow}[!] Using existing rootfs directory${reset}\n"
    fi
}

function create_launcher() {
    NH_LAUNCHER=${PREFIX}/bin/nethunter
    NH_SHORTCUT=${PREFIX}/bin/nh
    cat > $NH_LAUNCHER <<- EOF
#!/data/data/com.termux/files/usr/bin/bash -e
cd \${HOME}
unset LD_PRELOAD

if [ ! -f $CHROOT/root/.version ]; then
    touch $CHROOT/root/.version
fi

user="$USERNAME"
home="/home/\$user"
start="sudo -u kali /bin/bash"

if grep -q "kali" ${CHROOT}/etc/passwd; then
    KALIUSR="1";
else
    KALIUSR="0";
fi
if [[ \$KALIUSR == "0" || ("\$#" != "0" && ("\$1" == "-r" || "\$1" == "-R")) ]];then
    user="root"
    home="/\$user"
    start="/bin/bash --login"
    if [[ "\$#" != "0" && ("\$1" == "-r" || "\$1" == "-R") ]];then
        shift
    fi
fi

cmdline="proot \\
        --link2symlink \\
        -0 \\
        -r $CHROOT \\
        -b /dev \\
        -b /proc \\
        -b $CHROOT\$home:/dev/shm \\
        -w \$home \\
           /usr/bin/env -i \\
           HOME=\$home \\
           PATH=/usr/local/sbin:/usr/local/bin:/bin:/usr/bin:/sbin:/usr/sbin \\
           TERM=\$TERM \\
           LANG=C.UTF-8 \\
           \$start"

cmd="\$@"
if [ "\$#" == "0" ];then
    exec \$cmdline
else
    \$cmdline -c "\$cmd"
fi
EOF

    chmod 700 $NH_LAUNCHER
    if [ -L ${NH_SHORTCUT} ]; then
        rm -f ${NH_SHORTCUT}
    fi
    if [ ! -f ${NH_SHORTCUT} ]; then
        ln -s ${NH_LAUNCHER} ${NH_SHORTCUT} >/dev/null
    fi
}

function create_kex_launcher() {
    KEX_LAUNCHER=${CHROOT}/usr/bin/kex
    cat > $KEX_LAUNCHER <<- EOF
#!/bin/bash

function start-kex() {
    if [ ! -f ~/.vnc/passwd ]; then
        passwd-kex
    fi
    USR=\$(whoami)
    if [ \$USR == "root" ]; then
        SCREEN=":2"
    else
        SCREEN=":1"
    fi 
    export MOZ_FAKE_NO_SANDBOX=1; export HOME=\${HOME}; export USER=\${USR}; LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libgcc_s.so.1 nohup vncserver \$SCREEN >/dev/null 2>&1 </dev/null
    starting_kex=1
    return 0
}

function stop-kex() {
    vncserver -kill :1 | sed s/"Xtigervnc"/"NetHunter KeX"/
    vncserver -kill :2 | sed s/"Xtigervnc"/"NetHunter KeX"/
    return $?
}

function passwd-kex() {
    vncpasswd
    return $?
}

function status-kex() {
    sessions=\$(vncserver -list | sed s/"TigerVNC"/"NetHunter KeX"/ | sed -e '1d' | grep -E '^[0-9]+' | awk '{print \$1}')
    if [ -z "\$sessions" ]; then
        echo "KeX not running"
        return 0
    fi
    echo "KeX running"
    return 0
}

if [ "\$#" == 0 ]; then
    start-kex
elif [ "\$1" == "stop" ]; then
    stop-kex
elif [ "\$1" == "status" ]; then
    status-kex
elif [ "\$1" == "passwd" ]; then
    passwd-kex
else
    echo "Usage: \$0 [start|stop|status|passwd]"
fi

EOF
    chmod +x $KEX_LAUNCHER
}

function install() {
    check_dependencies
    get_arch
    set_strings
    prepare_fs
    get_rootfs
    extract_rootfs
    create_launcher
    create_kex_launcher
}

install

