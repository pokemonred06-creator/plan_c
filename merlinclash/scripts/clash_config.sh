#!/bin/sh

umask 077
source /jffs/softcenter/scripts/base.sh
source /jffs/softcenter/scripts/clash_base.sh
. /jffs/softcenter/scripts/clash_safe.sh
alias echo_date='echo 【$(date +%Y年%m月%d日\ %X)】:'
alias echo_date2='echo 【$(date +%Y年%m月%d日\ %X)】'
LOG_FILE=/tmp/upload/merlinclash_log.txt
LINUX_VER=$(uname -r|awk -F"." '{print $1$2}')
eval $(dbus export merlinclash_)
mkdir -p /tmp/upload

#内核进程启动成功检测标志
clash_process_started="0"
#ipv6代理标志
ipv6_flag="0"
# 路由标记值
mcrm=${merlinclash_ipt_routingmark_val:-524288}
case "$mcrm" in *[!0-9]*) mcrm=524288 ;; esac
### 全局变量赋值
yamlname=$(mc_selected) || yamlname=
mcenable=${merlinclash_enable}
dnshijacksel=${merlinclash_dns_dnshijack_sw}
dfib=${merlinclash_dns_fakeip_server}
cusruleplan=${merlinclash_acl_plan}
retryTimes=${merlinclash_set_logcheck_val}
tproxymode=${merlinclash_ipt_tproxy_type}
cirswitch=${merlinclash_set_chnroute_sw}
ipv6switch=${merlinclash_ipt_ipv6_sw}
dnsplan=${merlinclash_dns_type}
dnsgoclash=${merlinclash_ipt_proxyrouter_sw}
dnsinclash=${merlinclash_dns_proxydns_sw}

#配置文件路径
yamlpath=/jffs/softcenter/merlinclash/yaml_use/$yamlname.yaml

#IP获取
ISP_DNS1=$(nvram get wan0_dns | sed 's/ /\n/g' | grep -v 0.0.0.0 | grep -v 127.0.0.1 | sed -n 1p)
ISP_DNS2=$(nvram get wan0_dns | sed 's/ /\n/g' | grep -v 0.0.0.0 | grep -v 127.0.0.1 | sed -n 2p)
DHCP_DNS1=$(nvram get dhcp_dns1_x | sed 's/ /\n/g' | grep -v 0.0.0.0 | grep -v 127.0.0.1 | sed -n 1p)
IFIP_DNS1=$(echo $ISP_DNS1 | grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}|:")
IFIP_DNS2=$(echo $ISP_DNS2 | grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}|:")
IFIP_DHCPDNS1=$(echo $DHCP_DNS1 | grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}|:")
lan_ipaddr=$(nvram get lan_ipaddr)
wan_ipaddr=$(nvram get wan0_ipaddr)
#取公网接口-
ip_prefix_hex=$(nvram get lan_ipaddr | awk -F "." '{printf ("0x%02x", $1)} {printf ("%02x", $2)} {printf ("%02x", $3)} {printf ("00/0xffffff00\n")}')
opvpn_prefix_hex=$(nvram get vpn_server_local | awk -F "." '{printf ("0x%02x", $1)} {printf ("%02x", $2)} {printf ("%02x", $3)} {printf ("00/0xffffff00\n")}')
pptpvpn_prefix_hex=$(nvram get pptpd_clients | awk -F "." '{printf ("0x%02x", $1)} {printf ("%02x", $2)} {printf ("%02x", $3)} {printf ("00/0xffffff00\n")}')
ipsec_prefix_hex=$(nvram get ipsec_profile_1 | awk -F "." '{printf ("0x%02x", $1)} {printf ("%02x", $2)} {printf ("%02x", $3)} {printf ("00/0xffffff00\n")}')

mkdir -p /tmp/upload


ipv6_mode(){
	[ -n "$(ip addr | grep -w inet6 | awk '{print $2}')" ] && echo true || echo false
}

get_wan0_cidr() {
	local netmask=$(nvram get wan0_netmask)
	local x=${netmask##*255.}
	set -- 0^^^128^192^224^240^248^252^254^ $(((${#netmask} - ${#x}) * 2)) ${x%%.*}
	x=${1%%$3*}
	suffix=$(($2 + (${#x} / 4)))
	prefix=$(nvram get wan0_ipaddr)
	if [ -n "$prefix" -a -n "$netmask" ]; then
		echo $prefix/$suffix
	else
		echo ""
	fi
}

### 进程启动状态检测
detect_running_status(){
	local BINNAME=$1
	local PIDFILE=$2
	local PID1
	local PID2
	local i=40
	if [ -n "${PIDFILE}" ];then
		until [ -n "${PID1}" -a -n "${PID2}" -a -n $(echo ${PID1} | grep -Eow ${PID2} 2>/dev/null) ]; do
			usleep 250000
			i=$(($i - 1))
			PID1=$(pidof ${BINNAME})
			PID2=$(cat ${PIDFILE})
			if [ "$i" -lt 1 ]; then
				echo_date "$1进程启动失败！" >> $LOG_FILE
				#return 1
				close_in_five
			fi
		done
		echo_date "$1启动成功！pid：${PID2}"
	else
		until [ -n "${PID1}" ]; do
			usleep 250000
			i=$(($i - 1))
			PID1=$(pidof ${BINNAME})
			if [ "$i" -lt 1 ]; then
				echo_date "$1进程启动失败！" >> $LOG_FILE
				#return 1
				close_in_five
			fi
		done
		echo_date "$1启动成功，pid：${PID1}" >> $LOG_FILE
	fi
}

### dnsmasq处理
restart_dnsmasq() {
	local DLC=$(nvram get dns_local_cache)
	if [ "$DLC" == "1" ]; then
		nvram set dns_local_cache=0
		nvram commit
	fi
	# 根据情况写路由本机DNS，Fake ip情况下不可使用MC的代理
	local LOCAL_DNSISP_DNS1=$(nvram get wan0_dns | sed 's/ /\n/g' | grep -v 0.0.0.0 | grep -v 127.0.0.1 | sed -n 1p | grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}|:")
	local LOCAL_DNSISP_DNS2=$(nvram get wan0_dns | sed 's/ /\n/g' | grep -v 0.0.0.0 | grep -v 127.0.0.1 | sed -n 2p | grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}|:")
	local LOCAL_DNSISP_DNSv6=$(nvram get ipv6_get_dns | awk '{print $1}' | grep -v '^::$' | grep -v '^::1$' | head -1)
	if [ "$mcenable" = "1" ] && [ "$dnsinclash" = "1" ] && [ "${clash_process_started}" = "1" ]; then
		# 代理路由dns
		if [ "$dnsplan" = "rh" ]; then
			if [ "$(nvram get smartdns_enable)" == "1" ]; then
				echo "nameserver 127.0.0.1" > /etc/resolv.smartdns
			else
				echo "nameserver 127.0.0.1" > /etc/resolv.conf
			fi
		elif [ -n "$LOCAL_DNSISP_DNS1" ] || [ -n "$LOCAL_DNSISP_DNS2" ] || [ -n "$LOCAL_DNSISP_DNSv6" ]; then
			# 有任何一个 DNS 变量非空 → 写入所有非空的
			if [ "$(nvram get smartdns_enable)" == "1" ]; then
				[ -n "$(cat /tmp/resolv.smartdns | grep 9053)" ] || service restart_wan_dns
			else
				{
					[ -n "$LOCAL_DNSISP_DNS1" ] && echo "nameserver $LOCAL_DNSISP_DNS1"
					[ -n "$LOCAL_DNSISP_DNS2" ] && echo "nameserver $LOCAL_DNSISP_DNS2"
					[ -n "$LOCAL_DNSISP_DNSv6" ] && echo "nameserver $LOCAL_DNSISP_DNSv6"
				} > /etc/resolv.conf
			fi
		fi
	elif [ -n "$LOCAL_DNSISP_DNS1" ] || [ -n "$LOCAL_DNSISP_DNS2" ] || [ -n "$LOCAL_DNSISP_DNSv6" ]; then
		# 非代理路由dns，且有至少一个 DNS 变量非空
		if [ "$(nvram get smartdns_enable)" == "1" ]; then
			[ -n "$(cat /tmp/resolv.smartdns | grep 9053)" ] || service restart_wan_dns
		else
			{
				[ -n "$LOCAL_DNSISP_DNS1" ] && echo "nameserver $LOCAL_DNSISP_DNS1"
				[ -n "$LOCAL_DNSISP_DNS2" ] && echo "nameserver $LOCAL_DNSISP_DNS2"
				[ -n "$LOCAL_DNSISP_DNSv6" ] && echo "nameserver $LOCAL_DNSISP_DNSv6"
			} > /etc/resolv.conf
		fi
	fi
	echo_date "创建dnsmasq.postconf软链接" >> $LOG_FILE
	local link_dns_target=$(readlink "/jffs/scripts/dnsmasq.postconf")
#	local link_sdn_target=$(readlink "/jffs/scripts/dnsmasq-sdn.postconf")
    if [ "$link_dns_target" != "/jffs/softcenter/merlinclash/conf/dnsmasq.postconf" ]; then
        if [ ! -e /jffs/scripts/dnsmasq.postconf ]; then
            ln -s /jffs/softcenter/merlinclash/conf/dnsmasq.postconf /jffs/scripts/dnsmasq.postconf || return 1
        elif ! grep -q '^# BEGIN Magic Catling 2$' /jffs/scripts/dnsmasq.postconf; then
            local userhook wrapper
            userhook=$(mc_mktemp /jffs/scripts/dnsmasq.postconf.user.XXXXXX) || return 1
            cp -p /jffs/scripts/dnsmasq.postconf "$userhook" || return 1
            wrapper=$(mc_mktemp /jffs/scripts/dnsmasq.postconf.wrapper.XXXXXX) || return 1
            printf '#!/bin/sh\n"%s" "$@"\n# BEGIN Magic Catling 2\n[ ! -x /jffs/softcenter/merlinclash/conf/dnsmasq.postconf ] || /jffs/softcenter/merlinclash/conf/dnsmasq.postconf "$@"\n# END Magic Catling 2\n' "$userhook" > "$wrapper" || return 1
            chmod 755 "$wrapper" && mv -f "$wrapper" /jffs/scripts/dnsmasq.postconf || return 1
        fi
    fi
#	if [ "$link_sdn_target" != "/jffs/softcenter/merlinclash/conf/dnsmasq.postconf" ]; then
#		ln -sf /jffs/softcenter/merlinclash/conf/dnsmasq.postconf /jffs/scripts/dnsmasq-sdn.postconf
#	fi
	# Restart dnsmasq
	echo_date "重启dnsmasq服务..." >> $LOG_FILE
	local previous_dns
	previous_dns=$(mc_dnsmasq_owner)
	service restart_dnsmasq >/dev/null 2>&1 || return 1
	mc_dnsmasq_wait "$previous_dns" || {
		echo_date "dnsmasq重启或DNS配置生效超时" >> "$LOG_FILE"
		return 1
	}
}

### ipset处理
creat_ipset() {
	local resolver ipv4_resolvers= ipv6_resolvers=
	#创建直连名单
	xt=`lsmod | grep xt_set`
	OS=$(uname -r)
	if [ -z "$xt" ] && [ -f "/lib/modules/${OS}/kernel/net/netfilter/xt_set.ko" ]; then
		echo_date "加载xt_set.ko内核模块！" >> $LOG_FILE
		modprobe xt_set
	fi
	if [ -z "`lsmod | grep ip_set_bitmap_port`" ] && [ -f "/lib/modules/4.1.27/kernel/net/netfilter/ipset/ip_set_bitmap_port.ko" ]; then
		echo_date "加载ip_set_bitmap_port.ko内核模块！"
		modprobe ip_set_bitmap_port
	fi
	[ -n "$IFIP_DNS1" ] && ISP_DNS_a="$ISP_DNS1" || ISP_DNS_a=""
	[ -n "$IFIP_DNS2" ] && ISP_DNS_b="$ISP_DNS2" || ISP_DNS_b=""
	[ -n "$IFIP_DHCPDNS1" ] && ISP_DNS_c="$DHCP_DNS1" || ISP_DNS_c=""
	for resolver in $ISP_DNS_a $ISP_DNS_b $ISP_DNS_c; do
		case "$resolver" in *:*) ipv6_resolvers="$ipv6_resolvers $resolver";; *) ipv4_resolvers="$ipv4_resolvers $resolver";; esac
	done
	echo_date "创建内网绕行ipset规则集" >> $LOG_FILE
	ipset -! create direct_list nethash && ipset flush direct_list || return 1
	ip_lan="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4 255.255.255.255 $ipv4_resolvers $(get_wan0_cidr)"
	for ip in $ip_lan; do
		ipset -! add direct_list $ip >/dev/null 2>&1 || return 1
	done
	if [ $(ipv6_mode) == "true" ]; then
		echo_date "创建内网绕行ipv6-ipset规则集" >> $LOG_FILE
		ipset -! create direct_list6 nethash family inet6 && ipset flush direct_list6 || return 1
		ip6_lan="::/128 ::1/128 ::ffff:0:0/96 64:ff9b::/96 100::/64 2001::/32 2001:20::/28 2001:db8::/32 2002::/16 fc00::/7 fe80::/10 ff00::/8"
		for ip6 in $ip6_lan; do
			ipset -! add direct_list6 $ip6 >/dev/null 2>&1 || return 1
		done
		for resolver in $ipv6_resolvers; do
			ipset -! add direct_list6 "$resolver" >/dev/null 2>&1 || return 1
		done
		for a in $(ip addr | grep -w inet6 | awk '{print $2}') ; do 
			ipset -! add direct_list6 $a >/dev/null 2>&1 || return 1
		done
		fake_ip_range6=$(yq eval '.dns.fake-ip-range6' /jffs/softcenter/merlinclash/yaml_dns/fakeip.yaml)
		case "$fake_ip_range6" in ''|null) ;; *) ipset -! add direct_list6 "$fake_ip_range6" nomatch >/dev/null 2>&1 || return 1;; esac
	fi
	#
	echo_date "创建clash相关ipset规则集" >> $LOG_FILE
	ipset -! create router nethash || return 1
	ipset -! create ipset_proxy nethash || return 1
	ipset -! create ipset_proxy6 hash:net family inet6 || return 1
	ipset -! create ipset_proxyarround nethash || return 1
	ipset -! create ipset_proxyarround6 hash:net family inet6 || return 1
	
	if [ ! -f "/jffs/softcenter/res/china_ip_route.ipset" ]; then
		echo_date "创建大陆IP绕行ipset规则集" >> $LOG_FILE
		cp /jffs/softcenter/merlinclash/yaml_basic/ChinaIP.yaml /tmp/china_ip_route.list 2>/dev/null
		sed -i "s/'//g" /tmp/china_ip_route.list 2>/dev/null
		sed -i "s/^ \{0,\}- //g" /tmp/china_ip_route.list 2>/dev/null
		sed -i '/payload:/d' /tmp/china_ip_route.list 2>/dev/null
		sed -i '/^ \{0,\}#/d' /tmp/china_ip_route.list 2>/dev/null
		echo "create china_ip_route hash:net family inet hashsize 1024 maxelem 65536" >/jffs/softcenter/res/china_ip_route.ipset
		awk '!/^$/&&!/^#/{printf("add china_ip_route %s'" "'\n",$0)}' /tmp/china_ip_route.list >>/jffs/softcenter/res/china_ip_route.ipset
		rm -rf /tmp/china_ip_route.list 2>/dev/null
	fi
	ipset -! create china_ip_route hash:net family inet hashsize 1024 maxelem 65536 || return 1
	ipset flush china_ip_route 2>/dev/null || return 1
	ipset -! restore </jffs/softcenter/res/china_ip_route.ipset 2>/dev/null || return 1

	if [ $(ipv6_mode) == "true" ]; then
		ipset -! create china_ip_route6 hash:net family inet6 || return 1
		if [ ! -f "/jffs/softcenter/res/china_ip_route6.ipset" ]; then
			echo_date "创建大陆IP绕行ipv6-ipset规则集" >> $LOG_FILE
			cp /jffs/softcenter/merlinclash/yaml_basic/ChinaIPv6.yaml /tmp/china_ip_route6.list 2>/dev/null
			sed -i "s/'//g" /tmp/china_ip_route6.list 2>/dev/null
			sed -i "s/^ \{0,\}- //g" /tmp/china_ip_route6.list 2>/dev/null
			sed -i '/payload:/d' /tmp/china_ip_route6.list 2>/dev/null
			sed -i '/^ \{0,\}#/d' /tmp/china_ip_route6.list 2>/dev/null
			echo "create china_ip_route6 hash:net family inet6" >/jffs/softcenter/res/china_ip_route6.ipset
			awk '!/^$/&&!/^#/{printf("add china_ip_route6 %s'" "'\n",$0)}' /tmp/china_ip_route6.list >>/jffs/softcenter/res/china_ip_route6.ipset
			rm -rf /tmp/china_ip_route6.list 2>/dev/null
		fi	
		ipset flush china_ip_route6 2>/dev/null || return 1
		ipset -! restore </jffs/softcenter/res/china_ip_route6.ipset 2>/dev/null || return 1
	fi
	if [ -f "/jffs/softcenter/merlinclash/yaml_basic/ipsetproxy.yaml" ]; then
		echo_date "开始创建强制转发规则到ipset规则集..." >> $LOG_FILE
		sh /jffs/softcenter/scripts/clash_ipsetproxy.sh 1 ipsetproxy || return 1
	fi
	if [ -f "/jffs/softcenter/merlinclash/yaml_basic/ipsetproxyarround.yaml" ]; then
		echo_date "开始创建强制绕行规则到ipset规则集..." >> $LOG_FILE
		sh /jffs/softcenter/scripts/clash_ipsetproxy.sh 1 ipsetproxyarround || return 1
	fi

}

clean_ipset(){
	rm -rf /jffs/softcenter/merlinclash/conf/ipsetproxyarround.conf >/dev/null 2>&1
	rm -rf /tmp/etc/dnsmasq.user/ipsetproxyarround.conf >/dev/null 2>&1
	rm -rf /jffs/softcenter/merlinclash/conf/ipsetproxy.conf >/dev/null 2>&1
	rm -rf /tmp/etc/dnsmasq.user/ipsetproxy.conf >/dev/null 2>&1
}

### 启动准备
check_ss(){
	local ss_open=$(dbus get ss_basic_enable)
	
	if [ "${ss_open}" == "1" ]; then
    	echo_date "检测到【科学上网】插件运行中，请先关闭该插件，再运行MerlinClash！" >> $LOG_FILE
		echo_date "...MerlinClash！退出中..." >> $LOG_FILE
		return 1
    else
	    echo_date "没有检测到冲突插件，准备开启MerlinClash！" >> $LOG_FILE
	fi
}

check_yaml(){
    local source="${MC_FORCE_SOURCE:-$MC_ROOT/yaml_bak/$yamlname.yaml}" golden
    mc_valid_name "$yamlname" || return 1
    if ! mc_validate_yaml "$source"; then
        source="$MC_ROOT/yaml_use/$yamlname.yaml"
        if ! mc_validate_yaml "$source"; then
            golden=$(ls -1 "$MC_ROOT/yaml_bak/$yamlname.yaml".golden-* 2>/dev/null | sort | tail -1)
            [ -n "$golden" ] && mc_validate_yaml "$golden" || return 1
            source="$golden"
        fi
    fi
    cp -p "$source" "$yamlpath" || return 1
    complete_profile=0
    if [ "$(yq e '.dns != null and .redir-port != null' "$yamlpath")" = true ]; then
        complete_profile=1
        return 0
    fi
    printf '\n' >> "$yamlpath" || return 1
    cat "$MC_ROOT/yaml_basic/head.yaml" "$MC_ROOT/yaml_basic/hosts.yaml" >> "$yamlpath" || return 1
    if [ "${merlinclash_dns_sniffer_sw}" = 1 ]; then
        cat "$MC_ROOT/yaml_basic/sniffer.yaml" >> "$yamlpath" || return 1
    fi
}

check_dnsplan(){
	[ "${complete_profile:-0}" = 1 ] && return 0
	#插入换行符免得出错
	sed -i '$a' $yamlpath
	case $dnsplan in
	rh)
		#默认方案
		echo_date "使用DNS方案为：Redir-Host" >> $LOG_FILE
		cat /jffs/softcenter/merlinclash/yaml_dns/redirhost.yaml >> $yamlpath
		;;
	fi)
		#fake-ip方案
		echo_date "使用DNS方案为：Fake-IP" >> $LOG_FILE
		cat /jffs/softcenter/merlinclash/yaml_dns/fakeip.yaml >> $yamlpath
		;;
	esac

}
check_rule() {
    local custom_file reverse_rules mc_rule mc_rule_type
    mc_valid_name "$yamlname" || return 1
    MC_REQUEST_PROFILE="$yamlname" /bin/sh /jffs/softcenter/scripts/clash_saveacls.sh push push || return 1
    custom_file="/jffs/softcenter/merlinclash/rule_custom/${yamlname}_custom_rule.yaml"
    [ -f "$custom_file" ] || return 0
    reverse_rules=$(mc_mktemp /tmp/clash-custom-rules.XXXXXX) || return 1
    # Build from the captured profile file. UI DBus fields may change while a
    # startup holds the lifecycle lock, and are only a display/editing copy.
    awk '{ sub(/\r$/, ""); if (NF) rules[++n]=$0 } END { for(i=n;i>0;i--)print rules[i] }' "$custom_file" > "$reverse_rules" || { rm -f "$reverse_rules"; return 1; }
    while IFS= read -r mc_rule || [ -n "$mc_rule" ]; do
        mc_rule_type=${mc_rule%%,*}
        case "$mc_rule_type" in
            IP-CIDR|IP-CIDR6)
                case "$mc_rule" in *,no-resolve|*,no-resolve,*) ;; *) mc_rule="$mc_rule,no-resolve" ;; esac
                ;;
        esac
        # Prepending reversed records preserves original order and the complete
        # MATCH/AND/etc. rule syntax instead of rebuilding comma-delimited parts.
        MC_RULE="$mc_rule" yq eval '.rules = [strenv(MC_RULE)] + (.rules // [])' -i "$yamlpath" || { rm -f "$reverse_rules"; return 1; }
    done < "$reverse_rules"
    rm -f "$reverse_rules"
}

set_Tolerance(){
    if [ "${merlinclash_set_interval_sw}" = 1 ]; then
        case "$merlinclash_set_interval_val" in ''|*[!0-9]*) return 1 ;; esac
        MC_VALUE="$merlinclash_set_interval_val" yq e -i '(.proxy-groups[] | select(.type == "url-test" or .type == "fallback" or .type == "load-balance")).interval = env(MC_VALUE)' "$yamlpath" || return 1
    fi
    if [ "${merlinclash_set_tolerance_sw}" = 1 ]; then
        case "$merlinclash_set_tolerance_val" in ''|*[!0-9]*) return 1 ;; esac
        MC_VALUE="$merlinclash_set_tolerance_val" yq e -i '(.proxy-groups[] | select(.type == "url-test" or .type == "fallback" or .type == "load-balance")).tolerance = env(MC_VALUE)' "$yamlpath" || return 1
    fi
    return 0
}

check_coremark(){
	# 查看当前/jffs的挂载点是什么设备，如/dev/mtdblock9, /dev/sda1；有usb2jffs的时候，/dev/sda1，无usb2jffs的时候，/dev/mtdblock9，出问题未正确挂载的时候，为空
	local cur_patition=$(df -h | /bin/grep /jffs | awk '{print $1}')
	local jffs_device="not mount"
	if [ -n "${cur_patition}" ]; then
  		jffs_device=${cur_patition}
	fi
	local mounted_nu=$(mount | /bin/grep "${jffs_device}" | grep -E "/tmp/mnt/|/jffs"|/bin/grep -c "/dev/s")

	if [ "${merlinclash_set_recordbycron_sw}" != "1" ]; then
		if [ "${mounted_nu}" -eq "2" ]; then
			coremark="1"
		elif [ "${LINUX_VER}" -gt "41" ]; then
			coremark="1"
		else
			coremark="0"
		fi
	else
		echo_date "已开启强制使用定时脚本记录代理组状态" >> $LOG_FILE
		coremark="0"
	fi
	#更新内核版本号
	local ret=$(env -i PATH=${PATH} /jffs/softcenter/bin/clash -v 2>/dev/null | head -n 1)
	local ver=$(echo "$ret" | awk '{if ($2=="Meta") print $1" "$2" "$3; else print $1" "$2}')
	[ -n "$ver" ] && dbus set merlinclash_binary_ver="$ver"

}

start_custom(){

    #内核代理组状态记忆&fake-ip缓存启用
	if [ "${coremark}" == "1" ]; then
		echo_date "开启内核代理组状态记忆及Fake-ip缓存" >> $LOG_FILE
		yq eval ".profile.store-selected = true" -i "$yamlpath"
		yq eval ".profile.store-fake-ip = true" -i "$yamlpath"
	fi

	#开启tcp并发
	if [ "${merlinclash_set_tcpcon_sw}" == "1" ]; then
		yq eval ".tcp-concurrent = true" -i "$yamlpath"
	fi

	#检查redir/tproxy端口，如果没有就写一个
	proxy_port=$(yq eval ".redir-port" "$yamlpath" 2>/dev/null)
	tproxy_port=$(yq eval ".tproxy-port" "$yamlpath" 2>/dev/null)
	if [ "$tproxymode" == "closed" ] || [ "$tproxymode" == "udp" ]; then
		if [ "$proxy_port" == "null" ] || [ -z "$proxy_port" ]; then
			yq eval ".redir-port = 23457" -i "$yamlpath"
		fi
	fi
	if [ "$tproxymode" != "closed" ]; then
		if [ "$tproxy_port" == "null" ] || [ -z "$tproxy_port" ]; then
			yq eval ".tproxy-port = 23458" -i "$yamlpath"
		fi
	fi

	#移除出启动配置文件 http/socks 端口
	if [ "$merlinclash_set_mixport_sw" == "0" ]; then
		echo_date "Http/Socks5代理端口未开启" >> $LOG_FILE
		yq eval -i 'del(.port)' "$yamlpath"
		yq eval -i 'del(.socks-port)' "$yamlpath"
		yq eval -i 'del(.mixed-port)' "$yamlpath"
	fi
	
	#Geo数据库写入
	geoip_lite_url="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip-lite.dat"
	geoip_full_url="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"

	geosite_default_url="https://github.com/flyhigherpi/merlinclash_clash_related/raw/refs/heads/master/geosite/geosite.dat"
	geosite_lite_url="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite-lite.dat"
	geosite_full_url="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"

	if [ "${merlinclash_set_geoip_type}" != "head" ] || [ "${merlinclash_set_geosite_type}" != "head" ]; then
		yq eval ".geodata-mode = true" -i "$yamlpath"
	fi
	case "${merlinclash_set_geoip_type}" in
        lite)
            echo_date "设置GeoIP数据库为：GeoIP-Lite" >> $LOG_FILE
			yq eval ".geox-url.geoip = \"$geoip_lite_url\"" -i "$yamlpath"
			;;

        full)
            echo_date "设置GeoIP数据库为：GeoIP-Full" >> $LOG_FILE
			yq eval ".geox-url.geoip = \"$geoip_full_url\"" -i "$yamlpath"
			;;
		head)
			echo_date "GeoIP数据库跟随基础配置，不操作" >> $LOG_FILE
			;;
        *)
        echo_date "未设置GeoIP类型， 默认设置为GeoIP-lite" >> $LOG_FILE
			yq eval ".geox-url.geoip = \"$geoip_lite_url\"" -i "$yamlpath"
			;;
    esac
	#GeoSite数据库写入
	case "${merlinclash_set_geosite_type}" in
		lite)
			echo_date "设置GeoSite数据库为：GeoSite-Lite" >> $LOG_FILE
			yq eval ".geox-url.geosite = \"$geosite_lite_url\"" -i "$yamlpath"
			;;
		full)
			echo_date "设置GeoSite数据库为：GeoSite-Full" >> $LOG_FILE
			yq eval ".geox-url.geosite = \"$geosite_full_url\"" -i "$yamlpath"
			;;
		default)
			echo_date "设置GeoSite数据库为：GeoSite-default" >> $LOG_FILE
			yq eval ".geox-url.geosite = \"$geosite_default_url\"" -i "$yamlpath"
			;;
		head)
			echo_date "GeoSite数据库跟随基础配置，不操作" >> $LOG_FILE
			;;
		*)
			echo_date "未设置GeoSite类型， 默认设置为GeoSite-default" >> $LOG_FILE
			yq eval ".geox-url.geosite = \"$geosite_default_url\"" -i "$yamlpath"
			;;
	esac

	#设置必要字段
	yq eval ".allow-lan = true" -i "$yamlpath"
	#yq eval '.mode = "rule"' -i "$yamlpath"
	yq eval '.log-level = "error"' -i "$yamlpath"

	#启动时对控制面板IP重赋值
	ecport=$(yq eval '.external-controller | split(":") | .[1]' "$yamlpath" 2>/dev/null)
	if [ -z "$ecport" ] || [ "$ecport" == "null" ]; then
		ecport="9990"
	fi
	yq eval '.external-ui = "dashboard"' -i "$yamlpath"
	yq eval ".external-controller = \"$lan_ipaddr:$ecport\"" -i "$yamlpath"
	#修改管理面板密码
	mds=${merlinclash_set_dashboard_password}
	MC_SECRET="$mds" yq eval '.secret = strenv(MC_SECRET)' -i "$yamlpath"
	echo_date "Controller credential configured" >> "$LOG_FILE"
	#设置mark值
	if [ "${merlinclash_ipt_proxyrouter_sw}" == "1" ]; then
		yq eval ".routing-mark = $mcrm" -i "$yamlpath"
		echo_date "设置路由流量标记值(Routing-Mark)为：$mcrm" >> $LOG_FILE
	fi

	# 开启ipv6赋值
	if [ "$ipv6switch" == "1" ]; then
		echo_date "修改yaml配置文件的IPv6相关设置" >> $LOG_FILE
		yq eval ".ipv6 = true" -i "$yamlpath"
		yq eval ".dns.ipv6 = true" -i "$yamlpath"
	fi
}

apply_dns_settings(){
	# 检测是否在lan设置中是否自定义过dns,如果有给干掉
	if [ "${merlinclash_dns_cleardns_sw}" == "1" ]; then
		echo_date "清除路由自定义DNS" >> $LOG_FILE
		if [ -n "$(nvram get dhcp_dns1_x)" ]; then
			nvram unset dhcp_dns1_x
			nvram commit
		fi
		if [ -n "$(nvram get dhcp_dns2_x)" ]; then
			nvram unset dhcp_dns2_x
			nvram commit
		fi	
	fi

}

#端口取值
get_ports(){
	httpport=$(yq eval ".port" "$yamlpath" 2>/dev/null)
	socksport=$(yq eval ".socks-port" "$yamlpath" 2>/dev/null)
	mixport=$(yq eval ".mixed-port" "$yamlpath" 2>/dev/null)
	proxy_port=$(yq eval ".redir-port" "$yamlpath" 2>/dev/null)
	tproxy_port=$(yq eval ".tproxy-port" "$yamlpath" 2>/dev/null)
	dnslistenport=$(yq eval -r ".dns.listen" "$yamlpath" 2>/dev/null)
    dnslistenport=${dnslistenport##*:}
	ecport=$(yq eval '.external-controller | split(":") | .[1]' "$yamlpath" 2>/dev/null)
}

### 启动
set_sys() {
	# set_ulimit
	ulimit -n 16384
	echo 1 >/proc/sys/vm/overcommit_memory
	if [ -z "$(pidof jitterentropy-rngd)" -a -z "$(pidof haveged)" ];then
		echo_date "启动haveged，为系统提供更多的可用熵！" >> $LOG_FILE
		haveged -w 1024 9>&- >/dev/null 2>&1	
	fi	
}

#fixTimeZone() {
	# 修复日志显示时区问题
#	[ -f "/etc/TZ" ] && grep -q "GMT-8" /etc/TZ 2>/dev/null &&
#	[ ! -e "/etc/localtime" ] && [ -f "/jffs/softcenter/merlinclash/Shanghai" ] &&
#	ln -sf /jffs/softcenter/merlinclash/Shanghai /etc/localtime
#}

startClashNormalOrPerp(){
    mc_retire_supervisors
    [ -z "$(mc_core_pids)" ] || return 1
    # The single minute watchdog owns recovery; no competing restart loop.
    /jffs/softcenter/bin/clash -d "$MC_ROOT" -f "$yamlpath" 9>&- >/tmp/clash_run.log 2>&1 &
    echo $! > /tmp/clash.pid
}

start_clash(){
	echo_date "使用【$yamlname】 配置文件" >> $LOG_FILE
	rm -rf "/tmp/upload/view.txt"
	cp -rf $yamlpath /tmp/upload/view.txt
	echo_date "启动Clash程序" >> $LOG_FILE

	# 启动之前检查下是否需要修复时区
	#fixTimeZone
	# 启动clash，看看是不是需要用Perp守护进程
	startClashNormalOrPerp


	if [ ! $retryTimes ] || [ $retryTimes -lt 20 ];then
		retryTimes=40
		dbus set merlinclash_set_logcheck_val=40
	fi

	echo_date "启动Clash程序完毕，Clash启动日志位置：/tmp/clash_run.log" >> $LOG_FILE
	echo_date "正在检查Clash进程启动是否报错，请稍候！" >> $LOG_FILE
	echo_date "尝试重试检查日志次数：$retryTimes 次"  >> $LOG_FILE
	
	until [ "$(pidof clash)" -a "$(netstat -anp | grep clash |head -n 5)" -a ! -n "$(grep "Parse config error" /tmp/clash_run.log | head -n 5)" ]; do
		if [ "$retryTimes" -lt 1 ]; then
    		echo_date "Clash 进程启动失败！请检查配置文件是否存在问题，即将退出" >> $LOG_FILE
    		echo_date "失败原因：" >> $LOG_FILE
    		error1=$(cat /tmp/clash_run.log | grep -oE "Parse config error.*")
    		error2=$(cat /tmp/clash_run.log | grep -oE "clashconfig.sh.*")
    		error3=$(cat /tmp/clash_run.log | grep -oE "illegal instruction.*")
    		error4=$(cat /tmp/clash_run.log | grep -n "level=error" | head -1 | grep -oE "msg=.*")
    		if [ -n "$error1" ]; then
        		echo_date $error1 >> $LOG_FILE		
    		elif [ -n "$error2" ]; then
        		echo_date $error2 >> $LOG_FILE
    		elif [ -n "$error3" ]; then
        		echo_date $error3 >> $LOG_FILE
    			echo_date "clash二进制故障，请重新上传" >> $LOG_FILE
    		elif [ -n "$error4" ]; then
        		echo_date $error4 >> $LOG_FILE
    		fi
    		dbus set merlinclash_binary_startime=""
    		close_in_five
			return
		fi
		retryTimes=$(($retryTimes - 1))
		usleep 300000
	done
	
	usleep 300000
	echo_date "Clash 进程启动成功！(PID: $(pidof clash))" >> $LOG_FILE
	a_tmp=$(echo_date2)
	dbus set merlinclash_binary_startime=$a_tmp
	clash_process_started="1"
	rm -rf /tmp/upload/*.yaml
}

mc_saved_mark_valid() {
    [ -s "$1" ] && jq -e '(.mark | type == "object") and
        all(.mark[]; (type == "object") and (.now | type == "string")) and
        (.config.mode == "rule" or .config.mode == "global" or .config.mode == "direct")' "$1" >/dev/null 2>&1
}
start_remark(){
    # A fresh checkpoint can supplement native cache without applying a stale
    # record during cold startup or to a different pending profile.
    if [ -s "$MC_ROOT/mark/$yamlname.txt" ]; then
        if ! mc_saved_mark_valid "$MC_ROOT/mark/$yamlname.txt"; then
            echo_date "Saved selectors for $yamlname are invalid; record retained unchanged, using native or default selections" >> "$LOG_FILE"
            return 0
        fi
    elif [ "${coremark}" != "0" ]; then
        return 0
    fi
    if [ "${coremark}" != "0" ] && [ "${MC_FRESH_MARK_PROFILE:-}" != "$yamlname" ]; then
        return 0
    fi
	echo_date -------------------- 📌记录/还原代理组状态 ------------------- >> $LOG_FILE
	MC_REQUEST_PROFILE="$yamlname" /bin/sh /jffs/softcenter/scripts/clash_node_mark.sh remark || return 1
}

### nat加载
load_tproxy() {
	MODULES="nf_tproxy_core xt_TPROXY"
	OS=$(uname -r)
	# load Kernel Modules
	echo_date 加载Tproxy模块，用于UDP转发... >> $LOG_FILE
	checkmoduleisloaded() {
		if lsmod | grep $MODULE &>/dev/null; then return 0; else return 1; fi
	}

	for MODULE in $MODULES; do
		if ! checkmoduleisloaded; then
			if [  "${LINUX_VER}" -eq "419" -o "${LINUX_VER}" -eq "54" ];then
				modprobe ${MODULE}.ko
			else
				insmod /lib/modules/${OS}/kernel/net/netfilter/${MODULE}.ko
			fi
		fi
	done

	modules_loaded=0

	for MODULE in $MODULES; do
		if checkmoduleisloaded; then
			modules_loaded=$((j++))
		fi
	done
}

mc_create_firewall_targets() {
    local table
    # This kernel has no comment match. Owned child targets identify global
    # rules without additional modules; goto preserves the caller RETURN.
    iptables -t nat -N merlinclash_DNS53 2>/dev/null || :
    iptables -t nat -F merlinclash_DNS53 || return 1
    iptables -t nat -A merlinclash_DNS53 -p udp -j REDIRECT --to-ports 53 || return 1
    iptables -t nat -A merlinclash_DNS53 -p tcp -j REDIRECT --to-ports 53 || return 1
    for table in nat mangle; do
        iptables -t "$table" -N merlinclash_RETURN 2>/dev/null || :
        iptables -t "$table" -F merlinclash_RETURN || return 1
        iptables -t "$table" -A merlinclash_RETURN -j RETURN || return 1
    done
}

load_nat() {
	nat_ready=$(iptables -t nat -L PREROUTING -v -n --line-numbers | grep -v PREROUTING | grep -v destination)
	i=120
	until [ -n "$nat_ready" ]; do
		i=$(($i - 1))
		if [ "$i" -lt 1 ]; then
			echo_date "【错误】加载nat规则失败! 注意：路由AP模式下不能使用透明代理" >> $LOG_FILE
			close_in_five
		fi
		sleep 1s
		nat_ready=$(iptables -t nat -L PREROUTING -v -n --line-numbers | grep -v PREROUTING | grep -v destination)
	done
	echo_date "加载nat规则!" >> $LOG_FILE
	sleep 1s
    mc_create_firewall_targets || return 1
	apply_nat_rules || return 1
    sh /jffs/softcenter/scripts/clash_dns_tcp.sh || return 1
}

#设备绕行
get_method_name(){
	case "$1" in
	1)
		echo "IP + MAC匹配"
		;;
	2)
		echo "仅IP匹配"
		;;
	3)
		echo "仅MAC匹配"
		;;
	esac
}

get_mode_name() {
	case "$1" in
	0)
		echo "不通过代理"
		;;
	1)
		echo "通过clash"
		;;
	esac
}

factor() {
	if [ -z "$1" ] || [ -z "$2" ]; then
		echo ""
	else
		echo "$2 $1"
	fi
}

get_jump_mode() {
	case "$1" in
	0)
		echo "j"
		;;
	*)
		echo "g"
		;;
	esac
}

get_action_chain() {
	case "$1" in
	0)
		echo "RETURN"
		;;
	1)
		if [ "$cirswitch" == "1" ]; then
			echo "merlinclash_CHN"
		else
			echo "merlinclash_NOR"
		fi
		;;
	esac
}

lan_bypass(){
    mc_insert_dns53() {
        local snapshot count position
        snapshot=$(iptables -t nat -S PREROUTING 2>/dev/null) || return 1
        count=$(printf '%s\n' "$snapshot" | awk '$1=="-A" {n++} END {print n+0}')
        position=3
        [ "$count" -ge 2 ] || position=$((count+1))
        iptables -t nat -I PREROUTING "$position" -p udp --dport 53 -j merlinclash_DNS53 >/dev/null 2>&1 || return 1
    }
	# deivce_nu 获取已存数据序号
	echo_date --------------------- 📌写入访问控制规则 --------------------- >> $LOG_FILE
	OS=$(uname -r)
	if lsmod | grep ip_set_hash_mac &>/dev/null; then
		echo_date "ip_set_hash_mac模块已加载" >> $LOG_FILE; 
	else
		#检查是否固件是否有ip_set_hash_mac模块
		if [ -f "/lib/modules/${OS}/kernel/net/netfilter/ipset/ip_set_hash_mac.ko" ]; then
			echo_date "加载MAC地址过滤模块" >> $LOG_FILE; 
			modprobe ip_set_hash_mac
		fi
	fi
	mnm=$(dbus get merlinclash_nokpacl_method)
	# Fresh starts have no owned sets after flush_nat. Create before flushing,
	# and clear the applicable sets even when the last ACL row was removed.
	if [ "$mnm" != "2" ]; then
		for set in lan_mac_blacklist lan_mac_whitelist macblacklist_dns macwhitelist_dns; do
			ipset -! create "$set" hash:mac hashsize 1024 maxelem 65536 || return 1
			ipset flush "$set" || return 1
		done
	fi
	if [ "$mnm" != "3" ]; then
		for set in lan_ip_blacklist lan_ip_whitelist ipblacklist_dns ipwhitelist_dns; do
			ipset -! create "$set" hash:net family inet hashsize 1024 maxelem 65536 || return 1
			ipset flush "$set" || return 1
		done
	fi
	echo_date "已设置【$(get_method_name $mnm)】过滤" >> $LOG_FILE
	list_flag="0"
	if [ "$tproxymode" == "closed" ] || [ "$tproxymode" == "udp" ]; then
		list_flag="1" #REDIR-TCP / TPROXY-UDP
	elif [ "$tproxymode" == "tcp" ] || [ "$tproxymode" == "tcpudp" ]; then
		list_flag="2" #TPROXY-TCP / TCP&UDP
	fi
	nokpacl_nu=$(get_list merlinclash_nokpacl_ip 1 4)

	echo "create macblacklist_dns hash:mac hashsize 1024 maxelem 65536" >/jffs/softcenter/res/macblacklist_dns.ipset
	echo "create macwhitelist_dns hash:mac hashsize 1024 maxelem 65536" >/jffs/softcenter/res/macwhitelist_dns.ipset
	echo "create ipblacklist_dns hash:net family inet hashsize 1024 maxelem 65536" >/jffs/softcenter/res/ipblacklist_dns.ipset
	echo "create ipwhitelist_dns hash:net family inet hashsize 1024 maxelem 65536" >/jffs/softcenter/res/ipwhitelist_dns.ipset
	if [ "$mnm" != "3" ]; then
		echo "create lan_ip_blacklist hash:net family inet hashsize 1024 maxelem 65536" >/jffs/softcenter/res/lan_ip_blacklist.ipset
		echo "create lan_ip_whitelist hash:net family inet hashsize 1024 maxelem 65536" >/jffs/softcenter/res/lan_ip_whitelist.ipset
	fi
	if [ "$mnm" != "2" ]; then
		echo "create lan_mac_blacklist hash:mac hashsize 1024 maxelem 65536" >/jffs/softcenter/res/lan_mac_blacklist.ipset
		echo "create lan_mac_whitelist hash:mac hashsize 1024 maxelem 65536" >/jffs/softcenter/res/lan_mac_whitelist.ipset	
	fi
	if [ "$list_flag" == "1" ]; then
		if [ -n "$nokpacl_nu" ]; then
			for nokpacl in $nokpacl_nu; do
				echo_date "处理当前第$nokpacl条规则" >> $LOG_FILE
				ipaddr=$(eval echo \$merlinclash_nokpacl_ip_$nokpacl)
				if [ -z "$(echo "$ipaddr" | grep "/")" ]; then
    				ipaddr="${ipaddr}/32"
				fi
				macaddr=$(eval echo \$merlinclash_nokpacl_mac_$nokpacl)
				ports=$(eval echo \$merlinclash_nokpacl_port_$nokpacl)
				proxy_mode=$(eval echo \$merlinclash_nokpacl_mode_$nokpacl) #0不通过clash  1通过clash
				proxy_name=$(eval echo \$merlinclash_nokpacl_name_$nokpacl)
				[ "$mnm" == "1" ] && echo_date "设备IP地址：【$ipaddr】，MAC地址：【$macaddr】，端口：【$ports】，代理模式：【$(get_mode_name $proxy_mode)】" >> $LOG_FILE
				[ "$mnm" == "2" ] && macaddr="" && echo_date "设备IP地址：【$ipaddr】，端口：【$ports】，代理模式：【$(get_mode_name $proxy_mode)】" >> $LOG_FILE
				[ "$mnm" == "3" ] && ipaddr="" && echo_date "设备MAC地址：【$macaddr】，端口：【$ports】，代理模式：【$(get_mode_name $proxy_mode)】" >> $LOG_FILE
				if [ "$mnm" == "3" ] && [ "$macaddr" == "" ]; then
					echo_date "设备$proxy_name MAC地址为空，跳过处理。" >> $LOG_FILE
					continue
				fi
				if [ "$mnm" == "2" ] && [ "$ipaddr" == "" ]; then
					echo_date "设备$proxy_name IP地址为空，跳过处理。" >> $LOG_FILE
					continue
				fi
				if [ "$mnm" == "1" ] && [ "$macaddr" == "" ] && [ "$ipaddr" == "" ]; then
					echo_date "设备$proxy_name MAC地址和IP地址都为空，跳过处理。" >> $LOG_FILE
					continue
				fi
				if [ "$proxy_mode" == "0" ]; then
					# echo_date "$proxy_name 不走代理，添加进黑名单集和绕行DNS集" >> $LOG_FILE
					[ -n "$macaddr" ] && echo "add lan_mac_blacklist ${macaddr}" >> /jffs/softcenter/res/lan_mac_blacklist.ipset
					[ -n "$macaddr" ] && echo "add macblacklist_dns ${macaddr}" >> /jffs/softcenter/res/macblacklist_dns.ipset
					[ -n "$ipaddr" ] && echo "add lan_ip_blacklist ${ipaddr}" >> /jffs/softcenter/res/lan_ip_blacklist.ipset
					[ -n "$ipaddr" ] && echo "add ipblacklist_dns ${ipaddr}" >> /jffs/softcenter/res/ipblacklist_dns.ipset
				fi
				if [ "$proxy_mode" == "1" ] && [ "$ports" == "all" ]; then
					# echo_date "$proxy_name 全端口转发进Clash，添加进白名单集和转发DNS集" >> $LOG_FILE
					[ -n "$macaddr" ] && echo "add lan_mac_whitelist ${macaddr}" >> /jffs/softcenter/res/lan_mac_whitelist.ipset
					[ -n "$macaddr" ] && echo "add macwhitelist_dns ${macaddr}" >> /jffs/softcenter/res/macwhitelist_dns.ipset
					[ -n "$ipaddr" ] && echo "add lan_ip_whitelist ${ipaddr}" >> /jffs/softcenter/res/lan_ip_whitelist.ipset
					[ -n "$ipaddr" ] && echo "add ipwhitelist_dns ${ipaddr}" >> /jffs/softcenter/res/ipwhitelist_dns.ipset
				fi
				if [ "$proxy_mode" == "1" ] && [ "$ports" != "all" ]; then
					# echo_date "$proxy_name 指定端口转发进Clash，添加进转发DNS集" >> $LOG_FILE
					[ -n "$macaddr" ] && echo "add macwhitelist_dns ${macaddr}" >> /jffs/softcenter/res/macwhitelist_dns.ipset
					[ -n "$ipaddr" ] && echo "add ipwhitelist_dns ${ipaddr}" >> /jffs/softcenter/res/ipwhitelist_dns.ipset
				fi
				if [ "$ports" == "all" ]; then
					ports=""
				fi
				#访问自定端口走代理
				if [ "$proxy_mode" == "1" ] && [ "$ports" != "" ]; then
					# echo_date "$proxy_name 访问指定端口【$ports】转发进Clash" >> $LOG_FILE
					iptables -t nat -A merlinclash $(factor $ipaddr "-s") $(factor $macaddr "-m mac --mac-source") -p tcp $(factor $ports "-m multiport ! --dport") -j RETURN || return 1
					iptables -t nat -A merlinclash $(factor $ipaddr "-s") $(factor $macaddr "-m mac --mac-source") -p tcp $(factor $ports "-m multiport --dport") -$(get_jump_mode $proxy_mode) $(get_action_chain $proxy_mode) || return 1
					
					if [ "$tproxymode" == "udp" ]; then
						iptables -t mangle -A merlinclash_PREROUTING $(factor $ipaddr "-s") $(factor $macaddr "-m mac --mac-source") -p udp $(factor $ports "-m multiport --dport") -j merlinclash || return 1
						iptables -t mangle -A merlinclash_PREROUTING $(factor $ipaddr "-s") $(factor $macaddr "-m mac --mac-source") -p udp -j RETURN || return 1
						
					fi
				fi
			done
			if [ "$mnm" != "2" ]; then
				ipset -! flush lan_mac_blacklist 2>/dev/null || return 1
				ipset -! restore </jffs/softcenter/res/lan_mac_blacklist.ipset 2>/dev/null || return 1
				ipset -! flush macblacklist_dns 2>/dev/null || return 1
				ipset -! restore </jffs/softcenter/res/macblacklist_dns.ipset 2>/dev/null || return 1
				ipset -! flush lan_mac_whitelist 2>/dev/null || return 1
				ipset -! restore </jffs/softcenter/res/lan_mac_whitelist.ipset 2>/dev/null || return 1
				ipset -! flush macwhitelist_dns 2>/dev/null || return 1
				ipset -! restore </jffs/softcenter/res/macwhitelist_dns.ipset 2>/dev/null || return 1
			fi
			if [ "$mnm" != "3" ]; then
				ipset -! flush lan_ip_blacklist 2>/dev/null || return 1
				ipset -! restore </jffs/softcenter/res/lan_ip_blacklist.ipset 2>/dev/null || return 1
				ipset -! flush ipblacklist_dns 2>/dev/null || return 1
				ipset -! restore </jffs/softcenter/res/ipblacklist_dns.ipset 2>/dev/null || return 1
				ipset -! flush lan_ip_whitelist 2>/dev/null || return 1
				ipset -! restore </jffs/softcenter/res/lan_ip_whitelist.ipset 2>/dev/null || return 1
				ipset -! flush ipwhitelist_dns 2>/dev/null || return 1
				ipset -! restore </jffs/softcenter/res/ipwhitelist_dns.ipset 2>/dev/null || return 1
			fi
			#IPTABLES写法
			#1.黑名单内先过滤
			#iptables写法
			if [ "$mnm" != "2" ]; then iptables -t nat -I merlinclash -m set --match-set lan_mac_blacklist src -p tcp -j RETURN >/dev/null 2>&1 || return 1; fi
			if [ "$mnm" != "3" ]; then iptables -t nat -I merlinclash -m set --match-set lan_ip_blacklist src -p tcp -j RETURN >/dev/null 2>&1 || return 1; fi
			if [ "$tproxymode" == "udp" ]; then
				iptables -t mangle -I merlinclash_PREROUTING -p udp --dport 53 -j RETURN || return 1
				if [ "$mnm" != "2" ]; then iptables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_mac_blacklist src -p udp -j RETURN >/dev/null 2>&1 || return 1; fi
				if [ "$mnm" != "3" ]; then iptables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_ip_blacklist src -p udp -j RETURN >/dev/null 2>&1 || return 1; fi
			fi

			#2.白名单内再放行
			if [ "$cirswitch" == "1" ]; then
				echo_date "设置白名单进入merlinclash_CHN链" >> $LOG_FILE
				if [ "$mnm" != "2" ]; then iptables -t nat -A merlinclash -m set --match-set lan_mac_whitelist src -p tcp -j merlinclash_CHN || return 1; fi
				if [ "$mnm" != "3" ]; then iptables -t nat -A merlinclash -m set --match-set lan_ip_whitelist src -p tcp -j merlinclash_CHN || return 1; fi

				if [ "$tproxymode" == "udp" ]; then
						if [ "$mnm" != "2" ]; then iptables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_mac_whitelist src -p udp  -j merlinclash || return 1; fi
						if [ "$mnm" != "3" ]; then iptables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_ip_whitelist src -p udp  -j merlinclash || return 1; fi
				fi
			else
				echo_date "设置白名单进入merlinclash_NOR链" >> $LOG_FILE	
				if [ "$mnm" != "2" ]; then iptables -t nat -A merlinclash -m set --match-set lan_mac_whitelist src -p tcp -j merlinclash_NOR || return 1; fi
				if [ "$mnm" != "3" ]; then iptables -t nat -A merlinclash -m set --match-set lan_ip_whitelist src -p tcp -j merlinclash_NOR || return 1; fi
				if [ "$tproxymode" == "udp" ]; then
							if [ "$mnm" != "2" ]; then iptables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_mac_whitelist src -p udp  -j merlinclash || return 1; fi
							if [ "$mnm" != "3" ]; then iptables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_ip_whitelist src -p udp  -j merlinclash || return 1; fi
				fi
			fi
			#3.剩余主机处理
			if [ "$merlinclash_nokpacl_default_port" == "all" ] || [ "$merlinclash_nokpacl_default_port" == "" ] ; then
				merlinclash_nokpacl_default_port=""
				[ -z "$merlinclash_nokpacl_default_mode" ] && dbus set merlinclash_nokpacl_default_mode="0" && merlinclash_nokpacl_default_mode="0"
				echo_date 加载ACl规则：【剩余主机】【全部端口】模式为：$(get_mode_name $merlinclash_nokpacl_default_mode) >> $LOG_FILE
				if [ "$merlinclash_nokpacl_default_mode" == "1" ]; then #剩余主机访问全端口通过clash
					#iptables写法
					#大陆白判断
					if [ "$cirswitch" == "1" ]; then				
						iptables -t nat -A merlinclash -p tcp -j merlinclash_CHN || return 1
					else
						iptables -t nat -A merlinclash -p tcp -j merlinclash_NOR || return 1
					fi
					if [ "$dnshijacksel" == "1" ]; then
						iptables -t nat -I PREROUTING -p udp --dport 53 -j merlinclash_DNS53 >/dev/null 2>&1 || return 1
					fi
					if [ "$dnsplan" == "fi" ]; then
						if [ "$mnm" != "2" ]; then
							if [ "$mnm" != "2" ]; then iptables -t nat -I PREROUTING -m set --match-set macblacklist_dns src -p udp --dport 53 -j DNAT --to ${dfib} >/dev/null 2>&1 || return 1; fi
						fi
						if [ "$mnm" != "3" ]; then
							if [ "$mnm" != "3" ]; then iptables -t nat -I PREROUTING -m set --match-set ipblacklist_dns src -p udp --dport 53 -j DNAT --to ${dfib} >/dev/null 2>&1 || return 1; fi
						fi
					fi
					if [ "$tproxymode" == "udp" ]; then
						iptables -t mangle -A merlinclash_PREROUTING -p udp -j merlinclash || return 1
					fi
				else  #剩余主机全端口不通过clash，只给通过clash的设备转发dns端口
					echo_date "剩余主机全端口不通过clash，只给通过Clash的设备转发dns端口" >> $LOG_FILE
					#iptables写法
					if [ "$dnshijacksel" == "1" ]; then
						if [ "$mnm" != "2" ]; then
							if [ "$mnm" != "2" ]; then iptables -t nat -I PREROUTING -m set --match-set macwhitelist_dns src -p udp --dport 53 -j merlinclash_DNS53 >/dev/null 2>&1 || return 1; fi
						fi
						if [ "$mnm" != "3" ]; then
							if [ "$mnm" != "3" ]; then iptables -t nat -I PREROUTING -m set --match-set ipwhitelist_dns src -p udp --dport 53 -j merlinclash_DNS53 >/dev/null 2>&1 || return 1; fi
						fi
					fi
					if [ "$tproxymode" == "udp" ]; then
						iptables -t mangle -A merlinclash_PREROUTING -p udp -j RETURN || return 1 #剩余主机udp流量都不转发
					fi
				fi
			else 
				[ -z "$merlinclash_nokpacl_default_mode" ] && dbus set merlinclash_nokpacl_default_mode="0" && merlinclash_nokpacl_default_mode="0"
				echo_date 加载ACl规则：【剩余主机】【$merlinclash_nokpacl_default_port】模式为：$(get_mode_name $merlinclash_nokpacl_default_mode) >> $LOG_FILE
				if [ "$merlinclash_nokpacl_default_mode" == "1" ]; then #剩余主机访问指定端口通过clash
					#iptables写法
					#大陆白判断
					if [ "$cirswitch" == "1" ]; then	
						iptables -t nat -A merlinclash -p tcp -m multiport ! --dport $merlinclash_nokpacl_default_port -j RETURN || return 1
						iptables -t nat -A merlinclash -p tcp -m multiport --dport $merlinclash_nokpacl_default_port -j merlinclash_CHN || return 1
					else
						iptables -t nat -A merlinclash -p tcp -m multiport --dport $merlinclash_nokpacl_default_port -j merlinclash_NOR || return 1
					fi						
					if [ "$dnshijacksel" == "1" ]; then
						iptables -t nat -I PREROUTING -p udp --dport 53 -j merlinclash_DNS53 >/dev/null 2>&1 || return 1
					fi
					if [ "$dnsplan" == "fi" ]; then
						if [ "$mnm" != "2" ]; then
							if [ "$mnm" != "2" ]; then iptables -t nat -I PREROUTING -m set --match-set macblacklist_dns src -p udp --dport 53 -j DNAT --to ${dfib} >/dev/null 2>&1 || return 1; fi
						fi
						if [ "$mnm" != "3" ]; then
							if [ "$mnm" != "3" ]; then iptables -t nat -I PREROUTING -m set --match-set ipblacklist_dns src -p udp --dport 53 -j DNAT --to ${dfib} >/dev/null 2>&1 || return 1; fi
						fi
					fi
					if [ "$tproxymode" == "udp" ]; then
						iptables -t mangle -A merlinclash_PREROUTING -p udp -m multiport --dport $merlinclash_nokpacl_default_port -j merlinclash || return 1
					
					fi
				fi
			fi
			if [ "${merlinclash_ipt_proxyiot_sw}" != "1" ]; then
				iptables -t nat -I PREROUTING -i br1 -g merlinclash_RETURN >/dev/null 2>&1 || return 1
				iptables -t nat -I PREROUTING -i br2 -g merlinclash_RETURN >/dev/null 2>&1 || return 1
				iptables -t nat -I PREROUTING -i br5+ -g merlinclash_RETURN >/dev/null 2>&1 || return 1
			fi
		else
			echo_date "未设置设备绕行，使用默认：全设备转发进Clash" >> $LOG_FILE
			merlinclash_nokpacl_default_mode="1"
			dbus set merlinclash_nokpacl_default_mode="1"
			if [ "$merlinclash_nokpacl_default_port" == "all" ] || [ "$merlinclash_nokpacl_default_port" == "" ] ; then
				merlinclash_nokpacl_default_port=""
				echo_date 加载ACl规则：【全部主机】【全部端口】模式为：$(get_mode_name $merlinclash_nokpacl_default_mode) >> $LOG_FILE
				#iptables写法
				#大陆白判断
				if [ "$cirswitch" == "1" ]; then				
					iptables -t nat -A merlinclash -p tcp -j merlinclash_CHN || return 1
					if [ "$dnshijacksel" == "1" ]; then
							mc_insert_dns53 || return 1
					fi
				else
					iptables -t nat -A merlinclash -p tcp -j merlinclash_NOR || return 1
					if [ "$dnshijacksel" == "1" ]; then
						mc_insert_dns53 || return 1
					fi
				fi
				if [ "$tproxymode" == "udp" ]; then
						iptables -t mangle -A merlinclash_PREROUTING -p udp -j merlinclash || return 1
						iptables -t mangle -I merlinclash_PREROUTING -p udp --dport 53 -j RETURN || return 1
				fi
			else
				echo_date 加载ACL规则：【全部主机】【$merlinclash_nokpacl_default_port】模式为：$(get_mode_name $merlinclash_nokpacl_default_mode) >> $LOG_FILE
			
				#大陆白判断
				if [ "$cirswitch" == "1" ]; then
					iptables -t nat -A merlinclash -p tcp -m multiport --dport $merlinclash_nokpacl_default_port  -j merlinclash_CHN || return 1
					if [ "$dnshijacksel" == "1" ]; then
						iptables -t nat -I PREROUTING -p udp --dport 53 -j merlinclash_DNS53 >/dev/null 2>&1 || return 1
											
					fi
					if [ "$tproxymode" == "udp" ]; then
							iptables -t mangle -A merlinclash_PREROUTING -p udp -m multiport --dport $merlinclash_nokpacl_default_port  -j merlinclash || return 1
					fi
				else
					iptables -t nat -A merlinclash -p tcp -m multiport --dport $merlinclash_nokpacl_default_port  -j merlinclash_NOR || return 1
					if [ "$dnshijacksel" == "1" ]; then
						iptables -t nat -I PREROUTING -p udp --dport 53 -j merlinclash_DNS53 >/dev/null 2>&1 || return 1
					
					fi
					if [ "$tproxymode" == "udp" ]; then
							iptables -t mangle -A merlinclash_PREROUTING -p udp -m multiport --dport $merlinclash_nokpacl_default_port  -j merlinclash || return 1
					fi
				fi
			fi
			if [ "${merlinclash_ipt_proxyiot_sw}" != "1" ]; then
				iptables -t nat -I PREROUTING -i br1 -g merlinclash_RETURN >/dev/null 2>&1 || return 1
				iptables -t nat -I PREROUTING -i br2 -g merlinclash_RETURN >/dev/null 2>&1 || return 1
				iptables -t nat -I PREROUTING -i br5+ -g merlinclash_RETURN >/dev/null 2>&1 || return 1
			fi
		fi
		dbus remove merlinclash_nokpacl_ip
		dbus remove merlinclash_nokpacl_name
		dbus remove merlinclash_nokpacl_mode
		dbus remove merlinclash_nokpacl_port
	fi
	if [ "$list_flag" == "2" ]; then
		if [ -n "$nokpacl_nu" ]; then
			for nokpacl in $nokpacl_nu; do
				echo_date "处理第$nokpacl条规则" >> $LOG_FILE
				ipaddr=$(eval echo \$merlinclash_nokpacl_ip_$nokpacl)
				if [ -z "$(echo "$ipaddr" | grep "/")" ]; then
    				ipaddr="${ipaddr}/32"
				fi
				macaddr=$(eval echo \$merlinclash_nokpacl_mac_$nokpacl)
				ports=$(eval echo \$merlinclash_nokpacl_port_$nokpacl)
				proxy_mode=$(eval echo \$merlinclash_nokpacl_mode_$nokpacl) #0不通过clash  1通过clash
				proxy_name=$(eval echo \$merlinclash_nokpacl_name_$nokpacl)
				[ "$mnm" == "1" ] && echo_date "设备IP地址：【$ipaddr】，MAC地址：【$macaddr】，端口：【$ports】，代理模式：【$(get_mode_name $proxy_mode)】" >> $LOG_FILE
				[ "$mnm" == "2" ] && macaddr="" && echo_date "设备IP地址：【$ipaddr】，端口：【$ports】，代理模式：【$(get_mode_name $proxy_mode)】" >> $LOG_FILE
				[ "$mnm" == "3" ] && ipaddr="" && echo_date "设备MAC地址：【$macaddr】，端口：【$ports】，代理模式：【$(get_mode_name $proxy_mode)】" >> $LOG_FILE
				if [ "$mnm" == "3" ] && [ "$macaddr" == "" ]; then
					echo_date "设备$proxy_name MAC地址为空，跳过处理。" >> $LOG_FILE
					continue
				fi
				if [ "$mnm" == "2" ] && [ "$ipaddr" == "" ]; then
					echo_date "设备$proxy_name IP地址为空，跳过处理。" >> $LOG_FILE
					continue
				fi
				if [ "$mnm" == "1" ] && [ "$macaddr" == "" ] && [ "$ipaddr" == "" ]; then
					echo_date "设备$proxy_name MAC地址和IP地址都为空，跳过处理。" >> $LOG_FILE
					continue
				fi				
				if [ "$proxy_mode" == "0" ] && [ "$ports" == "all" ]; then
					# echo_date "$proxy_name 不走代理，添加进黑名单集和绕行DNS集" >> $LOG_FILE
					[ -n "$macaddr" ] && echo "add lan_mac_blacklist ${macaddr}" >> /jffs/softcenter/res/lan_mac_blacklist.ipset
					[ -n "$macaddr" ] && echo "add macblacklist_dns ${macaddr}" >> /jffs/softcenter/res/macblacklist_dns.ipset
					[ -n "$ipaddr" ] && echo "add lan_ip_blacklist ${ipaddr}" >> /jffs/softcenter/res/lan_ip_blacklist.ipset
					[ -n "$ipaddr" ] && echo "add ipblacklist_dns ${ipaddr}" >> /jffs/softcenter/res/ipblacklist_dns.ipset
				fi
				if [ "$proxy_mode" == "1" ] && [ "$ports" == "all" ]; then
					# echo_date "$proxy_name 全端口转发进Clash，添加进白名单集和转发DNS集" >> $LOG_FILE
					[ -n "$macaddr" ] && echo "add lan_mac_whitelist ${macaddr}" >> /jffs/softcenter/res/lan_mac_whitelist.ipset
					[ -n "$macaddr" ] && echo "add macwhitelist_dns ${macaddr}" >> /jffs/softcenter/res/macwhitelist_dns.ipset
					[ -n "$ipaddr" ] && echo "add lan_ip_whitelist ${ipaddr}" >> /jffs/softcenter/res/lan_ip_whitelist.ipset	
					[ -n "$ipaddr" ] && echo "add ipwhitelist_dns ${ipaddr}" >> /jffs/softcenter/res/ipwhitelist_dns.ipset
				fi
				if [ "$proxy_mode" == "1" ] && [ "$ports" != "all" ]; then
					# echo_date "$proxy_name 指定端口转发进Clash，添加进转发DNS集" >> $LOG_FILE
					[ -n "$macaddr" ] && echo "add macwhitelist_dns ${macaddr}" >> /jffs/softcenter/res/macwhitelist_dns.ipset
					[ -n "$ipaddr" ] && echo "add ipwhitelist_dns ${ipaddr}" >> /jffs/softcenter/res/ipwhitelist_dns.ipset
				fi
				if [ "$ports" == "all" ]; then
					ports=""
				fi
				# 1 acl in SHADOWSOCKS for nat
				#访问自定端口走代理
				# echo_date "iptables优先处理访问自定端口走代理设备：$proxy_name" >> $LOG_FILE
				if [ "$proxy_mode" == "1" ] && [ "$ports" != "" ]; then
					echo_date "$proxy_name 访问指定端口【$ports】走代理" >> $LOG_FILE
					iptables -t mangle -A merlinclash_PREROUTING $(factor $ipaddr "-s") $(factor $macaddr "-m mac --mac-source") -p tcp $(factor $ports "-m multiport --dport") -j merlinclash || return 1
					iptables -t mangle -A merlinclash_PREROUTING $(factor $ipaddr "-s") $(factor $macaddr "-m mac --mac-source") -p tcp -j RETURN || return 1
					if [ "$ipv6_flag" == "1" ]; then
						ip6tables -t mangle -A merlinclash_PREROUTING $(factor $macaddr "-m mac --mac-source") -p tcp $(factor $ports "-m multiport --dport") -j merlinclash || return 1
						ip6tables -t mangle -A merlinclash_PREROUTING $(factor $macaddr "-m mac --mac-source") -p tcp -j RETURN || return 1
					fi
					if [ "$tproxymode" == "tcpudp" ]; then
						echo_date "同时开启Tproxy-TCP&UDP转发" >> $LOG_FILE
						iptables -t mangle -A merlinclash_PREROUTING $(factor $ipaddr "-s") $(factor $macaddr "-m mac --mac-source") -p udp $(factor $ports "-m multiport --dport") -j merlinclash || return 1
						iptables -t mangle -A merlinclash_PREROUTING $(factor $ipaddr "-s") $(factor $macaddr "-m mac --mac-source") -p udp -j RETURN || return 1
						
						if [ "$ipv6_flag" == "1" ]; then
							echo_date "同时开启Tproxy-TCP&UDP转发 | 开启IPV6" >> $LOG_FILE
							ip6tables -t mangle -A merlinclash_PREROUTING $(factor $macaddr "-m mac --mac-source") -p udp $(factor $ports "-m multiport --dport") -j merlinclash || return 1
							ip6tables -t mangle -A merlinclash_PREROUTING $(factor $macaddr "-m mac --mac-source") -p udp -j RETURN || return 1
						fi
					fi
				fi
			done
			if [ "$mnm" != "2" ]; then
				ipset -! flush lan_mac_blacklist 2>/dev/null || return 1
				ipset -! restore </jffs/softcenter/res/lan_mac_blacklist.ipset 2>/dev/null || return 1
				ipset -! flush macblacklist_dns 2>/dev/null || return 1
				ipset -! restore </jffs/softcenter/res/macblacklist_dns.ipset 2>/dev/null || return 1
				ipset -! flush lan_mac_whitelist 2>/dev/null || return 1
				ipset -! restore </jffs/softcenter/res/lan_mac_whitelist.ipset 2>/dev/null || return 1
				ipset -! flush macwhitelist_dns 2>/dev/null || return 1
				ipset -! restore </jffs/softcenter/res/macwhitelist_dns.ipset 2>/dev/null || return 1
			fi
			if [ "$mnm" != "3" ]; then
				ipset -! flush lan_ip_blacklist 2>/dev/null || return 1
				ipset -! restore </jffs/softcenter/res/lan_ip_blacklist.ipset 2>/dev/null || return 1
				ipset -! flush ipblacklist_dns 2>/dev/null || return 1
				ipset -! restore </jffs/softcenter/res/ipblacklist_dns.ipset 2>/dev/null || return 1
				ipset -! flush lan_ip_whitelist 2>/dev/null || return 1
				ipset -! restore </jffs/softcenter/res/lan_ip_whitelist.ipset 2>/dev/null || return 1
				ipset -! flush ipwhitelist_dns 2>/dev/null || return 1
				ipset -! restore </jffs/softcenter/res/ipwhitelist_dns.ipset 2>/dev/null || return 1
			fi

			#IPTABLES写法
			#1.黑名单内先过滤
			#iptables写法
			echo_date "iptables处理中" >> $LOG_FILE		
			echo_date "黑名单内先过滤" >> $LOG_FILE	
			if [ "$mnm" != "2" ]; then iptables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_mac_blacklist src -p tcp -j RETURN >/dev/null 2>&1 || return 1; fi
			if [ "$mnm" != "3" ]; then iptables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_ip_blacklist src -p tcp -j RETURN >/dev/null 2>&1 || return 1; fi
							
			if [ "$tproxymode" == "udp" ] || [ "$tproxymode" == "tcpudp" ]; then
					iptables -t mangle -I merlinclash_PREROUTING -p udp --dport 53 -j RETURN || return 1
					ip6tables -t mangle -I merlinclash_PREROUTING -p udp --dport 53 -j RETURN || return 1
			fi
			if [ "$ipv6_flag" == "1" ]; then
				if [ "$mnm" != "2" ]; then ip6tables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_mac_blacklist src -p tcp -j RETURN >/dev/null 2>&1 || return 1; fi
			fi
			#20201122
			if [ "$tproxymode" == "tcpudp" ]; then
				if [ "$mnm" != "2" ]; then iptables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_mac_blacklist src -p udp -j RETURN >/dev/null 2>&1 || return 1; fi
				if [ "$mnm" != "3" ]; then iptables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_ip_blacklist src -p udp -j RETURN >/dev/null 2>&1 || return 1; fi
				if [ "$ipv6_flag" == "1" ]; then
					if [ "$mnm" != "2" ]; then ip6tables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_mac_blacklist src -p udp -j RETURN >/dev/null 2>&1 || return 1; fi
				fi
			fi
			#2.白名单内再放行
			echo_date "白名单内再放行" >> $LOG_FILE	
			if [ "$cirswitch" == "1" ]; then	
				if [ "$mnm" != "2" ]; then iptables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_mac_whitelist src -p tcp -j merlinclash || return 1; fi
				if [ "$mnm" != "3" ]; then iptables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_ip_whitelist src -p tcp -j merlinclash || return 1; fi
			
				if [ "$ipv6_flag" == "1" ]; then
					if [ "$mnm" != "2" ]; then ip6tables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_mac_whitelist src -p tcp -j merlinclash || return 1; fi
				fi
				if [ "$tproxymode" == "tcpudp" ]; then
						if [ "$mnm" != "2" ]; then iptables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_mac_whitelist src -p udp -j merlinclash || return 1; fi
						if [ "$mnm" != "3" ]; then iptables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_ip_whitelist src -p udp -j merlinclash || return 1; fi
					if [ "$ipv6_flag" == "1" ]; then
						if [ "$mnm" != "2" ]; then ip6tables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_mac_whitelist src -p udp -j merlinclash || return 1; fi
					fi
				fi
			else
				if [ "$mnm" != "2" ]; then iptables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_mac_whitelist src -p tcp -j merlinclash || return 1; fi
				if [ "$mnm" != "3" ]; then iptables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_ip_whitelist src -p tcp -j merlinclash || return 1; fi
				
				if [ "$ipv6_flag" == "1" ]; then
					if [ "$mnm" != "2" ]; then ip6tables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_mac_whitelist src -p tcp -j merlinclash || return 1; fi
				fi
				if [ "$tproxymode" == "tcpudp" ]; then
						if [ "$mnm" != "2" ]; then iptables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_mac_whitelist src -p udp -j merlinclash || return 1; fi
						if [ "$mnm" != "3" ]; then iptables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_ip_whitelist src -p udp -j merlinclash || return 1; fi
					if [ "$ipv6_flag" == "1" ]; then
						if [ "$mnm" != "2" ]; then ip6tables -t mangle -A merlinclash_PREROUTING -m set --match-set lan_mac_whitelist src -p udp -j merlinclash || return 1; fi
					fi
				fi
			fi
			#3.剩余主机处理
			echo_date "剩余主机处理" >> $LOG_FILE	
			if [ "$merlinclash_nokpacl_default_port" == "all" ] || [ "$merlinclash_nokpacl_default_port" == "" ] ; then
				merlinclash_nokpacl_default_port=""
				[ -z "$merlinclash_nokpacl_default_mode" ] && dbus set merlinclash_nokpacl_default_mode="0" && merlinclash_nokpacl_default_mode="0"
				echo_date 加载ACl规则：【剩余主机】【全部端口】模式为：$(get_mode_name $merlinclash_nokpacl_default_mode) >> $LOG_FILE
				if [ "$merlinclash_nokpacl_default_mode" == "1" ]; then #剩余主机访问全端口通过clash
					#iptables写法
					#大陆白判断
						if [ "$dnshijacksel" == "1" ]; then
							iptables -t nat -I PREROUTING -p udp --dport 53 -j merlinclash_DNS53 >/dev/null 2>&1 || return 1
						
							if [ "$dnsplan" == "fi" ]; then
								if [ "$mnm" != "2" ]; then iptables -t nat -I PREROUTING -m set --match-set macblacklist_dns src -p udp --dport 53 -j DNAT --to ${dfib} >/dev/null 2>&1 || return 1; fi
							fi
						
						fi
						iptables -t mangle -A merlinclash_PREROUTING -p tcp -j merlinclash || return 1
						if [ "$ipv6_flag" == "1" ]; then
							ip6tables -t mangle -A merlinclash_PREROUTING -p tcp -j merlinclash || return 1
						fi
						if [ "$tproxymode" == "tcpudp" ]; then
							iptables -t mangle -A merlinclash_PREROUTING -p udp -j merlinclash || return 1
								if [ "$ipv6_flag" == "1" ]; then
									ip6tables -t mangle -A merlinclash_PREROUTING -p udp -j merlinclash || return 1
								fi
						fi 
				else  #剩余主机全端口不通过clash，只给通过clash的设备转发dns端口
					echo_date "剩余主机全端口不通过clash，只给通过clash的设备转发dns端口" >> $LOG_FILE
					#iptables写法
					if [ "$dnshijacksel" == "1" ]; then
						if [ "$mnm" != "2" ]; then
							if [ "$mnm" != "2" ]; then iptables -t nat -I PREROUTING -m set --match-set macwhitelist_dns src -p udp --dport 53 -j merlinclash_DNS53 >/dev/null 2>&1 || return 1; fi
						fi
						if [ "$mnm" != "3" ]; then
							if [ "$mnm" != "3" ]; then iptables -t nat -I PREROUTING -m set --match-set ipwhitelist_dns src -p udp --dport 53 -j merlinclash_DNS53 >/dev/null 2>&1 || return 1; fi
						fi
					fi
				fi
			else
				[ -z "$merlinclash_nokpacl_default_mode" ] && dbus set merlinclash_nokpacl_default_mode="0" && merlinclash_nokpacl_default_mode="0"
				echo_date 加载ACL规则：【剩余主机】【$merlinclash_nokpacl_default_port】模式为：$(get_mode_name $merlinclash_nokpacl_default_mode) >> $LOG_FILE
				if [ "$merlinclash_nokpacl_default_mode" == "1" ]; then #剩余主机访问指定端口通过clash
					#iptables写法
					#大陆白判断
					if [ "$cirswitch" == "1" ]; then				
						iptables -t mangle -A merlinclash_PREROUTING -p tcp -m multiport --dport $merlinclash_nokpacl_default_port -j merlinclash || return 1
						if [ "$ipv6_flag" == "1" ]; then
							ip6tables -t mangle -A merlinclash_PREROUTING -p tcp -m multiport --dport $merlinclash_nokpacl_default_port -j merlinclash || return 1
						fi
						if [ "$dnshijacksel" == "1" ]; then
							iptables -t nat -I PREROUTING -p udp --dport 53 -j merlinclash_DNS53 >/dev/null 2>&1 || return 1
						
							if [ "$dnsplan" == "fi" ]; then
								if [ "$mnm" != "2" ]; then iptables -t nat -I PREROUTING -m set --match-set macblacklist_dns src -p udp --dport 53 -j DNAT --to ${dfib} >/dev/null 2>&1 || return 1; fi
							fi
					
						fi
						if [ "$tproxymode" == "tcpudp" ]; then
							iptables -t mangle -A merlinclash_PREROUTING -p udp -m multiport --dport $merlinclash_nokpacl_default_port -j merlinclash || return 1
							if [ "$ipv6_flag" == "1" ]; then
								ip6tables -t mangle -A merlinclash_PREROUTING -p udp -m multiport --dport $merlinclash_nokpacl_default_port -j merlinclash || return 1
							fi
						fi
					else
						iptables -t mangle -A merlinclash_PREROUTING -p tcp -m multiport --dport $merlinclash_nokpacl_default_port -j merlinclash || return 1
						if [ "$ipv6_flag" == "1" ]; then
							ip6tables -t mangle -A merlinclash_PREROUTING -p tcp -m multiport --dport $merlinclash_nokpacl_default_port -j merlinclash || return 1
						fi
						if [ "$dnshijacksel" == "1" ]; then
							iptables -t nat -I PREROUTING -p udp --dport 53 -j merlinclash_DNS53 >/dev/null 2>&1 || return 1
						
						fi
						if [ "$tproxymode" == "tcpudp" ]; then
							iptables -t mangle -A merlinclash_PREROUTING -p udp -m multiport --dport $merlinclash_nokpacl_default_port -j merlinclash || return 1
							if [ "$ipv6_flag" == "1" ]; then
								ip6tables -t mangle -A merlinclash_PREROUTING -p udp -m multiport --dport $merlinclash_nokpacl_default_port -j merlinclash || return 1
							fi
						fi
					fi
				fi
			fi
			if [ "${merlinclash_ipt_proxyiot_sw}" != "1" ]; then
				iptables -t nat -I PREROUTING -i br1 -g merlinclash_RETURN >/dev/null 2>&1 || return 1
				iptables -t nat -I PREROUTING -i br2 -g merlinclash_RETURN >/dev/null 2>&1 || return 1
				iptables -t nat -I PREROUTING -i br5+ -g merlinclash_RETURN >/dev/null 2>&1 || return 1
			fi
		else
			echo_date "未设置设备绕行，采用默认规则：clash全设备通行" >> $LOG_FILE
			merlinclash_nokpacl_default_mode="1"
			dbus set merlinclash_nokpacl_default_mode="1"
			if [ "$merlinclash_nokpacl_default_port" == "all" ] || [ "$merlinclash_nokpacl_default_port" == "" ] ; then
				merlinclash_nokpacl_default_port=""
				echo_date 加载ACl规则：【全部主机】【全部端口】模式为：$(get_mode_name $merlinclash_nokpacl_default_mode) >> $LOG_FILE
				#iptables写法
					iptables -t mangle -A merlinclash_PREROUTING -p tcp -j merlinclash || return 1
					if [ "$dnshijacksel" == "1" ]; then
						iptables -t nat -I PREROUTING -p udp --dport 53 -j merlinclash_DNS53 >/dev/null 2>&1 || return 1
					fi
					if [ "$tproxymode" == "tcpudp" ]; then
						iptables -t mangle -A merlinclash_PREROUTING -p udp -j merlinclash || return 1
						iptables -t mangle -I merlinclash_PREROUTING -p udp --dport 53 -j RETURN || return 1
					fi
					if [ "$ipv6_flag" == "1" ]; then
						ip6tables -t mangle -A merlinclash_PREROUTING -p tcp -j merlinclash || return 1
							if [ "$tproxymode" == "tcpudp" ]; then
								ip6tables -t mangle -A merlinclash_PREROUTING -p udp -j merlinclash || return 1
								ip6tables -t mangle -I merlinclash_PREROUTING -p udp --dport 53 -j RETURN || return 1
							fi
					fi
			else
				echo_date 加载ACL规则：【全部主机】【$merlinclash_nokpacl_default_port】模式为：$(get_mode_name $merlinclash_nokpacl_default_mode) >> $LOG_FILE
				#大陆白判断
				if [ "$cirswitch" == "1" ]; then
					iptables -t mangle -A merlinclash_PREROUTING -p tcp -m multiport --dport $merlinclash_nokpacl_default_port  -j merlinclash || return 1
					if [ "$ipv6_flag" == "1" ]; then
						ip6tables -t mangle -A merlinclash_PREROUTING -p tcp -m multiport --dport $merlinclash_nokpacl_default_port  -j merlinclash || return 1
					fi
					if [ "$dnshijacksel" == "1" ]; then
						iptables -t nat -I PREROUTING -p udp --dport 53 -j merlinclash_DNS53 >/dev/null 2>&1 || return 1
					fi
					if [ "$tproxymode" == "tcpudp" ]; then
						iptables -t mangle -A merlinclash_PREROUTING -p udp -m multiport --dport $merlinclash_nokpacl_default_port  -j merlinclash || return 1
						if [ "$ipv6_flag" == "1" ]; then
							ip6tables -t mangle -A merlinclash_PREROUTING -p udp -m multiport --dport $merlinclash_nokpacl_default_port  -j merlinclash || return 1
						fi
					fi
				else
					iptables -t mangle -A merlinclash_PREROUTING -p tcp -m multiport --dport $merlinclash_nokpacl_default_port  -j merlinclash || return 1
					if [ "$ipv6_flag" == "1" ]; then
						ip6tables -t mangle -A merlinclash_PREROUTING -p tcp -m multiport --dport $merlinclash_nokpacl_default_port  -j merlinclash || return 1
					fi
					if [ "$dnshijacksel" == "1" ]; then
						iptables -t nat -I PREROUTING -p udp --dport 53 -j merlinclash_DNS53 >/dev/null 2>&1 || return 1
					fi
					if [ "$tproxymode" == "tcpudp" ]; then
						iptables -t mangle -A merlinclash_PREROUTING -p udp -m multiport --dport $merlinclash_nokpacl_default_port  -j merlinclash || return 1
						if [ "$ipv6_flag" == "1" ]; then
							ip6tables -t mangle -A merlinclash_PREROUTING -p udp -m multiport --dport $merlinclash_nokpacl_default_port  -j merlinclash || return 1
						fi
					fi
				fi
				
			fi
			if [ "${merlinclash_ipt_proxyiot_sw}" != "1" ]; then
				iptables -t nat -I PREROUTING -i br1 -g merlinclash_RETURN >/dev/null 2>&1 || return 1
				iptables -t nat -I PREROUTING -i br2 -g merlinclash_RETURN >/dev/null 2>&1 || return 1
				iptables -t nat -I PREROUTING -i br5+ -g merlinclash_RETURN >/dev/null 2>&1 || return 1
			fi
		fi
		dbus remove merlinclash_nokpacl_ip
		dbus remove merlinclash_nokpacl_name
		dbus remove merlinclash_nokpacl_mode
		dbus remove merlinclash_nokpacl_port
	fi
	
}

apply_nat_rules() {
    mc_ensure_policy_rule() {
        local family="$1" mark="$2" snapshot
        snapshot=$(ip "$family" rule show 2>/dev/null) || return 1
        if printf '%s\n' "$snapshot" | awk -v mark="$mark" '
            NF==7 && $1 ~ /^[0-9]+:$/ && $2=="from" && $3=="all" && $4=="fwmark" && $6=="lookup" && $7=="233" {
                value=$5; sub(/\/0xffffffff$/,"",value); if(value==mark) found=1
            }
            END {exit(found ? 0 : 1)}
        '; then return 0; fi
        ip "$family" rule add from all fwmark "$mark/0xffffffff" lookup 233 || return 1
    }
	dem2=$(yq eval ".enhanced-mode" "$yamlpath" 2>/dev/null)
	echo_date "开始写入iptable规则" >> $LOG_FILE

	if [ "$tproxymode" == "closed" ] || [ "$tproxymode" == "udp" ]; then
		echo_date "当前为【Redir TCP】透明代理模式" >> $LOG_FILE
		# ports redirect for clash except port 22 for ssh connection
		echo_date "DNS方案是$dnsplan;配置文件DNS方案是$dem2" >> $LOG_FILE
		echo_date "Lan_ip是$lan_ipaddr" >> $LOG_FILE
		if [ "$ipv6switch" == "1" ] && [ $(ipv6_mode) == "true" ]; then
			ipv6_flag="1"
			echo_date "IPV6-DNS兼容处理" >> $LOG_FILE
		fi
		iptables -t nat -N merlinclash 2>/dev/null || iptables -t nat -S merlinclash >/dev/null 2>&1 || return 1
		echo_date "创建【nat】表【merlinclash】链" >> $LOG_FILE	
		iptables -t nat -N merlinclash_EXT 2>/dev/null || iptables -t nat -S merlinclash_EXT >/dev/null 2>&1 || return 1
		echo_date "创建【nat】表【merlinclash_EXT】链" >> $LOG_FILE
		#ip集强制绕过
		iptables -t nat -A merlinclash -p tcp -m set --match-set ipset_proxyarround dst -j RETURN || return 1
		#局域网&排除地址绕行
		iptables -t nat -A merlinclash -p tcp -m set --match-set direct_list dst -j RETURN || return 1
		iptables -t nat -A merlinclash_EXT -p tcp -m set --match-set direct_list dst -j RETURN || return 1
		# 创建redirhost常规模式nat rule
		
		iptables -t nat -N merlinclash_NOR 2>/dev/null || iptables -t nat -S merlinclash_NOR >/dev/null 2>&1 || return 1
		echo_date "创建【nat】表【merlinclash_NOR】链" >> $LOG_FILE
		#ip集强制代理
		iptables -t nat -A merlinclash_NOR -p tcp -m set --match-set ipset_proxy dst -j REDIRECT --to-ports $proxy_port || return 1
		iptables -t nat -A merlinclash_NOR -p tcp -j REDIRECT --to-ports $proxy_port || return 1
		# 创建redirhost大陆白名单模式nat rule
		
		iptables -t nat -N merlinclash_CHN 2>/dev/null || iptables -t nat -S merlinclash_CHN >/dev/null 2>&1 || return 1
		echo_date "创建【nat】表【merlinclash_CHN】链" >> $LOG_FILE
		#ip集强制代理
		iptables -t nat -A merlinclash_CHN -p tcp -m set --match-set ipset_proxy dst -j REDIRECT --to-ports $proxy_port || return 1
		iptables -t nat -A merlinclash_CHN -p tcp -m set ! --match-set china_ip_route dst -j REDIRECT --to-ports $proxy_port || return 1
		
		if [ "$tproxymode" == "udp" ]; then
			echo_date "开启【TProxy UDP】转发，将创建相关iptable规则" >> $LOG_FILE
			# udp
			load_tproxy || return 1
			# 设置策略路由
			ip -4 route replace local default dev lo table 233 || return 1
			mc_ensure_policy_rule -4 0x2333 || return 1
			#同步路由家长电脑控制
			iptables -t filter -S PControls | sed 's/PControls/MC_PControls/g' | while read -r line; do iptables -t mangle $line || return 1; done || return 1
			iptables -t filter -S FORWARD|grep PControls|sed 's/-A FORWARD/-I PREROUTING/g;s/PControls/MC_PControls/g'|while read -r line; do iptables -t mangle $line || return 1; done || return 1

			#添加merlinclash_PREROUTING链
			iptables -t mangle -N merlinclash_PREROUTING 2>/dev/null || iptables -t mangle -S merlinclash_PREROUTING >/dev/null 2>&1 || return 1
			iptables -t mangle -F merlinclash_PREROUTING || return 1
            
			#仅对首包进行判断是否走clash，对转发的链接打上mark
			iptables -t mangle -N merlinclash 2>/dev/null || iptables -t mangle -S merlinclash >/dev/null 2>&1 || return 1
			iptables -t mangle -F merlinclash || return 1
			iptables -t mangle -A merlinclash -m conntrack --ctstate NEW -j MARK --set-mark 0x2333 || return 1
            iptables -t mangle -A merlinclash -j CONNMARK --save-mark || return 1
            iptables -t mangle -A merlinclash -p udp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port $tproxy_port || return 1
            
			#非首包有mark直接转发，无mark直连不再进行黑白名单及acl判断
			iptables -t mangle -N merlinclash_divert 2>/dev/null || iptables -t mangle -S merlinclash_divert >/dev/null 2>&1 || return 1
			iptables -t mangle -F merlinclash_divert || return 1
			iptables -t mangle -A merlinclash_divert -j CONNMARK --restore-mark || return 1
            iptables -t mangle -A merlinclash_divert -p udp -m mark --mark 0x2333 -m conntrack --ctstate RELATED,ESTABLISHED -j TPROXY --on-ip 127.0.0.1 --on-port $tproxy_port || return 1
            iptables -t mangle -A merlinclash_divert -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || return 1
            iptables -t mangle -A merlinclash_divert -m conntrack --ctstate INVALID -j DROP || return 1
				
			if [ "${merlinclash_ipt_proxyiot_sw}" != "1" ]; then
				iptables -t mangle -A merlinclash_PREROUTING -i br1 -j RETURN || return 1
				iptables -t mangle -A merlinclash_PREROUTING -i br2 -j RETURN || return 1
				iptables -t mangle -A merlinclash_PREROUTING -i br5+ -j RETURN || return 1
			fi
			#ip集强制代理
			iptables -t mangle -A merlinclash_PREROUTING -p udp -m set --match-set ipset_proxy dst -j merlinclash || return 1
			#ip集强制绕过
			iptables -t mangle -A merlinclash_PREROUTING -p udp -m set --match-set ipset_proxyarround dst -j RETURN || return 1
			#局域网&排除地址绕行
			iptables -t mangle -A merlinclash_PREROUTING -p udp -m set --match-set direct_list dst -j RETURN || return 1
			if [ "$cirswitch" == "1" ]; then	
				iptables -t mangle -A merlinclash_PREROUTING -p udp -m set --match-set china_ip_route dst -j RETURN || return 1
			fi
			iptables -t mangle -A PREROUTING -p udp -j merlinclash_divert || return 1
			iptables -t mangle -A PREROUTING -p udp -j merlinclash_PREROUTING || return 1
		else
			echo_date "【检测到UDP转发关闭，进行下一步】" >> $LOG_FILE
		fi

		lan_bypass || return 1
		iptables -t nat -A OUTPUT -p tcp -m mark --mark "$ip_prefix_hex" -j merlinclash_EXT || return 1
		iptables -t nat -A OUTPUT -p tcp -m mark --mark "$opvpn_prefix_hex" -j merlinclash_EXT || return 1 #OPENVPN回城兼容
		iptables -t nat -A OUTPUT -p tcp -m mark --mark "$pptpvpn_prefix_hex" -j merlinclash_EXT || return 1 #PPTPVPN回城兼容
		iptables -t nat -A OUTPUT -p tcp -m mark --mark "$ipsec_prefix_hex" -j merlinclash_EXT || return 1 #PPTPVPN回城兼容
		iptables -t nat -A merlinclash_EXT -p tcp -j merlinclash || return 1
		
				
		if [ "$dnsgoclash" == "1" ]; then
			#转发路由器自身tcp流量，clash出站流量打了mark不转发，避免回环
			iptables -t nat -N merlinclash_OUTPUT 2>/dev/null || iptables -t nat -S merlinclash_OUTPUT >/dev/null 2>&1 || return 1
            iptables -t nat -A merlinclash_OUTPUT -p tcp -m set --match-set direct_list dst -j RETURN || return 1
			iptables -t nat -A merlinclash_OUTPUT -m mark --mark $mcrm -j RETURN || return 1
			if [ "$cirswitch" == "1" ]; then	
				iptables -t nat -A merlinclash_OUTPUT -p tcp -m set ! --match-set china_ip_route dst -j merlinclash || return 1
			else
				iptables -t nat -A merlinclash_OUTPUT -p tcp -j merlinclash || return 1
			fi
			iptables -t nat -A merlinclash_OUTPUT -p udp --dport 53 -j REDIRECT --to-port 53 || return 1
			iptables -t nat -I OUTPUT -j merlinclash_OUTPUT || return 1
				
		fi
		

		iptables -t nat -A PREROUTING -p tcp -j merlinclash || return 1
		
	
	elif [ "$tproxymode" == "tcpudp" ]; then 
		echo_date "当前为【TProxy TCP&UDP】透明代理模式" >> $LOG_FILE
		echo_date "DNS方案是$dnsplan;配置文件DNS方案是$dem2" >> $LOG_FILE
		echo_date "Lan_ip是$lan_ipaddr" >> $LOG_FILE
		if [ "$ipv6switch" == "1" ] && [ $(ipv6_mode) == "true" ]; then
			ipv6_flag="1"
			echo_date "开启IPv6模式" >> $LOG_FILE
		fi

		# ipv4设置策略路由
		load_tproxy || return 1
		ip -4 route replace local default dev lo table 233 || return 1
		mc_ensure_policy_rule -4 0x2333 || return 1

		#同步路由家长电脑控制
		iptables -t filter -S PControls | sed 's/PControls/MC_PControls/g' | while read -r line; do iptables -t mangle $line || return 1; done || return 1
		iptables -t filter -S FORWARD|grep PControls|sed 's/-A FORWARD/-I PREROUTING/g;s/PControls/MC_PControls/g'|while read -r line; do iptables -t mangle $line || return 1; done || return 1

		#添加merlinclash_PREROUTING链
		iptables -t mangle -N merlinclash_PREROUTING 2>/dev/null || iptables -t mangle -S merlinclash_PREROUTING >/dev/null 2>&1 || return 1
		iptables -t mangle -F merlinclash_PREROUTING || return 1

		#仅对首包进行判断是否走clash，对转发的链接打上mark
		iptables -t mangle -N merlinclash 2>/dev/null || iptables -t mangle -S merlinclash >/dev/null 2>&1 || return 1
		iptables -t mangle -F merlinclash || return 1
		iptables -t mangle -A merlinclash -m conntrack --ctstate NEW -j MARK --set-mark 0x2333 || return 1
        iptables -t mangle -A merlinclash -j CONNMARK --save-mark || return 1
		iptables -t mangle -A merlinclash -p tcp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port $tproxy_port || return 1
        iptables -t mangle -A merlinclash -p udp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port $tproxy_port || return 1
            
		#非首包有mark直接转发，无mark直连不再进行黑白名单及acl判断
		iptables -t mangle -N merlinclash_divert 2>/dev/null || iptables -t mangle -S merlinclash_divert >/dev/null 2>&1 || return 1
		iptables -t mangle -F merlinclash_divert || return 1
		iptables -t mangle -A merlinclash_divert -j CONNMARK --restore-mark || return 1
		iptables -t mangle -A merlinclash_divert -p tcp -m mark --mark 0x2333 -m conntrack --ctstate RELATED,ESTABLISHED -j TPROXY --on-ip 127.0.0.1 --on-port $tproxy_port || return 1
        iptables -t mangle -A merlinclash_divert -p udp -m mark --mark 0x2333 -m conntrack --ctstate RELATED,ESTABLISHED -j TPROXY --on-ip 127.0.0.1 --on-port $tproxy_port || return 1
        iptables -t mangle -A merlinclash_divert -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || return 1
        iptables -t mangle -A merlinclash_divert -m conntrack --ctstate INVALID -j DROP || return 1

		#echo_date "创建【mangle】表【merlinclash】链" >> $LOG_FILE
		if [ "${merlinclash_ipt_proxyiot_sw}" != "1" ]; then
			iptables -t mangle -A merlinclash_PREROUTING -i br1 -j RETURN || return 1
			iptables -t mangle -A merlinclash_PREROUTING -i br2 -j RETURN || return 1
			iptables -t mangle -A merlinclash_PREROUTING -i br5+ -j RETURN || return 1
		fi
		#ip集强制代理
		iptables -t mangle -A merlinclash_PREROUTING -p tcp -m set --match-set ipset_proxy dst --syn -j merlinclash || return 1
		iptables -t mangle -A merlinclash_PREROUTING -p udp -m set --match-set ipset_proxy dst -m conntrack --ctstate NEW -j merlinclash || return 1
		#iptables -t mangle -A merlinclash_PREROUTING -p tcp -m set --match-set router dst -j merlinclash
		#ip集强制绕过
		iptables -t mangle -A merlinclash_PREROUTING -p tcp -m set --match-set ipset_proxyarround dst -j RETURN || return 1
		iptables -t mangle -A merlinclash_PREROUTING -p udp -m set --match-set ipset_proxyarround dst -j RETURN || return 1
		#局域网&排除地址绕行
		iptables -t mangle -A merlinclash_PREROUTING -p tcp -m set --match-set direct_list dst -j RETURN || return 1
		iptables -t mangle -A merlinclash_PREROUTING -p udp -m set --match-set direct_list dst -j RETURN || return 1
		#
		if [ "$cirswitch" == "1" ]; then
			iptables -t mangle -A merlinclash_PREROUTING -p tcp -m set --match-set china_ip_route dst -j RETURN || return 1
			iptables -t mangle -A merlinclash_PREROUTING -p udp -m set --match-set china_ip_route dst -j RETURN || return 1
		fi
											
		if [ "$ipv6_flag" == "0" ]; then
			lan_bypass || return 1
			iptables -t mangle -A PREROUTING -p tcp -j merlinclash_divert || return 1
			iptables -t mangle -A PREROUTING -p udp -j merlinclash_divert || return 1
			iptables -t mangle -A PREROUTING -p tcp -j merlinclash_PREROUTING || return 1
			iptables -t mangle -A PREROUTING -p udp -j merlinclash_PREROUTING || return 1
			
		fi		
	    # ipv6设置策略路由
		if [ "$ipv6_flag" == "1" ]; then

			ip -6 route replace local default dev lo table 233 || return 1
			mc_ensure_policy_rule -6 0x2333 || return 1

			#同步路由家长电脑控制
			ip6tables -t filter -S PControls | sed 's/PControls/MC_PControls/g' | while read -r line; do ip6tables -t mangle $line || return 1; done || return 1
			ip6tables -t filter -S FORWARD|grep PControls|sed 's/-A FORWARD/-I PREROUTING/g;s/PControls/MC_PControls/g'|while read -r line; do ip6tables -t mangle $line || return 1; done || return 1

			#添加merlinclash_PREROUTING链
			ip6tables -t mangle -N merlinclash_PREROUTING 2>/dev/null || ip6tables -t mangle -S merlinclash_PREROUTING >/dev/null 2>&1 || return 1
			ip6tables -t mangle -F merlinclash_PREROUTING || return 1

			#仅对首包进行判断是否走clash，对转发的链接打上mark
			ip6tables -t mangle -N merlinclash 2>/dev/null || ip6tables -t mangle -S merlinclash >/dev/null 2>&1 || return 1
			ip6tables -t mangle -F merlinclash || return 1
			ip6tables -t mangle -A merlinclash -m conntrack --ctstate NEW -j MARK --set-mark 0x2333 || return 1
            ip6tables -t mangle -A merlinclash -j CONNMARK --save-mark || return 1
			ip6tables -t mangle -A merlinclash -p tcp -m mark --mark 0x2333 -j TPROXY --on-ip ::1 --on-port $tproxy_port || return 1
            ip6tables -t mangle -A merlinclash -p udp -m mark --mark 0x2333 -j TPROXY --on-ip ::1 --on-port $tproxy_port || return 1
            
			#非首包有mark直接转发，无mark直连不再进行黑白名单及acl判断
			ip6tables -t mangle -N merlinclash_divert 2>/dev/null || ip6tables -t mangle -S merlinclash_divert >/dev/null 2>&1 || return 1
			ip6tables -t mangle -F merlinclash_divert || return 1
			ip6tables -t mangle -A merlinclash_divert -j CONNMARK --restore-mark || return 1
			ip6tables -t mangle -A merlinclash_divert -p tcp -m mark --mark 0x2333 -m conntrack --ctstate RELATED,ESTABLISHED -j TPROXY --on-ip ::1 --on-port $tproxy_port || return 1
            ip6tables -t mangle -A merlinclash_divert -p udp -m mark --mark 0x2333 -m conntrack --ctstate RELATED,ESTABLISHED -j TPROXY --on-ip ::1 --on-port $tproxy_port || return 1
            ip6tables -t mangle -A merlinclash_divert -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || return 1
            ip6tables -t mangle -A merlinclash_divert -m conntrack --ctstate INVALID -j DROP || return 1

			#echo_date "创建【ipv6-mangle】表【merlinclash】链" >> $LOG_FILE
			if [ "${merlinclash_ipt_proxyiot_sw}" != "1" ]; then
				ip6tables -t mangle -A merlinclash_PREROUTING -i br1 -j RETURN || return 1
				ip6tables -t mangle -A merlinclash_PREROUTING -i br2 -j RETURN || return 1
				ip6tables -t mangle -A merlinclash_PREROUTING -i br5+ -j RETURN || return 1
			fi
			#强制转发clash
			ip6tables -t mangle -A merlinclash_PREROUTING -p tcp -m set --match-set ipset_proxy6 dst -j merlinclash || return 1
			ip6tables -t mangle -A merlinclash_PREROUTING -p udp -m set --match-set ipset_proxy6 dst -j merlinclash || return 1
			
			#强制绕行clash
			ip6tables -t mangle -A merlinclash_PREROUTING -p tcp -m set --match-set ipset_proxyarround6 dst -j RETURN || return 1
			ip6tables -t mangle -A merlinclash_PREROUTING -p udp -m set --match-set ipset_proxyarround6 dst -j RETURN || return 1
			#局域网&排除地址绕行
			echo_date "局域网&排除地址绕行" >> $LOG_FILE
			ip6tables -t mangle -A merlinclash_PREROUTING -p tcp -m set --match-set direct_list6 dst -j RETURN || return 1
			ip6tables -t mangle -A merlinclash_PREROUTING -p udp -m set --match-set direct_list6 dst -j RETURN || return 1
			#
			if [ "$cirswitch" == "1" ]; then	
				ip6tables -t mangle -A merlinclash_PREROUTING -p udp -m set --match-set china_ip_route6 dst -j RETURN || return 1
				ip6tables -t mangle -A merlinclash_PREROUTING -p tcp -m set --match-set china_ip_route6 dst -j RETURN || return 1
			fi
			
			lan_bypass || return 1
			iptables -t mangle -A PREROUTING -p tcp -j merlinclash_divert || return 1
			iptables -t mangle -A PREROUTING -p udp -j merlinclash_divert || return 1
			ip6tables -t mangle -A PREROUTING -p tcp -j merlinclash_divert || return 1
			ip6tables -t mangle -A PREROUTING -p udp -j merlinclash_divert || return 1
			iptables -t mangle -A PREROUTING -p tcp -j merlinclash_PREROUTING || return 1
			iptables -t mangle -A PREROUTING -p udp -j merlinclash_PREROUTING || return 1
			ip6tables -t mangle -A PREROUTING -p tcp -j merlinclash_PREROUTING || return 1
			ip6tables -t mangle -A PREROUTING -p udp -j merlinclash_PREROUTING || return 1
			
		fi
		
		if [ "$dnsgoclash" == "1" ]; then
			mc_ensure_policy_rule -4 0x1111 || return 1
			iptables -t nat -N merlinclash_OUTPUT 2>/dev/null || iptables -t nat -S merlinclash_OUTPUT >/dev/null 2>&1 || return 1
			iptables -t nat -A merlinclash_OUTPUT -p tcp -m set --match-set direct_list dst -j RETURN || return 1
            iptables -t nat -A merlinclash_OUTPUT -m mark --mark $mcrm -j RETURN || return 1
			iptables -t nat -A merlinclash_OUTPUT -p udp --dport 53 -j REDIRECT --to-port 53 || return 1
			iptables -t nat -I OUTPUT -j merlinclash_OUTPUT || return 1
			iptables -t mangle -N merlinclash_OUTPUT 2>/dev/null || iptables -t mangle -S merlinclash_OUTPUT >/dev/null 2>&1 || return 1
			iptables -t mangle -A merlinclash_OUTPUT ! -s $wan_ipaddr -j RETURN || return 1
			iptables -t mangle -A merlinclash_OUTPUT -p udp --dport 53 -j RETURN || return 1
			iptables -t mangle -A merlinclash_OUTPUT -m set --match-set direct_list dst -j RETURN || return 1
            iptables -t mangle -A merlinclash_OUTPUT -m mark --mark $mcrm -j RETURN || return 1
			if [ "$cirswitch" == "1" ]; then	
				iptables -t mangle -A merlinclash_OUTPUT -m set --match-set china_ip_route dst -j RETURN || return 1
			fi
			iptables -t mangle -A merlinclash_OUTPUT -j CONNMARK --restore-mark || return 1
			iptables -t mangle -A merlinclash_OUTPUT -p tcp -m mark --mark 0x1111 -m conntrack --ctstate RELATED,ESTABLISHED -j MARK --set-mark 0x1111 || return 1
			iptables -t mangle -A merlinclash_OUTPUT -p udp -m mark --mark 0x1111 -m conntrack --ctstate RELATED,ESTABLISHED -j MARK --set-mark 0x1111 || return 1
            iptables -t mangle -A merlinclash_OUTPUT -m mark ! --mark 0x1111 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || return 1
            iptables -t mangle -A merlinclash_OUTPUT  -m mark ! --mark 0x1111 -m conntrack --ctstate INVALID -j DROP || return 1
			iptables -t mangle -A merlinclash_OUTPUT -p tcp -m conntrack --ctstate NEW -j MARK --set-mark 0x1111 || return 1
			iptables -t mangle -A merlinclash_OUTPUT -p udp -m conntrack --ctstate NEW -j MARK --set-mark 0x1111 || return 1
			iptables -t mangle -A merlinclash_OUTPUT -j CONNMARK --save-mark || return 1

			iptables -t mangle -I OUTPUT -j merlinclash_OUTPUT || return 1

			iptables -t mangle -I merlinclash_divert -p udp -s $wan_ipaddr -m mark --mark 0x1111 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j TPROXY --on-ip 127.0.0.1 --on-port $tproxy_port || return 1
			iptables -t mangle -I merlinclash_divert -p tcp -s $wan_ipaddr -m mark --mark 0x1111 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j TPROXY --on-ip 127.0.0.1 --on-port $tproxy_port || return 1
			iptables -t mangle -D merlinclash_divert -j CONNMARK --restore-mark || return 1
			iptables -t mangle -I merlinclash_divert -j CONNMARK --restore-mark || return 1
			if [ "$ipv6_flag" == "1" ]; then
				mc_ensure_policy_rule -6 0x1111 || return 1
				wan_ip6addr=$(ip -6 addr show dev ppp0 | sed -n '/inet/{s!.*inet6* !!;s!/.*!!p}' | sed 's/peer.*//' | grep -v '^fe80')
				ip6tables -t mangle -N merlinclash_OUTPUT 2>/dev/null || ip6tables -t mangle -S merlinclash_OUTPUT >/dev/null 2>&1 || return 1
				ip6tables -t mangle -A merlinclash_OUTPUT ! -s $wan_ip6addr -j RETURN || return 1
				ip6tables -t mangle -A merlinclash_OUTPUT -p udp --dport 53 -j RETURN || return 1
				ip6tables -t mangle -A merlinclash_OUTPUT -m set --match-set direct_list6 dst -j RETURN || return 1
                ip6tables -t mangle -A merlinclash_OUTPUT -m mark --mark $mcrm -j RETURN || return 1
				if [ "$cirswitch" == "1" ]; then
				    ip6tables -t mangle -A merlinclash_OUTPUT -m set --match-set china_ip_route6 dst -j RETURN || return 1
			    fi
				ip6tables -t mangle -A merlinclash_OUTPUT -j CONNMARK --restore-mark || return 1
				ip6tables -t mangle -A merlinclash_OUTPUT -p tcp -m mark --mark 0x1111 -m conntrack --ctstate RELATED,ESTABLISHED -j MARK --set-mark 0x1111 || return 1
				ip6tables -t mangle -A merlinclash_OUTPUT -p udp -m mark --mark 0x1111 -m conntrack --ctstate RELATED,ESTABLISHED -j MARK --set-mark 0x1111 || return 1
				ip6tables -t mangle -A merlinclash_OUTPUT -m mark ! --mark 0x1111 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || return 1
				ip6tables -t mangle -A merlinclash_OUTPUT -m mark ! --mark 0x1111 -m conntrack --ctstate INVALID -j DROP || return 1
				ip6tables -t mangle -A merlinclash_OUTPUT -p tcp -m conntrack --ctstate NEW -j MARK --set-mark 0x1111 || return 1
				ip6tables -t mangle -A merlinclash_OUTPUT -p udp -m conntrack --ctstate NEW -j MARK --set-mark 0x1111 || return 1
				ip6tables -t mangle -A merlinclash_OUTPUT -j CONNMARK --save-mark || return 1

				ip6tables -t mangle -I OUTPUT -j merlinclash_OUTPUT || return 1
				#取到wan口ipv6地址
				ip6tables -t mangle -I merlinclash_divert -p udp -s $wan_ip6addr -m mark --mark 0x1111 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j TPROXY --on-ip ::1 --on-port $tproxy_port || return 1
				ip6tables -t mangle -I merlinclash_divert -p tcp -s $wan_ip6addr -m mark --mark 0x1111 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j TPROXY --on-ip ::1 --on-port $tproxy_port || return 1
				ip6tables -t mangle -D merlinclash_divert -j CONNMARK --restore-mark || return 1
				ip6tables -t mangle -I merlinclash_divert -j CONNMARK --restore-mark || return 1
			fi
		fi
	elif [ "$tproxymode" == "tcp" ]; then
		echo_date "当前为【TProxy TCP】透明代理模式" >> $LOG_FILE
		echo_date "DNS方案是$dnsplan;配置文件DNS方案是$dem2" >> $LOG_FILE
		echo_date "Lan_ip是$lan_ipaddr" >> $LOG_FILE
		if [ "$ipv6switch" == "1" ] && [ $(ipv6_mode) == "true" ]; then
			ipv6_flag="1"
			echo_date "开启IPv6模式" >> $LOG_FILE
		fi

		# 设置策略路由
		load_tproxy || return 1
		ip -4 route replace local default dev lo table 233 || return 1
		mc_ensure_policy_rule -4 0x2333 || return 1

		#同步路由家长电脑控制
		iptables -t filter -S PControls | sed 's/PControls/MC_PControls/g' | while read -r line; do iptables -t mangle $line || return 1; done || return 1
		iptables -t filter -S FORWARD|grep PControls|sed 's/-A FORWARD/-I PREROUTING/g;s/PControls/MC_PControls/g'|while read -r line; do iptables -t mangle $line || return 1; done || return 1

		#添加merlinclash_PREROUTING链
		iptables -t mangle -N merlinclash_PREROUTING 2>/dev/null || iptables -t mangle -S merlinclash_PREROUTING >/dev/null 2>&1 || return 1
		iptables -t mangle -F merlinclash_PREROUTING || return 1

		#仅对首包进行判断是否走clash，对转发的链接打上mark
		iptables -t mangle -N merlinclash 2>/dev/null || iptables -t mangle -S merlinclash >/dev/null 2>&1 || return 1
		iptables -t mangle -F merlinclash || return 1
		iptables -t mangle -A merlinclash -m conntrack --ctstate NEW -j MARK --set-mark 0x2333 || return 1
        iptables -t mangle -A merlinclash -j CONNMARK --save-mark || return 1
        iptables -t mangle -A merlinclash -p tcp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port $tproxy_port || return 1
            
		#非首包有mark直接转发，无mark直连不再进行黑白名单及acl判断
		iptables -t mangle -N merlinclash_divert 2>/dev/null || iptables -t mangle -S merlinclash_divert >/dev/null 2>&1 || return 1
		iptables -t mangle -F merlinclash_divert || return 1
		iptables -t mangle -A merlinclash_divert -j CONNMARK --restore-mark || return 1
        iptables -t mangle -A merlinclash_divert -p tcp -m mark --mark 0x2333 -m conntrack --ctstate RELATED,ESTABLISHED -j TPROXY --on-ip 127.0.0.1 --on-port $tproxy_port || return 1
        iptables -t mangle -A merlinclash_divert -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || return 1
        iptables -t mangle -A merlinclash_divert -m conntrack --ctstate INVALID -j DROP || return 1

		#echo_date "创建【mangle】表【merlinclash】链" >> $LOG_FILE
		if [ "${merlinclash_ipt_proxyiot_sw}" != "1" ]; then
			iptables -t mangle -A merlinclash_PREROUTING -i br1 -j RETURN || return 1
			iptables -t mangle -A merlinclash_PREROUTING -i br2 -j RETURN || return 1
			iptables -t mangle -A merlinclash_PREROUTING -i br5+ -j RETURN || return 1
		fi
		#iptables -t mangle -A merlinclash_PREROUTING -p tcp -m set --match-set router dst -j merlinclash
		#ip集强制代理
		iptables -t mangle -A merlinclash_PREROUTING -p tcp -m set --match-set ipset_proxy dst --syn -j merlinclash || return 1
		#ip集强制绕过
		iptables -t mangle -A merlinclash_PREROUTING -p tcp -m set --match-set ipset_proxyarround dst -j RETURN || return 1
		#局域网&排除地址绕行
		iptables -t mangle -A merlinclash_PREROUTING -p tcp -m set --match-set direct_list dst -j RETURN || return 1
		#
		if [ "$cirswitch" == "1" ]; then	
			iptables -t mangle -A merlinclash_PREROUTING -p tcp -m set --match-set china_ip_route dst -j RETURN || return 1
		fi

		if [ "$ipv6_flag" == "0" ]; then
			lan_bypass || return 1
			iptables -t mangle -A PREROUTING -p tcp -j merlinclash_divert || return 1
			iptables -t mangle -A PREROUTING -p tcp -j merlinclash_PREROUTING || return 1
			
		fi
		# ipv6设置策略路由
		if [ "$ipv6_flag" == "1" ]; then

			ip -6 route replace local default dev lo table 233 || return 1
			mc_ensure_policy_rule -6 0x2333 || return 1

			#同步路由家长电脑控制
			ip6tables -t filter -S PControls | sed 's/PControls/MC_PControls/g' | while read -r line; do ip6tables -t mangle $line || return 1; done || return 1
			ip6tables -t filter -S FORWARD|grep PControls|sed 's/-A FORWARD/-I PREROUTING/g;s/PControls/MC_PControls/g'|while read -r line; do ip6tables -t mangle $line || return 1; done || return 1

			#添加merlinclash_PREROUTING链
			ip6tables -t mangle -N merlinclash_PREROUTING 2>/dev/null || ip6tables -t mangle -S merlinclash_PREROUTING >/dev/null 2>&1 || return 1
			ip6tables -t mangle -F merlinclash_PREROUTING || return 1

			#仅对首包进行判断是否走clash，对转发的链接打上mark
			ip6tables -t mangle -N merlinclash 2>/dev/null || ip6tables -t mangle -S merlinclash >/dev/null 2>&1 || return 1
			ip6tables -t mangle -F merlinclash || return 1
			ip6tables -t mangle -A merlinclash -m conntrack --ctstate NEW -j MARK --set-mark 0x2333 || return 1
            ip6tables -t mangle -A merlinclash -j CONNMARK --save-mark || return 1
			ip6tables -t mangle -A merlinclash -p tcp -m mark --mark 0x2333 -j TPROXY --on-ip ::1 --on-port $tproxy_port || return 1
                       
			#非首包有mark直接转发，无mark直连不再进行黑白名单及acl判断
			ip6tables -t mangle -N merlinclash_divert 2>/dev/null || ip6tables -t mangle -S merlinclash_divert >/dev/null 2>&1 || return 1
			ip6tables -t mangle -F merlinclash_divert || return 1
			ip6tables -t mangle -A merlinclash_divert -j CONNMARK --restore-mark || return 1
			ip6tables -t mangle -A merlinclash_divert -p tcp -m mark --mark 0x2333 -m conntrack --ctstate RELATED,ESTABLISHED -j TPROXY --on-ip ::1 --on-port $tproxy_port || return 1
            ip6tables -t mangle -A merlinclash_divert -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || return 1
            ip6tables -t mangle -A merlinclash_divert -m conntrack --ctstate INVALID -j DROP || return 1

			#echo_date "创建【ipv6-mangle】表【merlinclash】链" >> $LOG_FILE
			if [ "${merlinclash_ipt_proxyiot_sw}" != "1" ]; then
				ip6tables -t mangle -A merlinclash_PREROUTING -i br1 -j RETURN || return 1
				ip6tables -t mangle -A merlinclash_PREROUTING -i br2 -j RETURN || return 1
				ip6tables -t mangle -A merlinclash_PREROUTING -i br5+ -j RETURN || return 1
			fi
			#强制转发clash
			ip6tables -t mangle -A merlinclash_PREROUTING -p tcp -m set --match-set ipset_proxy6 dst -j merlinclash || return 1
			#强制绕行clash
			ip6tables -t mangle -A merlinclash_PREROUTING -p tcp -m set --match-set ipset_proxyarround6 dst -j RETURN || return 1
			#局域网&排除地址绕行
			ip6tables -t mangle -A merlinclash_PREROUTING -p tcp -m set --match-set direct_list6 dst -j RETURN || return 1
			#
			if [ "$cirswitch" == "1" ]; then	
				ip6tables -t mangle -A merlinclash_PREROUTING -p tcp -m set --match-set china_ip_route6 dst -j RETURN || return 1
			fi

			lan_bypass || return 1
			iptables -t mangle -A PREROUTING -p tcp -j merlinclash_divert || return 1
			ip6tables -t mangle -A PREROUTING -p tcp -j merlinclash_divert || return 1
			iptables -t mangle -A PREROUTING -p tcp -j merlinclash_PREROUTING || return 1
			ip6tables -t mangle -A PREROUTING -p tcp -j merlinclash_PREROUTING || return 1
		
		fi

		
		if [ "$dnsgoclash" == "1" ]; then
			mc_ensure_policy_rule -4 0x1111 || return 1
			iptables -t nat -N merlinclash_OUTPUT 2>/dev/null || iptables -t nat -S merlinclash_OUTPUT >/dev/null 2>&1 || return 1
			iptables -t nat -A merlinclash_OUTPUT -p tcp -m set --match-set direct_list dst -j RETURN || return 1
            iptables -t nat -A merlinclash_OUTPUT -m mark --mark $mcrm -j RETURN || return 1
			iptables -t nat -A merlinclash_OUTPUT -p udp --dport 53 -j REDIRECT --to-port 53 || return 1
			iptables -t nat -I OUTPUT -j merlinclash_OUTPUT || return 1
			iptables -t mangle -N merlinclash_OUTPUT 2>/dev/null || iptables -t mangle -S merlinclash_OUTPUT >/dev/null 2>&1 || return 1
			iptables -t mangle -A merlinclash_OUTPUT ! -s $wan_ipaddr -j RETURN || return 1
			iptables -t mangle -A merlinclash_OUTPUT -p udp --dport 53 -j RETURN || return 1
			iptables -t mangle -A merlinclash_OUTPUT -m set --match-set direct_list dst -j RETURN || return 1
            iptables -t mangle -A merlinclash_OUTPUT -m mark --mark $mcrm -j RETURN || return 1
			if [ "$cirswitch" == "1" ]; then	
				iptables -t mangle -A merlinclash_OUTPUT -m set --match-set china_ip_route dst -j RETURN || return 1
			fi
			iptables -t mangle -A merlinclash_OUTPUT -j CONNMARK --restore-mark || return 1
			iptables -t mangle -A merlinclash_OUTPUT -p tcp -m mark --mark 0x1111 -m conntrack --ctstate RELATED,ESTABLISHED -j MARK --set-mark 0x1111 || return 1
            iptables -t mangle -A merlinclash_OUTPUT -m mark ! --mark 0x1111 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || return 1
            iptables -t mangle -A merlinclash_OUTPUT -m mark ! --mark 0x1111 -m conntrack --ctstate INVALID -j DROP || return 1
			iptables -t mangle -A merlinclash_OUTPUT -p tcp -m conntrack --ctstate NEW -j MARK --set-mark 0x1111 || return 1
			iptables -t mangle -A merlinclash_OUTPUT -j CONNMARK --save-mark || return 1

			iptables -t mangle -I OUTPUT -j merlinclash_OUTPUT || return 1

			iptables -t mangle -I merlinclash_divert -p tcp -s $wan_ipaddr -m mark --mark 0x1111 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j TPROXY --on-ip 127.0.0.1 --on-port $tproxy_port || return 1
			iptables -t mangle -D merlinclash_divert -j CONNMARK --restore-mark || return 1
			iptables -t mangle -I merlinclash_divert -j CONNMARK --restore-mark || return 1
			if [ "$ipv6_flag" == "1" ]; then
				mc_ensure_policy_rule -6 0x1111 || return 1
				wan_ip6addr=$(ip -6 addr show dev ppp0 | sed -n '/inet/{s!.*inet6* !!;s!/.*!!p}' | sed 's/peer.*//' | grep -v '^fe80')
				ip6tables -t mangle -N merlinclash_OUTPUT 2>/dev/null || ip6tables -t mangle -S merlinclash_OUTPUT >/dev/null 2>&1 || return 1
				ip6tables -t mangle -A merlinclash_OUTPUT ! -s $wan_ip6addr -j RETURN || return 1
				ip6tables -t mangle -A merlinclash_OUTPUT -p udp --dport 53 -j RETURN || return 1
				ip6tables -t mangle -A merlinclash_OUTPUT -m set --match-set direct_list6 dst -j RETURN || return 1
                ip6tables -t mangle -A merlinclash_OUTPUT -m mark --mark $mcrm -j RETURN || return 1
				if [ "$cirswitch" == "1" ]; then
				    ip6tables -t mangle -A merlinclash_OUTPUT -m set --match-set china_ip_route6 dst -j RETURN || return 1
			    fi
				ip6tables -t mangle -A merlinclash_OUTPUT -j CONNMARK --restore-mark || return 1
				ip6tables -t mangle -A merlinclash_OUTPUT -p tcp -m mark --mark 0x1111 -m conntrack --ctstate RELATED,ESTABLISHED -j MARK --set-mark 0x1111 || return 1
				ip6tables -t mangle -A merlinclash_OUTPUT -m mark ! --mark 0x1111 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || return 1
				ip6tables -t mangle -A merlinclash_OUTPUT -m mark ! --mark 0x1111 -m conntrack --ctstate INVALID -j DROP || return 1
				ip6tables -t mangle -A merlinclash_OUTPUT -p tcp -m conntrack --ctstate NEW -j MARK --set-mark 0x1111 || return 1
				ip6tables -t mangle -A merlinclash_OUTPUT -j CONNMARK --save-mark || return 1

				ip6tables -t mangle -I OUTPUT -j merlinclash_OUTPUT || return 1
				#取到wan口ipv6地址
				ip6tables -t mangle -I merlinclash_divert -p tcp -s $wan_ip6addr -m mark --mark 0x1111 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j TPROXY --on-ip ::1 --on-port $tproxy_port || return 1
				ip6tables -t mangle -D merlinclash_divert -j CONNMARK --restore-mark || return 1
				ip6tables -t mangle -I merlinclash_divert -j CONNMARK --restore-mark || return 1
			fi
		fi
	fi

	# QOS开启的情况下
	QOSO=$(iptables -t mangle -S | grep -o QOSO | wc -l)
	RRULE=$(iptables -t mangle -S | grep "A QOSO" | head -n1 | grep RETURN)
	if [ "$QOSO" -gt "1" ] && [ -z "$RRULE" ]; then
		iptables -t mangle -I QOSO0 -m mark --mark "$ip_prefix_hex" -g merlinclash_RETURN || return 1
	fi
	#路由IPV6开启，但是不开启tproxy代理，仅开启ipv6劫持解析，需要内核4.1以上
	if [ "${LINUX_VER}" -ge "41" ] && [ "$ipv6switch" == "0" ] && [ $(ipv6_mode) == "true" ]; then
		load_tproxy || return 1
		echo_date "检测到路由IPv6开启，但未开启Tproxy代理，仅开启IPv6劫持解析" >> $LOG_FILE
		ip -6 route replace local default dev lo table 233 || return 1
		mc_ensure_policy_rule -6 0x2333 || return 1
	fi
	if [ "${LINUX_VER}" -lt "41" ] && [ $(ipv6_mode) == "true" ]; then
		load_tproxy || return 1
		echo_date "检测到路由IPv6开启，但未开启Tproxy代理，仅开启IPv6劫持解析" >> $LOG_FILE
		ip -6 route replace local default dev lo table 233 || return 1
		mc_ensure_policy_rule -6 0x2333 || return 1
	fi
	if [ "$dnsplan" == "fi" ]; then
		if [ "$mnm" != "2" ]; then ip6tables -t mangle -I PREROUTING -p udp --dport 53 -m set --match-set lan_mac_blacklist src -j DROP || return 1; fi #阻断黑名单设备ipv6dns查询
	fi
	echo_date "iptable规则创建完成" >> $LOG_FILE
}

write_update_yaml_cron(){
	
    yaml_dlinks_file=/jffs/softcenter/merlinclash/yaml_bak/${yamlname}.dlinks
	
	if [ -n "$yamlname" ] && echo "$yamlname" | grep -q '^AP_' && [ -f "${yaml_dlinks_file}" ];then
		cru d autoupdate
		cru d autologdel

		if [ "$mcenable" == "1" ] && [ "${clash_process_started}" = "1" ]; then
			update_time=$(awk -F',' '{print $1; exit}' "${yaml_dlinks_file}")
        	case "${update_time}" in
				86400)
					echo_date "设置每天凌晨5点，更新订阅配置" >> $LOG_FILE
					cru a autoupdate "0 5 * * * /bin/sh /jffs/softcenter/scripts/clash_subscribe.sh cron cron"
					cru a autologdel "0 * * * * /bin/sh /jffs/softcenter/scripts/clash_logautodel.sh"
				;;
				259200)
					echo_date "设置每周一周四凌晨5点，更新订阅配置" >> $LOG_FILE
					cru a autoupdate "0 5 * * 1,4 /bin/sh /jffs/softcenter/scripts/clash_subscribe.sh cron cron"
					cru a autologdel "0 * * * * /bin/sh /jffs/softcenter/scripts/clash_logautodel.sh"
				;;
				604800)
					echo_date "设置每周一凌晨5点，更新订阅配置" >> $LOG_FILE
					cru a autoupdate "0 5 * * 1 /bin/sh /jffs/softcenter/scripts/clash_subscribe.sh cron cron"
					cru a autologdel "0 * * * * /bin/sh /jffs/softcenter/scripts/clash_logautodel.sh"
				;;
				*)
					echo_date "未开启定时订阅" >> $LOG_FILE
			;;
			esac
		else
			echo_date "未检查到Clash进程，不开启定时订阅更新服务" >> $LOG_FILE
		fi
	fi																
}


write_setmark_cron_job(){
	if [ "${coremark}" == "1" ]; then
		echo_date "使用内核内置代理组状态保存服务" >> $LOG_FILE
		echo_date "Linux内核版本大于4.19或者启用了jffs2usb，使用内核内置代理组状态保存服务" > /tmp/upload/merlinclash_node_mark.log
		echo_date "------ 未使用定时脚本，本处无记录日志 -------" >> /tmp/upload/merlinclash_node_mark.log
	else
		cru d autosermark
		cru d autologdel
		if [ "$mcenable" == "1" ] && [ "${clash_process_started}" = "1" ]; then
			echo_date "开启Clash代理组状态保存服务，每分钟自动保存代理组设置" >> $LOG_FILE
			echo_date "开启Clash代理组状态保存服务，每分钟自动保存代理组设置" > /tmp/upload/merlinclash_node_mark.log
			cru a autosermark "* * * * * /bin/sh /jffs/softcenter/scripts/clash_node_mark.sh setmark"
			#同时启动日志监测，1小时检测一次
			cru a autologdel "0 * * * * /bin/sh /jffs/softcenter/scripts/clash_logautodel.sh"		
		else	
			echo_date "未检查到Clash进程，不开启Clash代理组状态保存服务" >> $LOG_FILE
		fi
	fi
}

write_clash_restart_cron_job(){
    # UI edits and controller restarts use one validated cron builder.
    sh /jffs/softcenter/scripts/clash_restart_regularly.sh --quiet
}

### 关闭各种服务
kill_process(){
    local p n=0
    mc_retire_supervisors
    for p in $(mc_core_pids); do kill "$p" 2>/dev/null || true; done
    while [ -n "$(mc_core_pids)" ] && [ "$n" -lt 20 ]; do sleep 1; n=$((n+1)); done
    for p in $(mc_core_pids); do kill -9 "$p" 2>/dev/null || true; done
    n=0
    while [ -n "$(mc_core_pids)" ] && [ "$n" -lt 20 ]; do sleep 0.25; n=$((n+1)); done
    [ -z "$(mc_core_pids)" ] || return 1
    rm -f /tmp/clash.pid
}

kill_cron_job(){
    cru d autosermark
    cru d autologdel
    cru d autoupdate
    cru d clash_restart
}

flush_nat() {
    echo_date 清除iptables规则... >> "$LOG_FILE"
    # Parse owned targets/ipsets rather than matching display text such as MAC.
    # Numbers come from the complete chain and are deleted in numeric reverse
    # order, so positions above nine and interleaved user rules remain correct.
    mc_flush_external_chain() {
        local family="$1" table="$2" chain="$3" number
        "$family" -t "$table" -S "$chain" 2>/dev/null | awk -v table="$table" '
            function splitrule(line, args, i,c,value,quote,escaped,n,present,sq) {
                sq=sprintf("%c",39); value=""; quote=""; escaped=0; n=0; present=0
                for(i=1;i<=length(line);i++) {
                    c=substr(line,i,1)
                    if(escaped) {value=value c; escaped=0; present=1; continue}
                    if(c=="\\" && quote!=sq) {escaped=1; present=1; continue}
                    if(quote!="") {if(c==quote) quote=""; else value=value c; present=1; continue}
                    if(c=="\"" || c==sq) {quote=c; present=1; continue}
                    if(c ~ /[[:space:]]/) {if(present) args[++n]=value; value=""; present=0; continue}
                    value=value c; present=1
                }
                if(present) args[++n]=value
                return n
            }
            $1=="-A" {
                number++; owned=0; n=splitrule($0,a)
                for(key in fields) delete fields[key]
                for(i=3;i<n;i+=2) fields[a[i]]=a[i+1]
                if(table=="nat" && a[2]=="PREROUTING" && n==8 && fields["-i"]=="br0" && fields["-d"]=="198.19.0.0/16" && fields["-j"]=="ACCEPT") owned=1
                if(table=="filter" && a[2]=="FORWARD") {
                    if(n==14 && fields["-i"]=="br0" && fields["-o"]=="mcquic" && fields["-d"]=="198.19.0.0/16" && fields["-m"]=="mark" && fields["--mark"]=="0x234/0xffff" && fields["-j"]=="ACCEPT") owned=1
                    if(n==12 && fields["-i"]=="mcquic" && fields["-o"]=="br0" && fields["-s"]=="198.19.0.0/16" && fields["-d"] ~ /^[0-9.]+\/[0-9]+$/ && fields["-j"]=="ACCEPT") owned=1
                    if(n==12 && fields["-i"]=="br0" && fields["-o"] ~ /^[A-Za-z0-9_.:-]+$/ && fields["-d"]=="198.19.0.0/16" && fields["-j"]=="REJECT" && fields["--reject-with"]=="icmp-port-unreachable") owned=1
                }
                for(i=3;i<n;i++) {
                    if((a[i]=="-j" || a[i]=="-g") && a[i+1] ~ /^(merlinclash(_[A-Za-z0-9_]+)?|MC_PControls)$/) owned=1
                    if(a[i]=="--match-set" && a[i+1] ~ /^(macblacklist_dns|macwhitelist_dns|ipblacklist_dns|ipwhitelist_dns|lan_mac_blacklist)$/) owned=1
                }
                if(owned) print number
            }
        ' | sort -rn | while IFS= read -r number; do
            "$family" -t "$table" -D "$chain" "$number" >/dev/null 2>&1 || return 1
        done
    }
    # The initial live snapshot proves these two exact legacy DNS53 rules came
    # from this plugin. Retire them once; future generic unmarked rules belong
    # to the user. New global DNS/RETURN rules enter owned payload chains.
    if [ "$(dbus get merlinclash_firewall_ownership_v1)" != 1 ]; then
        for protocol in udp tcp; do
            while iptables -t nat -C PREROUTING -p "$protocol" --dport 53 -j REDIRECT --to-ports 53 2>/dev/null; do
                iptables -t nat -D PREROUTING -p "$protocol" --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || return 1
            done
        done
        dbus set merlinclash_firewall_ownership_v1=1 || return 1
    fi
    local family table chain
    for family in iptables ip6tables; do
        for table in nat mangle filter; do
            for chain in PREROUTING OUTPUT QOSO0 FORWARD; do
                mc_flush_external_chain "$family" "$table" "$chain" || return 1
            done
            # Flush every owned chain before deleting any, removing mutual
            # references without touching shared built-in chains.
            for chain in merlinclash merlinclash_NOR merlinclash_CHN merlinclash_EXT merlinclash_divert merlinclash_PREROUTING merlinclash_OUTPUT merlinclash_DNS53 merlinclash_RETURN merlinclash_ACCEPT merlinclash_ROUTER_DNS MC_PControls; do
                "$family" -t "$table" -F "$chain" >/dev/null 2>&1 || :
            done
            for chain in merlinclash merlinclash_NOR merlinclash_CHN merlinclash_EXT merlinclash_divert merlinclash_PREROUTING merlinclash_OUTPUT merlinclash_DNS53 merlinclash_RETURN merlinclash_ACCEPT merlinclash_ROUTER_DNS MC_PControls; do
                "$family" -t "$table" -X "$chain" >/dev/null 2>&1 || :
            done
        done
    done
	#echo_date 删除ip route规则.
    mc_clean_policy() {
        local family="$1" snapshot records priority mark unavailable=0
        snapshot=$(ip "$family" rule show 2>&1) || {
            # This kernel can lack the IPv6 RPDB while IPv6 routes remain usable.
            # Only the exact native unsupported-family reply proves no rules.
            if [ "$family" = -6 ] && [ "$snapshot" = 'RTNETLINK answers: Address family not supported by protocol
Dump terminated' ]; then
                snapshot=; unavailable=1
            else
                return 1
            fi
        }
        # Missing selector attributes are wildcards for deletion. Refuse a
        # priority collision rather than remove an unrelated scoped neighbor.
        printf '%s\n' "$snapshot" | awk '
            $1 ~ /^[0-9]+:$/ {
                source=0; mark=""; table=0
                # Keyword-valued interfaces must not overwrite selector keys.
                for(i=2;i<NF;i++) {
                    if($i=="from" && $(i+1)=="all") source=1
                    if($i=="fwmark" && $(i+1) ~ /^0x(2333|1111)(\/0xffffffff)?$/) mark=$(i+1)
                    if($i=="lookup" && $(i+1)=="233") table=1
                }
                if(source && mark!="" && table) {
                    sub(/\/0xffffffff$/,"",mark)
                    key=$1 ":" mark
                    if(NF==7 && $2=="from" && $4=="fwmark" && $6=="lookup") wanted[key]=1
                    else conflict[key]=1
                }
            }
            END {for(key in wanted) if(conflict[key]) exit 1; exit 0}
        ' || return 1
        records=$(printf '%s\n' "$snapshot" | awk '
            NF==7 && $1 ~ /^[0-9]+:$/ && $2=="from" && $3=="all" && $4=="fwmark" && $5 ~ /^0x(2333|1111)(\/0xffffffff)?$/ && $6=="lookup" && $7=="233" {
                sub(/:$/,"",$1); sub(/\/0xffffffff$/,"",$5); print $1, $5 "/0xffffffff"
            }
        ')
        printf '%s\n' "$records" | while read -r priority mark; do
            [ -n "$priority" ] || continue
            ip "$family" rule del priority "$priority" from all fwmark "$mark" lookup 233 >/dev/null 2>&1 || return 1
        done || return 1
        if [ "$unavailable" = 0 ]; then
            snapshot=$(ip "$family" rule show 2>/dev/null) || return 1
            printf '%s\n' "$snapshot" | awk '
                NF==7 && $1 ~ /^[0-9]+:$/ && $2=="from" && $3=="all" && $4=="fwmark" && $5 ~ /^0x(2333|1111)(\/0xffffffff)?$/ && $6=="lookup" && $7=="233" {found=1}
                END {exit(found ? 0 : 1)}
            ' && return 1
        fi
        ip "$family" route del local default dev lo table 233 >/dev/null 2>&1 || :
        snapshot=$(ip "$family" route show table 233 2>/dev/null) || return 1
        printf '%s\n' "$snapshot" | awk '
            $1=="local" && $2=="default" && $3=="dev" && $4=="lo" {found=1}
            END {exit(found ? 0 : 1)}
        ' && return 1
        return 0
    }
    mc_clean_policy -4 || return 1
    mc_clean_policy -6 || return 1
	#
	echo_date "清除ipset规则集" >> $LOG_FILE
	ipset -F direct_list >/dev/null 2>&1 && ipset -X direct_list >/dev/null 2>&1
	ipset -F direct_list6 >/dev/null 2>&1 && ipset -X direct_list6 >/dev/null 2>&1
	ipset -F router >/dev/null 2>&1 && ipset -X router >/dev/null 2>&1
	ipset -F ipset_proxy >/dev/null 2>&1 && ipset -X ipset_proxy >/dev/null 2>&1
	ipset -F ipset_proxyarround >/dev/null 2>&1 && ipset -X ipset_proxyarround >/dev/null 2>&1
	ipset -F ipset_proxy6 >/dev/null 2>&1 && ipset -X ipset_proxy6 >/dev/null 2>&1
	ipset -F ipset_proxyarround6 >/dev/null 2>&1 && ipset -X ipset_proxyarround6 >/dev/null 2>&1

	ipset destroy china_ip_route >/dev/null 2>&1
	ipset destroy china_ip_route6 >/dev/null 2>&1
	ipset destroy lan_ip_blacklist >/dev/null 2>&1
	ipset destroy lan_mac_blacklist >/dev/null 2>&1
	ipset destroy lan_ip_whitelist >/dev/null 2>&1
	ipset destroy lan_mac_whitelist >/dev/null 2>&1
	ipset destroy macblacklist_dns >/dev/null 2>&1
	ipset destroy macwhitelist_dns >/dev/null 2>&1
	ipset destroy ipblacklist_dns >/dev/null 2>&1
	ipset destroy ipwhitelist_dns >/dev/null 2>&1
	echo_date "清除iptables规则完毕..." >> $LOG_FILE
	if [ -f "/tmp/clash_firewall_triggered" ]; then
    	rm -f /tmp/clash_firewall_triggered
	else
		restart_firewall
	fi
}

restart_firewall() {
	if [ "${merlinclash_ipt_proxyrouter_sw}" == "1" ]; then
		# 设置标志，表示这次防火墙重启是由flush_nat触发的
		touch /tmp/clash_firewall_triggered
		service restart_firewall >/dev/null 2>&1
		logger "[软件中心-Magic Catling]: 重启防火墙...！"
		echo_date "重启防火墙..." >> $LOG_FILE
	fi
}

close_in_five() {
    echo_date "Startup failed; preserving recovery intent and rollback profile" >> "$LOG_FILE"
    exit 1
}

stop_config(){
    local p active previous="$yamlpath" stopstatus=0
    MC_STOP_APPLIED=0
    p=$(mc_core_pids | head -1)
    if [ -n "$p" ]; then
        active=$(tr '\000' '\n' < "/proc/$p/cmdline" | awk 'found {print; exit} $0=="-f" {found=1}')
        if [ -s "$active" ]; then yamlpath="$active"; get_ports; yamlpath="$previous"; fi
    fi
	dbus set merlinclash_recovery_wanted=0 # explicit stop cancels recovery
	echo_date 触发脚本stop_config >> $LOG_FILE
	echo_date ======================= Magic Catling ======================= >> $LOG_FILE
	echo_date ---------------------- 🔴关闭相关程序 ---------------------- >> $LOG_FILE
	kill_cron_job
	clean_ipset
	dbus set merlinclash_enable="0"
	if [ "${merlinclash_ipt_closeproxy_sw}" != "1" ] || mc_owned_state_present --dns-only; then
		restart_dnsmasq || stopstatus=1
	fi
	kill_process || stopstatus=1
    mc_cleanup_ai || stopstatus=1
	echo_date -------------------- 🔴清除iptables规则 -------------------- >> $LOG_FILE
	flush_nat || stopstatus=1
    if [ -n "$(mc_core_pids)" ] || mc_owned_state_present; then stopstatus=1; fi
    if [ "$stopstatus" = 0 ]; then MC_STOP_APPLIED=1; fi
    return "$stopstatus"
}

maintenance_stop(){
    local prior="$mcenable" stopstatus=0
    kill_cron_job
    clean_ipset
    kill_process || stopstatus=1
    mc_cleanup_ai || stopstatus=1
    flush_nat || stopstatus=1
    mcenable=0
    if [ "${merlinclash_ipt_closeproxy_sw}" != 1 ] || mc_owned_state_present --dns-only; then
        restart_dnsmasq || stopstatus=1
    fi
    mcenable="$prior"
    if [ -n "$(mc_core_pids)" ] || mc_owned_state_present; then stopstatus=1; fi
    return "$stopstatus"
}

### 主流程
apply_mc() {
	echo_date ======================= Magic Catling ======================= >> $LOG_FILE
	echo_date ------------------------ 🟠启动准备 ------------------------ >> $LOG_FILE
	check_ss || return 1
    local livepath="$MC_ROOT/yaml_use/$yamlname.yaml" candidate rc
    candidate=$(mc_mktemp "$MC_ROOT/yaml_use/.${yamlname}.prepare.XXXXXX") || return 1
    yamlpath="$candidate"
    (
        set -e
        check_yaml
        check_rule || return 1
        check_dnsplan
        set_Tolerance
        check_coremark
        start_custom
        mc_validate_yaml "$yamlpath"
    )
    rc=$?
    yamlpath="$livepath"
    if [ "$rc" != 0 ]; then rm -f "$candidate"; return "$rc"; fi
    # Keep a verified rollback profile before atomic publication.
    [ ! -e "$livepath" ] || cp -p "$livepath" "$livepath.last-good" || { rm -f "$candidate"; return 1; }
    chmod 600 "$candidate" && mv -f "$candidate" "$livepath" || return 1
    MC_PROFILE_COMMITTED=1
	apply_dns_settings
	clean_ipset	#清除ipset
	kill_process || return 1 #关闭进程
	kill_cron_job #关闭定时任务
	flush_nat || return 1 #清除iptables规则
	if [ "${merlinclash_ipt_closeproxy_sw}" != "1" ] || mc_owned_state_present --dns-only; then
		restart_dnsmasq || return 1
	fi
	echo_date ------------------------ 🟢开始启动 ------------------------ >> $LOG_FILE
	echo_date ---------------------- 📌设置启动参数 ---------------------- >> $LOG_FILE






	check_coremark
	get_ports	#获取端口号
	echo_date ---------------------- 📌创建ipset规则 --------------------- >> $LOG_FILE
	if [ "${merlinclash_ipt_closeproxy_sw}" != "1" ]; then creat_ipset || return 1; fi	#创建相关ipset规则
	set_sys	#启动增熵
	echo_date ---------------------- 📌启动Mihomo内核 --------------------- >> $LOG_FILE
    if [ "$(dbus get merlinclash_enable)" != 1 ] && [ "$(dbus get merlinclash_recovery_wanted)" != 1 ]; then
        MC_PROFILE_COMMITTED=0
        stop_config
        return $?
    fi
	start_clash || return 1
	start_remark || return 1
	[ "${merlinclash_ipt_closeproxy_sw}" != "1" ] && echo_date --------------------- 📌创建iptables规则 -------------------- >> $LOG_FILE
	if [ "${merlinclash_ipt_closeproxy_sw}" != "1" ]; then load_nat || return 1; fi
	if [ "${merlinclash_ipt_closeproxy_sw}" != "1" ]; then
		restart_dnsmasq || return 1
	fi
	echo_date ----------------------- 📌启动后处理 ------------------------ >> $LOG_FILE
	/jffs/scripts/chatgpt-http3.sh || return 1
	cru a clash_watchdog "* * * * * /bin/sh /jffs/softcenter/scripts/clash_watchdog.sh"
    cru a merlinclash_autoupdate "30 4 * * * /bin/sh /jffs/softcenter/scripts/merlinclash_autoupdate.sh"
	write_setmark_cron_job #节点后台记忆
	write_update_yaml_cron #定时订阅
	write_clash_restart_cron_job #定时重启
    echo_date "" >> $LOG_FILE
	echo_date "             ++++++++++++++++++++++++++++++++++++++++" >> $LOG_FILE
    echo_date "                      管理面板：$lan_ipaddr:$ecport      " >> $LOG_FILE
    [ -n "${httpport}" ] &&  [ "${httpport}" != "null" ] && echo_date "                     Http代理：$lan_ipaddr:$httpport "  >> $LOG_FILE
    [ -n "${socksport}" ] &&  [ "${socksport}" != "null" ] && echo_date "                    Socks代理：$lan_ipaddr:$socksport " >> $LOG_FILE
	[ -n "${mixport}" ] &&  [ "${mixport}" != "null" ] && echo_date "                      混合代理：$lan_ipaddr:$mixport " >> $LOG_FILE	
    echo_date "             ++++++++++++++++++++++++++++++++++++++++" >> $LOG_FILE
	echo_date "" >> $LOG_FILE
    echo_date "                     ✅恭喜！开启MerlinClash成功！" >> $LOG_FILE
	echo_date "" >> $LOG_FILE
	echo_date   "如果不能科学上网，请刷新设备dns缓存，或者等待几分钟再尝试" >> $LOG_FILE
	echo_date "" >> $LOG_FILE
	echo_date ======================= Magic Catling ======================= >> $LOG_FILE
}

apply_nat() {
	echo_date --------------------- 🔴清除iptables规则 -------------------- >> $LOG_FILE
	flush_nat || return 1
	echo_date ---------------------- 📌创建ipset规则 ---------------------- >> $LOG_FILE
	clean_ipset
	if [ "${merlinclash_ipt_closeproxy_sw}" != "1" ]; then creat_ipset || return 1; fi
	get_ports
	[ "${merlinclash_ipt_closeproxy_sw}" != "1" ] && echo_date --------------------- 📌创建iptables规则 -------------------- >> $LOG_FILE
	if [ "${merlinclash_ipt_closeproxy_sw}" != "1" ]; then load_nat || return 1; fi
	if [ "${merlinclash_ipt_closeproxy_sw}" != "1" ] || mc_owned_state_present --dns-only; then
		restart_dnsmasq || return 1
	fi
	echo_date "=============== Magic Catling iptable 重写完成===============" >> $LOG_FILE
}

# Read settings again only after acquiring the lifecycle mutex.
request=${2:-${1:-}}
case "$request" in start|start_nat|stop|restart) ;; *) exit 2 ;; esac
MC_CLEANUP_ONLY=0
[ "$request" != stop ] || MC_CLEANUP_ONLY=1
if { [ "$request" = stop ] && [ "${1:-}" != maintenance ]; } || { [ "$request" = start ] && [ -n "${2:-}" ] && [ "$(dbus get merlinclash_enable)" != 1 ]; }; then
    # UI Off is durable even if another workflow currently owns the lock.
    dbus set "merlinclash_stop_token=$(date +%s).$$"
    dbus set merlinclash_enable=0
    dbus set merlinclash_recovery_wanted=0
    MC_CLEANUP_ONLY=1
fi
if [ "$MC_CLEANUP_ONLY" = 1 ]; then mc_lock --cleanup-only; else mc_lock; fi
lock_status=$?
[ "$lock_status" = 0 ] || exit "$lock_status"
MC_STOP_TOKEN=$(dbus get merlinclash_stop_token)
MC_WAS_RUNNING=0
[ -z "$(mc_core_pids)" ] || MC_WAS_RUNNING=1
MC_PREVIOUS_PROFILE=$(mc_active_name)
MC_PREVIOUS_CFG=$(mc_active_config)
mc_controller_cleanup() {
    local status=$? restored rollback_source= rollback_profile="$yamlname" rollback_mark=
    trap - EXIT
    if [ "$(dbus get merlinclash_stop_token)" != "$MC_STOP_TOKEN" ] || { [ "$(dbus get merlinclash_enable)" = 0 ] && [ "$(dbus get merlinclash_recovery_wanted)" != 1 ]; }; then
        if [ "${MC_STOP_APPLIED:-0}" != 1 ]; then stop_config || status=1; fi
        mc_unlock
        exit "$status"
    fi
    if [ "$status" != 0 ] && [ "${MC_PROFILE_COMMITTED:-0}" = 1 ]; then
        restored="$MC_ROOT/yaml_use/$yamlname.yaml.last-good"
        if mc_validate_yaml "$restored"; then
            cp -p "$restored" "$restored.restore" && mv -f "$restored.restore" "$MC_ROOT/yaml_use/$yamlname.yaml"
            rollback_source="$restored"
        fi
        if [ "$MC_WAS_RUNNING" = 1 ] && [ "${MC_ROLLBACK_PASS:-0}" != 1 ]; then
            if [ -n "$MC_PREVIOUS_PROFILE" ] && mc_validate_yaml "$MC_PREVIOUS_CFG.active-last-good"; then
                rollback_source="$MC_PREVIOUS_CFG.active-last-good"
                rollback_profile="$MC_PREVIOUS_PROFILE"
                if [ "${MC_REQUEST_PROFILE+x}" != x ]; then
                    dbus set "merlinclash_set_yamlsel_start=$MC_PREVIOUS_PROFILE"
                    dbus set "merlinclash_yamlsel=$MC_PREVIOUS_PROFILE"
                fi
            fi
            if [ -n "$rollback_source" ]; then
                [ "${MC_FRESH_MARK_PROFILE:-}" != "$rollback_profile" ] || rollback_mark="$rollback_profile"
                MC_FRESH_MARK_PROFILE="$rollback_mark" MC_ROLLBACK_PASS=1 MC_REQUEST_PROFILE="$rollback_profile" MC_FORCE_SOURCE="$rollback_source" sh /jffs/softcenter/scripts/clash_config.sh rollback restart >> "$LOG_FILE" 2>&1
            fi
        fi
    fi
    mc_unlock
    exit "$status"
}

trap 'mc_controller_cleanup' EXIT
trap 'exit 1' HUP INT TERM
eval $(dbus export merlinclash_)
# A UI Off request may be followed by On while waiting for the mutex. Any
# resulting start still requires publication recovery before touching profiles.
if [ "$MC_CLEANUP_ONLY" = 1 ] && [ "$request" != stop ] &&
   { [ "$merlinclash_enable" = 1 ] || [ "$merlinclash_recovery_wanted" = 1 ]; }; then
    mc_recover_profiles || exit 1
fi
mcrm=${merlinclash_ipt_routingmark_val:-524288}
case "$mcrm" in *[!0-9]*) mcrm=524288 ;; esac
### 全局变量赋值
mcenable=${merlinclash_enable}
dnshijacksel=${merlinclash_dns_dnshijack_sw}
dfib=${merlinclash_dns_fakeip_server}
cusruleplan=${merlinclash_acl_plan}
retryTimes=${merlinclash_set_logcheck_val}
tproxymode=${merlinclash_ipt_tproxy_type}
cirswitch=${merlinclash_set_chnroute_sw}
ipv6switch=${merlinclash_ipt_ipv6_sw}
dnsplan=${merlinclash_dns_type}
dnsgoclash=${merlinclash_ipt_proxyrouter_sw}
dnsinclash=${merlinclash_dns_proxydns_sw}


if [ "$request" = start_nat ] && [ -n "$(mc_core_pids)" ]; then
    yamlname=$(mc_active_name) || exit 1
elif { [ "$request" = start ] || [ "$request" = restart ]; } && [ "${MC_REQUEST_PROFILE+x}" = x ]; then
    yamlname=$MC_REQUEST_PROFILE
    mc_valid_name "$yamlname" || exit 1
else
    yamlname=$(mc_selected) || { [ "$request" = stop ] && yamlname=disabled || exit 1; }
fi
yamlpath="$MC_ROOT/yaml_use/$yamlname.yaml"
mcenable=${merlinclash_enable}
case "$request" in
    stop) if [ "${1:-}" = maintenance ]; then maintenance_stop; else stop_config; fi ;;
    start_nat)
        [ "$mcenable" = 1 ] && [ -n "$(mc_core_pids)" ] || exit 0
        apply_nat >>"$LOG_FILE" || exit $?
        /jffs/scripts/chatgpt-http3.sh || exit $?
        ;;
    start|restart)
        if [ "$mcenable" != 1 ]; then
            if [ "$request" = restart ] && [ "$(dbus get merlinclash_recovery_wanted)" = 1 ]; then
                dbus set merlinclash_enable=1
                mcenable=1
            else
                if [ "$request" = start ] && [ -n "$2" ]; then
                    stop_config || exit 1
                fi
                exit 0
            fi
        fi
        if [ "$request" = start ] && [ -z "${2:-}" ] && [ "${merlinclash_set_startdelay_sw}" = 1 ]; then
            delay=${merlinclash_set_startdelay_val}
            case "$delay" in ''|*[!0-9]*) exit 1 ;; esac
            [ "$delay" -le 3600 ] || exit 1
            # Off is durable before its caller attempts the lifecycle lock.
            # Observe cancellation while retaining this owner's cleanup trap.
            while :; do
                if [ "$(dbus get merlinclash_stop_token)" != "$MC_STOP_TOKEN" ] ||
                   { [ "$(dbus get merlinclash_enable)" = 0 ] && [ "$(dbus get merlinclash_recovery_wanted)" != 1 ]; }; then
                    exit 0
                fi
                [ "$delay" -gt 0 ] || break
                sleep 1 || exit 1
                delay=$((delay-1))
            done
        fi
        # Save the current manual selector choices immediately before stopping.
        if [ -n "$(mc_core_pids)" ] && [ "${MC_ROLLBACK_PASS:-0}" != 1 ]; then
            mark_profile=${MC_PREVIOUS_PROFILE:-$yamlname}
            if sh /jffs/softcenter/scripts/clash_node_mark.sh setmark; then
                MC_FRESH_MARK_PROFILE=
                [ "$(dbus get merlinclash_stop_token)" = "$MC_STOP_TOKEN" ] || exit 0
                if [ "$(dbus get merlinclash_enable)" = 1 ]; then
                    captured_profile=$(mc_active_name) && mc_valid_name "$captured_profile" &&
                        [ "$captured_profile" = "$mark_profile" ] || exit 1
                    MC_FRESH_MARK_PROFILE="$captured_profile"
                fi
            else
                MC_FRESH_MARK_PROFILE=
                if mc_saved_mark_valid "$MC_ROOT/mark/$mark_profile.txt"; then
                    echo_date "Selector API unavailable; retained validated saved selectors for $mark_profile, fresh choices were not captured" >> "$LOG_FILE"
                elif [ -n "$MC_PREVIOUS_CFG" ] && [ "$(yq e '.profile.store-selected == true' "$MC_PREVIOUS_CFG" 2>/dev/null)" = true ]; then
                    echo_date "Selector API unavailable; using native saved selections, fresh choices were not captured" >> "$LOG_FILE"
                else
                    echo_date "Selector API unavailable and no validated prior selector record or native persistence; selections may reset to defaults" >> "$LOG_FILE"
                fi
            fi
            if [ -n "$MC_PREVIOUS_CFG" ] && mc_validate_yaml "$MC_PREVIOUS_CFG"; then
                cp -p "$MC_PREVIOUS_CFG" "$MC_PREVIOUS_CFG.active-last-good" && chmod 600 "$MC_PREVIOUS_CFG.active-last-good" || exit 1
            fi
        fi
        [ -z "${2:-}" ] || http_response "$1"
        apply_mc
        rc=$?
        [ "$rc" = 0 ] || exit "$rc"
        if [ "$(dbus get merlinclash_enable)" != 1 ] && [ "$(dbus get merlinclash_recovery_wanted)" != 1 ]; then
            MC_PROFILE_COMMITTED=0
            stop_config
            exit $?
        fi
        sh /jffs/softcenter/scripts/clash_watchdog.sh --check || exit 1
        MC_PROFILE_COMMITTED=0
        dbus set merlinclash_recovery_wanted=0
        echo BBABBBBC >> "$LOG_FILE"
        ;;
esac
