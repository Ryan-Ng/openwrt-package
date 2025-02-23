#!/bin/sh
# Copyright (C) 2018-2020 Lienol <lawlienol@gmail.com>

. $IPKG_INSTROOT/lib/functions.sh
. $IPKG_INSTROOT/lib/functions/service.sh

CONFIG=passwall
CONFIG_PATH=/var/etc/$CONFIG
RUN_PID_PATH=$CONFIG_PATH/pid
RUN_PORT_PATH=$CONFIG_PATH/port
HAPROXY_FILE=$CONFIG_PATH/haproxy.cfg
REDSOCKS_CONFIG_TCP_FILE=$CONFIG_PATH/redsocks_TCP.conf
REDSOCKS_CONFIG_UDP_FILE=$CONFIG_PATH/redsocks_UDP.conf
CONFIG_TCP_FILE=$CONFIG_PATH/TCP.json
CONFIG_UDP_FILE=$CONFIG_PATH/UDP.json
CONFIG_SOCKS5_FILE=$CONFIG_PATH/SOCKS5.json
LOCK_FILE=/var/lock/$CONFIG.lock
LOG_FILE=/var/log/$CONFIG.log
RULE_PATH=/etc/config/${CONFIG}_rule
APP_PATH=/usr/share/$CONFIG
TMP_DNSMASQ_PATH=/var/etc/dnsmasq-passwall.d
DNSMASQ_PATH=/etc/dnsmasq.d
lanip=$(uci get network.lan.ipaddr)
DNS_PORT=7913

get_date() {
	echo "$(date "+%Y-%m-%d %H:%M:%S")"
}

echolog() {
	echo -e "$(get_date): $1" >>$LOG_FILE
}

find_bin() {
	bin_name=$1
	result=$(find /usr/*bin -iname "$bin_name" -type f)
	if [ -z "$result" ]; then
		echo ""
		echolog "找不到$bin_name主程序，无法启动！"
	else
		echo "$result"
	fi
}

config_n_get() {
	local ret=$(uci get $CONFIG.$1.$2 2>/dev/null)
	echo ${ret:=$3}
}

config_t_get() {
	local index=0
	[ -n "$4" ] && index=$4
	local ret=$(uci get $CONFIG.@$1[$index].$2 2>/dev/null)
	echo ${ret:=$3}
}

get_host_ip() {
	local network_type host isip
	network_type=$1
	host=$2
	isip=""
	ip=$host
	if [ "$network_type" == "ipv6" ]; then
		isip=$(echo $host | grep -E "([[a-f0-9]{1,4}(:[a-f0-9]{1,4}){7}|[a-f0-9]{1,4}(:[a-f0-9]{1,4}){0,7}::[a-f0-9]{0,4}(:[a-f0-9]{1,4}){0,7}])")
		if [ -n "$isip" ]; then
			isip=$(echo $host | cut -d '[' -f2 | cut -d ']' -f1)
		else
			isip=$(echo $host | grep -E "([a-f0-9]{1,4}(:[a-f0-9]{1,4}){7}|[a-f0-9]{1,4}(:[a-f0-9]{1,4}){0,7}::[a-f0-9]{0,4}(:[a-f0-9]{1,4}){0,7})")
		fi
	else
		isip=$(echo $host | grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}")
	fi
	if [ -z "$isip" ]; then
		vpsrip=""
		if [ "$use_ipv6" == "1" ]; then
			vpsrip=$(resolveip -6 -t 2 $host | awk 'NR==1{print}')
			[ -z "$vpsrip" ] && vpsrip=$(dig @208.67.222.222 $host AAAA 2>/dev/null | grep 'IN' | awk -F ' ' '{print $5}' | grep -E "([a-f0-9]{1,4}(:[a-f0-9]{1,4}){7}|[a-f0-9]{1,4}(:[a-f0-9]{1,4}){0,7}::[a-f0-9]{0,4}(:[a-f0-9]{1,4}){0,7})" | head -n1)
		else
			vpsrip=$(resolveip -4 -t 2 $host | awk 'NR==1{print}')
			[ -z "$vpsrip" ] && vpsrip=$(dig @208.67.222.222 $host 2>/dev/null | grep 'IN' | awk -F ' ' '{print $5}' | grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}" | head -n1)
		fi
		ip=$vpsrip
	fi
	echo $ip
}

check_port_exists() {
	port=$1
	protocol=$2
	result=
	if [ "$protocol" = "tcp" ]; then
		result=$(netstat -tlpn | grep "\<$port\>")
	elif [ "$protocol" = "udp" ]; then
		result=$(netstat -ulpn | grep "\<$port\>")
	fi
	if [ -n "$result" ]; then
		echo 1
	else
		echo 0
	fi
}

get_not_exists_port_after() {
	port=$1
	protocol=$2
	result=$(check_port_exists $port $protocol)
	if [ "$result" = 1 ]; then
		temp=
		if [ "$port" -lt 65535 ]; then
			temp=$(expr $port + 1)
		elif [ "$port" -gt 1 ]; then
			temp=$(expr $port - 1)
		fi
		get_not_exists_port_after $temp $protocol
	else
		echo $port
	fi
}

TCP_NODE_NUM=$(config_t_get global_other tcp_node_num 1)
for i in $(seq 1 $TCP_NODE_NUM); do
	eval TCP_NODE$i=$(config_t_get global tcp_node$i nil)
done

UDP_NODE_NUM=$(config_t_get global_other udp_node_num 1)
for i in $(seq 1 $UDP_NODE_NUM); do
	eval UDP_NODE$i=$(config_t_get global udp_node$i nil)
done

SOCKS5_NODE_NUM=$(config_t_get global_other socks5_node_num 1)
for i in $(seq 1 $SOCKS5_NODE_NUM); do
	eval SOCKS5_NODE$i=$(config_t_get global socks5_node$i nil)
done

[ "$UDP_NODE1" == "default" ] && UDP_NODE1=$TCP_NODE1

TCP_NODE1_IP=""
UDP_NODE1_IP=""
SOCKS5_NODE1_IP=""
TCP_NODE1_IPV6=""
UDP_NODE1_IPV6=""
SOCKS5_NODE1_IPV6=""
TCP_NODE1_PORT=""
UDP_NODE1_PORT=""
SOCKS5_NODE1_PORT=""
TCP_NODE1_TYPE=""
UDP_NODE1_TYPE=""
SOCKS5_NODE1_TYPE=""

BROOK_SOCKS5_CMD=""
BROOK_TCP_CMD=""
BROOK_UDP_CMD=""
AUTO_SWITCH_ENABLE=$(config_t_get auto_switch enable 0)
TCP_REDIR_PORTS=$(config_t_get global_forwarding tcp_redir_ports '80,443')
UDP_REDIR_PORTS=$(config_t_get global_forwarding udp_redir_ports '1:65535')
KCPTUN_REDIR_PORT=$(config_t_get global_proxy kcptun_port 11183)
PROXY_MODE=$(config_t_get global proxy_mode gfwlist)

load_config() {
	[ "$TCP_NODE1" == "nil" -a "$UDP_NODE1" == "nil" -a "$SOCKS5_NODE1" == "nil" ] && {
		echolog "没有选择节点！"
		return 1
	}
	DNS_MODE=$(config_t_get global dns_mode ChinaDNS)
	UP_CHINADNS_MODE=$(config_t_get global up_chinadns_mode OpenDNS_1)
	process=1
	if [ "$(config_t_get global_forwarding process 0)" = "0" ]; then
		process=$(cat /proc/cpuinfo | grep 'processor' | wc -l)
	else
		process=$(config_t_get global_forwarding process)
	fi
	LOCALHOST_PROXY_MODE=$(config_t_get global localhost_proxy_mode default)
	DNS1=$(config_t_get global_dns dns_1)
	DNS2=$(config_t_get global_dns dns_2)
	TCP_REDIR_PORT1=$(config_t_get global_proxy tcp_redir_port 1041)
	TCP_REDIR_PORT2=$(expr $TCP_REDIR_PORT1 + 1)
	TCP_REDIR_PORT3=$(expr $TCP_REDIR_PORT2 + 1)
	UDP_REDIR_PORT1=$(config_t_get global_proxy udp_redir_port 1051)
	UDP_REDIR_PORT2=$(expr $UDP_REDIR_PORT1 + 1)
	UDP_REDIR_PORT3=$(expr $UDP_REDIR_PORT2 + 1)
	SOCKS5_PROXY_PORT1=$(config_t_get global_proxy socks5_proxy_port 1061)
	SOCKS5_PROXY_PORT2=$(expr $SOCKS5_PROXY_PORT1 + 1)
	SOCKS5_PROXY_PORT3=$(expr $SOCKS5_PROXY_PORT2 + 1)
	PROXY_IPV6=$(config_t_get global_proxy proxy_ipv6 0)
	mkdir -p /var/etc $CONFIG_PATH $RUN_PID_PATH $RUN_PORT_PATH
	config_load $CONFIG
	return 0
}

gen_ss_ssr_config_file() {
	local type local_port kcptun node configfile
	type=$1
	local_port=$2
	kcptun=$3
	node=$4
	configfile=$5
	local port encrypt_method
	port=$(config_n_get $node port)
	encrypt_method=$(config_n_get $node ss_encrypt_method)
	[ "$type" == "ssr" ] && encrypt_method=$(config_n_get $node ssr_encrypt_method)
	[ "$kcptun" == "1" ] && {
		server_ip=127.0.0.1
		server_host=127.0.0.1
		port=$KCPTUN_REDIR_PORT
	}
	cat <<-EOF >$configfile
		{
			"server": "$server_host",
			"_comment": "$server_ip",
			"server_port": $port,
			"local_address": "0.0.0.0",
			"local_port": $local_port,
			"password": "$(config_n_get $node password)",
			"timeout": $(config_n_get $node timeout),
			"method": "$encrypt_method",
			"fast_open": $(config_n_get $node tcp_fast_open false),
			"reuse_port": true,
	EOF
	[ "$1" == "ssr" ] && {
		cat <<-EOF >>$configfile
			"protocol": "$(config_n_get $node protocol)",
			"protocol_param": "$(config_n_get $node protocol_param)",
			"obfs": "$(config_n_get $node obfs)",
			"obfs_param": "$(config_n_get $node obfs_param)"
		EOF
	}
	echo -e "}" >>$configfile
}

gen_config_file() {
	local node local_port redir_type config_file_path server_host server_ip port type use_ipv6 network_type
	node=$1
	local_port=$2
	redir_type=$3
	config_file_path=$4
	remarks=$(config_n_get $node remarks)
	server_host=$(config_n_get $node address)
	use_ipv6=$(config_n_get $node use_ipv6)
	network_type="ipv4"
	[ "$use_ipv6" == "1" ] && network_type="ipv6"
	server_ip=$(get_host_ip $network_type $server_host)
	port=$(config_n_get $node port)
	type=$(echo $(config_n_get $node type) | tr 'A-Z' 'a-z')
	echolog "$redir_type节点：$remarks"
	echolog "$redir_type节点IP：$server_ip"

	if [ "$redir_type" == "Socks5" ]; then
		if [ "$network_type" == "ipv6" ]; then
			SOCKS5_NODE1_IPV6=$server_ip
		else
			SOCKS5_NODE1_IP=$server_ip
		fi
		SOCKS5_NODE1_PORT=$port
		if [ "$type" == "ss" -o "$type" == "ssr" ]; then
			gen_ss_ssr_config_file $type $local_port 0 $node $config_file_path
		elif [ "$type" == "v2ray" ]; then
			lua /usr/lib/lua/luci/model/cbi/passwall/api/gen_v2ray_client_config_file.lua $node nil nil $local_port >$config_file_path
		elif [ "$type" == "brook" ]; then
			BROOK_SOCKS5_CMD="client -l 0.0.0.0:$local_port -i 0.0.0.0 -s $server_ip:$port -p $(config_n_get $node password)"
		elif [ "$type" == "trojan" ]; then
			lua /usr/lib/lua/luci/model/cbi/passwall/api/gen_trojan_client_config_file.lua $node client $local_port >$config_file_path
		fi
	fi

	if [ "$redir_type" == "UDP" ]; then
		if [ "$network_type" == "ipv6" ]; then
			UDP_NODE1_IPV6=$server_ip
		else
			UDP_NODE1_IP=$server_ip
		fi
		UDP_NODE1_PORT=$port
		if [ "$type" == "ss" -o "$type" == "ssr" ]; then
			gen_ss_ssr_config_file $type $local_port 0 $node $config_file_path
		elif [ "$type" == "v2ray" ]; then
			lua /usr/lib/lua/luci/model/cbi/passwall/api/gen_v2ray_client_config_file.lua $node udp $local_port nil >$config_file_path
		elif [ "$type" == "brook" ]; then
			BROOK_UDP_CMD="tproxy -l 0.0.0.0:$local_port -s $server_ip:$port -p $(config_n_get $node password)"
		elif [ "$type" == "trojan" ]; then
			local_port=$(get_not_exists_port_after $SOCKS5_PROXY_PORT1 tcp)
			socks5_port=$local_port
			lua /usr/lib/lua/luci/model/cbi/passwall/api/gen_trojan_client_config_file.lua $node client $socks5_port >$config_file_path
		fi
	fi

	if [ "$redir_type" == "TCP" ]; then
		if [ "$network_type" == "ipv6" ]; then
			TCP_NODE1_IPV6=$server_ip
		else
			TCP_NODE1_IP=$server_ip
		fi
		TCP_NODE1_PORT=$port
		if [ "$type" == "v2ray" ]; then
			lua /usr/lib/lua/luci/model/cbi/passwall/api/gen_v2ray_client_config_file.lua $node tcp $local_port nil >$config_file_path
		elif [ "$type" == "trojan" ]; then
			lua /usr/lib/lua/luci/model/cbi/passwall/api/gen_trojan_client_config_file.lua $node nat $local_port >$config_file_path
		else
			local kcptun_use kcptun_server_host kcptun_port kcptun_config
			kcptun_use=$(config_n_get $node use_kcp)
			kcptun_server_host=$(config_n_get $node kcp_server)
			kcptun_port=$(config_n_get $node kcp_port)
			kcptun_config=$(config_n_get $node kcp_opts)
			kcptun_path=""
			lbenabled=$(config_t_get global_haproxy balancing_enable 0)
			if [ "$kcptun_use" == "1" ] && ([ -z "$kcptun_port" ] || [ -z "$kcptun_config" ]); then
				echolog "【检测到启用KCP，但未配置KCP参数】，跳过~"
			fi
			if [ "$kcptun_use" == "1" -a -n "$kcptun_port" -a -n "$kcptun_config" -a "$lbenabled" == "1" ]; then
				echolog "【检测到启用KCP，但KCP与负载均衡二者不能同时开启】，跳过~"
			fi

			if [ "$kcptun_use" == "1" ]; then
				if [ -f "$(config_t_get global_kcptun kcptun_client_file)" ]; then
					kcptun_path=$(config_t_get global_kcptun kcptun_client_file)
				else
					temp=$(find_bin kcptun_client)
					[ -n "$temp" ] && kcptun_path=$temp
				fi
			fi

			if [ "$kcptun_use" == "1" -a -z "$kcptun_path" ] && ([ -n "$kcptun_port" ] || [ -n "$kcptun_config" ]); then
				echolog "【检测到启用KCP，但未安装KCP主程序，请自行到自动更新下载KCP】，跳过~"
			fi

			if [ "$kcptun_use" == "1" -a -n "$kcptun_port" -a -n "$kcptun_config" -a "$lbenabled" == "0" -a -n "$kcptun_path" ]; then
				if [ -z "$kcptun_server_host" ]; then
					start_kcptun "$kcptun_path" $server_ip $kcptun_port "$kcptun_config"
				else
					kcptun_use_ipv6=$(config_n_get $node kcp_use_ipv6)
					network_type="ipv4"
					[ "$kcptun_use_ipv6" == "1" ] && network_type="ipv6"
					kcptun_server_ip=$(get_host_ip $network_type $kcptun_server_host)
					echolog "KCP节点IP地址:$kcptun_server_ip"
					TCP_NODE1_IP=$kcptun_server_ip
					start_kcptun "$kcptun_path" $kcptun_server_ip $kcptun_port "$kcptun_config"
				fi
				echolog "运行Kcptun..."
				if [ "$type" == "ss" -o "$type" == "ssr" ]; then
					gen_ss_ssr_config_file $type $local_port 1 $node $config_file_path
				fi
				if [ "$type" == "brook" ]; then
					BROOK_TCP_CMD="tproxy -l 0.0.0.0:$local_port -s 127.0.0.1:$KCPTUN_REDIR_PORT -p $(config_n_get $node password)"
				fi
			else
				if [ "$type" == "ss" -o "$type" == "ssr" ]; then
					gen_ss_ssr_config_file $type $local_port 0 $node $config_file_path
				elif [ "$type" == "brook" ]; then
					BROOK_TCP_CMD="tproxy -l 0.0.0.0:$local_port -s $server_ip:$port -p $(config_n_get $node password)"
				fi
			fi
		fi
	fi
	return 0
}

start_kcptun() {
	kcptun_bin=$1
	if [ -z "$kcptun_bin" ]; then
		echolog "找不到Kcptun客户端主程序，无法启用！！！"
	else
		$kcptun_bin --log $CONFIG_PATH/kcptun -l 0.0.0.0:$KCPTUN_REDIR_PORT -r $2:$3 $4 >/dev/null 2>&1 &
	fi
}

start_tcp_redir() {
	for i in $(seq 1 $TCP_NODE_NUM); do
		eval temp_server=\$TCP_NODE$i
		[ "$temp_server" != "nil" ] && {
			TYPE=$(echo $(config_n_get $temp_server type) | tr 'A-Z' 'a-z')
			local config_file=$CONFIG_PATH/TCP_$i.json
			eval current_port=\$TCP_REDIR_PORT$i
			local port=$(echo $(get_not_exists_port_after $current_port tcp))
			eval TCP_REDIR_PORT$i=$port
			gen_config_file $temp_server $port TCP $config_file
			if [ "$TYPE" == "v2ray" ]; then
				v2ray_path=$(config_t_get global_app v2ray_file)
				if [ -f "${v2ray_path}/v2ray" ]; then
					${v2ray_path}/v2ray -config=$config_file >/dev/null &
				else
					v2ray_bin=$(find_bin V2ray)
					[ -n "$v2ray_bin" ] && $v2ray_bin -config=$config_file >/dev/null &
				fi
			elif [ "$TYPE" == "brook" ]; then
				brook_bin=$(config_t_get global_app brook_file)
				if [ -f "$brook_bin" ]; then
					$brook_bin $BROOK_TCP_CMD &>/dev/null &
				else
					brook_bin=$(find_bin Brook)
					[ -n "$brook_bin" ] && $brook_bin $BROOK_TCP_CMD &>/dev/null &
				fi
			elif [ "$TYPE" == "trojan" ]; then
				trojan_bin=$(find_bin trojan)
				[ -n "$trojan_bin" ] && $trojan_bin -c $config_file >/dev/null 2>&1 &
			elif [ "$TYPE" == "socks5" ]; then
				local address=$(config_n_get $temp_server address)
				local port=$(config_n_get $temp_server port)
				local server_username=$(config_n_get $temp_server username)
				local server_password=$(config_n_get $temp_server password)
				ipt2socks_bin=$(find_bin ipt2socks)
				[ -n "$ipt2socks_bin" ] && {
					$ipt2socks_bin -T -l $port -b 0.0.0.0 -s $address -p $port -R >/dev/null &
				}
				#redsocks_bin=$(find_bin redsocks2)
				#[ -n "$redsocks_bin" ] && {
				#	local redsocks_config_file=$CONFIG_PATH/TCP_$i.conf
				#	gen_redsocks_config $redsocks_config_file tcp $port $address $port $server_username $server_password
				#	$redsocks_bin -c $redsocks_config_file >/dev/null &
				#}
			elif [ "$TYPE" == "ss" -o "$TYPE" == "ssr" ]; then
				ss_bin=$(find_bin "$TYPE"-redir)
				[ -n "$ss_bin" ] && {
					for k in $(seq 1 $process); do
						$ss_bin -c $config_file -f $RUN_PID_PATH/tcp_${TYPE}_$k_$i >/dev/null 2>&1 &
					done
				}
			fi
			echo $port > $CONFIG_PATH/port/TCP_${i}
		}
	done
}

start_udp_redir() {
	for i in $(seq 1 $UDP_NODE_NUM); do
		eval temp_server=\$UDP_NODE$i
		[ "$temp_server" != "nil" ] && {
			TYPE=$(echo $(config_n_get $temp_server type) | tr 'A-Z' 'a-z')
			local config_file=$CONFIG_PATH/UDP_$i.json
			eval current_port=\$UDP_REDIR_PORT$i
			local port=$(echo $(get_not_exists_port_after $current_port udp))
			eval UDP_REDIR_PORT$i=$port
			gen_config_file $temp_server $port UDP $config_file
			if [ "$TYPE" == "v2ray" ]; then
				v2ray_path=$(config_t_get global_app v2ray_file)
				if [ -f "${v2ray_path}/v2ray" ]; then
					${v2ray_path}/v2ray -config=$config_file >/dev/null &
				else
					v2ray_bin=$(find_bin V2ray)
					[ -n "$v2ray_bin" ] && $v2ray_bin -config=$config_file >/dev/null &
				fi
			elif [ "$TYPE" == "brook" ]; then
				brook_bin=$(config_t_get global_app brook_file)
				if [ -f "$brook_bin" ]; then
					$brook_bin $BROOK_UDP_CMD >/dev/null &
				else
					brook_bin=$(find_bin Brook)
					[ -n "$brook_bin" ] && $brook_bin $BROOK_UDP_CMD >/dev/null &
				fi
			elif [ "$TYPE" == "trojan" ]; then
				trojan_bin=$(find_bin trojan)
				[ -n "$trojan_bin" ] && $trojan_bin -c $config_file >/dev/null 2>&1 &
				local address=$(config_n_get $temp_server address)
				local port=$(config_n_get $temp_server port)
				local server_username=$(config_n_get $temp_server username)
				local server_password=$(config_n_get $temp_server password)
				ipt2socks_bin=$(find_bin ipt2socks)
				[ -n "$ipt2socks_bin" ] && {
					$ipt2socks_bin -U -l $port -b 0.0.0.0 -s 127.0.0.1 -p $socks5_port -R >/dev/null &
				}
				
				#redsocks_bin=$(find_bin redsocks2)
				#[ -n "$redsocks_bin" ] && {
				#	local redsocks_config_file=$CONFIG_PATH/redsocks_UDP_$i.conf
				#	gen_redsocks_config $redsocks_config_file udp $port "127.0.0.1" $socks5_port
				#	$redsocks_bin -c $redsocks_config_file >/dev/null &
				#}
			elif [ "$TYPE" == "socks5" ]; then
				local address=$(config_n_get $temp_server address)
				local port=$(config_n_get $temp_server port)
				local server_username=$(config_n_get $temp_server username)
				local server_password=$(config_n_get $temp_server password)
				ipt2socks_bin=$(find_bin ipt2socks)
				[ -n "$ipt2socks_bin" ] && {
					$ipt2socks_bin -U -l $port -b 0.0.0.0 -s $address -p $port -R >/dev/null &
				}
				
				#redsocks_bin=$(find_bin redsocks2)
				#[ -n "$redsocks_bin" ] && {
				#	local redsocks_config_file=$CONFIG_PATH/UDP_$i.conf
				#	gen_redsocks_config $redsocks_config_file udp $port $address $port $server_username $server_password
				#	$redsocks_bin -c $redsocks_config_file >/dev/null &
				#}
			elif [ "$TYPE" == "ss" -o "$TYPE" == "ssr" ]; then
				ss_bin=$(find_bin "$TYPE"-redir)
				[ -n "$ss_bin" ] && {
					$ss_bin -c $config_file -f $RUN_PID_PATH/udp_${TYPE}_1_$i -U >/dev/null 2>&1 &
				}
			fi
			echo $port > $CONFIG_PATH/port/UDP_${i}
		}
	done
}

start_socks5_proxy() {
	for i in $(seq 1 $SOCKS5_NODE_NUM); do
		eval temp_server=\$SOCKS5_NODE$i
		if [ "$temp_server" != "nil" ]; then
			TYPE=$(echo $(config_n_get $temp_server type) | tr 'A-Z' 'a-z')
			local config_file=$CONFIG_PATH/Socks5_$i.json
			eval current_port=\$SOCKS5_PROXY_PORT$i
			local port=$(get_not_exists_port_after $current_port tcp)
			eval SOCKS5_PROXY_PORT$i=$port
			gen_config_file $temp_server $port Socks5 $config_file
			if [ "$TYPE" == "v2ray" ]; then
				v2ray_path=$(config_t_get global_app v2ray_file)
				if [ -f "${v2ray_path}/v2ray" ]; then
					${v2ray_path}/v2ray -config=$config_file >/dev/null &
				else
					v2ray_bin=$(find_bin V2ray)
					[ -n "$v2ray_bin" ] && $v2ray_bin -config=$config_file >/dev/null &
				fi
			elif [ "$TYPE" == "brook" ]; then
				brook_bin=$(config_t_get global_app brook_file)
				if [ -f "$brook_bin" ]; then
					$brook_bin $BROOK_SOCKS5_CMD >/dev/null &
				else
					brook_bin=$(find_bin Brook)
					[ -n "$brook_bin" ] && $brook_bin $BROOK_SOCKS5_CMD >/dev/null &
				fi
			elif [ "$TYPE" == "trojan" ]; then
				trojan_bin=$(find_bin trojan)
				[ -n "$trojan_bin" ] && $trojan_bin -c $config_file >/dev/null 2>&1 &
			elif [ "$TYPE" == "socks5" ]; then
				echolog "Socks5节点不能使用Socks5代理节点！"
			elif [ "$TYPE" == "ss" -o "$TYPE" == "ssr" ]; then
				ss_bin=$(find_bin "$TYPE"-local)
				[ -n "$ss_bin" ] && $ss_bin -c $config_file -b 0.0.0.0 >/dev/null 2>&1 &
			fi
			echo $port > $CONFIG_PATH/port/Socks5_${i}
		fi
	done
}

clean_log() {
	logsnum=$(cat $LOG_FILE 2>/dev/null | wc -l)
	if [ "$logsnum" -gt 300 ]; then
		rm -f $LOG_FILE >/dev/null 2>&1 &
		echolog "日志文件过长，清空处理！"
	fi
}

set_cru() {
	autoupdate=$(config_t_get global_rules auto_update)
	weekupdate=$(config_t_get global_rules week_update)
	dayupdate=$(config_t_get global_rules time_update)
	autoupdatesubscribe=$(config_t_get global_subscribe auto_update_subscribe)
	weekupdatesubscribe=$(config_t_get global_subscribe week_update_subscribe)
	dayupdatesubscribe=$(config_t_get global_subscribe time_update_subscribe)
	if [ "$autoupdate" = "1" ]; then
		if [ "$weekupdate" = "7" ]; then
			echo "0 $dayupdate * * * $APP_PATH/rule_update.sh" >>/etc/crontabs/root
			echolog "设置自动更新规则在每天 $dayupdate 点。"
		else
			echo "0 $dayupdate * * $weekupdate $APP_PATH/rule_update.sh" >>/etc/crontabs/root
			echolog "设置自动更新规则在星期 $weekupdate 的 $dayupdate 点。"
		fi
	else
		sed -i '/rule_update.sh/d' /etc/crontabs/root >/dev/null 2>&1 &
	fi

	if [ "$autoupdatesubscribe" = "1" ]; then
		if [ "$weekupdatesubscribe" = "7" ]; then
			echo "0 $dayupdatesubscribe * * * $APP_PATH/subscription.sh" >>/etc/crontabs/root
			echolog "设置节点订阅自动更新规则在每天 $dayupdatesubscribe 点。"
		else
			echo "0 $dayupdatesubscribe * * $weekupdate $APP_PATH/subscription.sh" >>/etc/crontabs/root
			echolog "设置节点订阅自动更新规则在星期 $weekupdate 的 $dayupdatesubscribe 点。"
		fi
	else
		sed -i '/subscription.sh/d' /etc/crontabs/root >/dev/null 2>&1 &
	fi
}

start_crontab() {
	sed -i '/$CONFIG/d' /etc/crontabs/root >/dev/null 2>&1 &
	start_daemon=$(config_t_get global_delay start_daemon)
	if [ "$start_daemon" = "1" ]; then
		echo "*/2 * * * * nohup $APP_PATH/monitor.sh > /dev/null 2>&1" >>/etc/crontabs/root
		echolog "已启动守护进程。"
	fi

	auto_on=$(config_t_get global_delay auto_on)
	if [ "$auto_on" = "1" ]; then
		time_off=$(config_t_get global_delay time_off)
		time_on=$(config_t_get global_delay time_on)
		time_restart=$(config_t_get global_delay time_restart)
		[ -z "$time_off" -o "$time_off" != "nil" ] && {
			echo "0 $time_off * * * /etc/init.d/$CONFIG stop" >>/etc/crontabs/root
			echolog "设置自动关闭在每天 $time_off 点。"
		}
		[ -z "$time_on" -o "$time_on" != "nil" ] && {
			echo "0 $time_on * * * /etc/init.d/$CONFIG start" >>/etc/crontabs/root
			echolog "设置自动开启在每天 $time_on 点。"
		}
		[ -z "$time_restart" -o "$time_restart" != "nil" ] && {
			echo "0 $time_restart * * * /etc/init.d/$CONFIG restart" >>/etc/crontabs/root
			echolog "设置自动重启在每天 $time_restart 点。"
		}
	fi

	[ "$AUTO_SWITCH_ENABLE" = "1" ] && {
		testing_time=$(config_t_get auto_switch testing_time)
		[ -n "$testing_time" ] && {
			echo "*/$testing_time * * * * nohup $APP_PATH/test.sh > /dev/null 2>&1" >>/etc/crontabs/root
			echolog "设置每$testing_time分钟执行检测脚本。"
		}
	}
	/etc/init.d/cron restart
}

stop_crontab() {
	sed -i "/$CONFIG/d" /etc/crontabs/root >/dev/null 2>&1 &
	ps | grep "$APP_PATH/test.sh" | grep -v "grep" | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1 &
	rm -f /var/lock/passwall_test.lock >/dev/null 2>&1 &
	/etc/init.d/cron restart
	echolog "清除定时执行命令。"
}

start_dns() {
	case "$DNS_MODE" in
	nonuse)
		echolog "不使用任何DNS转发模式，将会直接将WAN口DNS给dnsmasq上游！"
	;;
	local_7913)
		echolog "运行DNS转发模式：使用本机7913端口DNS服务器解析域名..."
	;;
	dns2socks)
		if [ -n "$SOCKS5_NODE1" -a "$SOCKS5_NODE1" != "nil" ]; then
			dns2socks_bin=$(find_bin dns2socks)
			[ -n "$dns2socks_bin" ] && {
				local dns=$(config_t_get global dns2socks_forward 8.8.4.4)
				nohup $dns2socks_bin 127.0.0.1:$SOCKS5_PROXY_PORT1 ${dns}:53 127.0.0.1:$DNS_PORT >/dev/null 2>&1 &
				echolog "运行DNS转发模式：dns2socks..."
			}
		else
			echolog "dns2socks模式需要使用Socks5代理节点，请开启！"
		fi
	;;
	pdnsd)
		pdnsd_bin=$(find_bin pdnsd)
		[ -n "$pdnsd_bin" ] && {
			gen_pdnsd_config
			nohup $pdnsd_bin --daemon -c $CACHEDIR/pdnsd.conf -p $RUN_PID_PATH/pdnsd.pid -d >/dev/null 2>&1 &
			echolog "运行DNS转发模式：Pdnsd..."
		}
	;;
	chinadns)
		chinadns_bin=$(find_bin ChinaDNS)
		[ -n "$chinadns_bin" ] && {
			other=1
			other_port=$(expr $DNS_PORT + 1)
			echolog "运行DNS转发模式：ChinaDNS..."
			local dns1=$DNS1
			[ "$DNS1" = "dnsbyisp" ] && dns1=$(cat /tmp/resolv.conf.auto 2>/dev/null | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | grep -v 0.0.0.0 | grep -v 127.0.0.1 | sed -n '1P')
			case "$UP_CHINADNS_MODE" in
			OpenDNS_1)
				other=0
				nohup $chinadns_bin -p $DNS_PORT -c $RULE_PATH/chnroute -m -d -s $dns1,208.67.222.222:443,208.67.222.222:5353 >/dev/null 2>&1 &
				echolog "运行ChinaDNS上游转发模式：$dns1,208.67.222.222..."
				;;
			OpenDNS_2)
				other=0
				nohup $chinadns_bin -p $DNS_PORT -c $RULE_PATH/chnroute -m -d -s $dns1,208.67.220.220:443,208.67.220.220:5353 >/dev/null 2>&1 &
				echolog "运行ChinaDNS上游转发模式：$dns1,208.67.220.220..."
				;;
			custom)
				other=0
				UP_CHINADNS_CUSTOM=$(config_t_get global up_chinadns_custom '114.114.114.114,208.67.222.222:5353')
				nohup $chinadns_bin -p $DNS_PORT -c $RULE_PATH/chnroute -m -d -s $UP_CHINADNS_CUSTOM >/dev/null 2>&1 &
				echolog "运行ChinaDNS上游转发模式：$UP_CHINADNS_CUSTOM..."
				;;
			esac
			if [ "$other" = "1" ]; then
				nohup $chinadns_bin -p $DNS_PORT -c $RULE_PATH/chnroute -m -d -s $dns1,127.0.0.1:$other_port >/dev/null 2>&1 &
			fi
		}
	;;
	esac
	echolog "若不正常，请尝试其他模式！"
}

add_dnsmasq() {
	mkdir -p $TMP_DNSMASQ_PATH $DNSMASQ_PATH /var/dnsmasq.d
	local wirteconf dnsconf dnsport isp_dns isp_ip
	dnsport=$(config_t_get global_dns dns_port)
	[ -z "$dnsport" ] && dnsport=0
	if [ "$DNS1" = "dnsbyisp" -o "$DNS2" = "dnsbyisp" ]; then
		cat >/etc/dnsmasq.conf <<EOF
all-servers
no-poll
no-resolv
cache-size=2048
local-ttl=60
neg-ttl=3600
max-cache-ttl=1200
EOF
		echolog "生成Dnsmasq配置文件。"

		if [ "$dnsport" != "0" ]; then
			failcount=0
			while [ "$failcount" -lt "10" ]; do
				interface=$(ifconfig | grep "$dnsport" | awk '{print $1}')
				if [ -z "$interface" ]; then
					echolog "找不到出口接口：$dnsport，1分钟后再重试"
					let "failcount++"
					[ "$failcount" -ge 10 ] && exit 0
					sleep 1m
				else
					[ "$DNS1" != "dnsbyisp" ] && {
						route add -host ${DNS1} dev ${dnsport}
						echolog "添加DNS1出口路由表：$dnsport"
						echo server=$DNS1 >>/etc/dnsmasq.conf
					}
					[ "$DNS2" != "dnsbyisp" ] && {
						route add -host ${DNS2} dev ${dnsport}
						echolog "添加DNS2出口路由表：$dnsport"
						echo server=$DNS2 >>/etc/dnsmasq.conf
					}
					break
				fi
			done
		else
			isp_dnss=$(cat /tmp/resolv.conf.auto 2>/dev/null | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | sort -u | grep -v 0.0.0.0 | grep -v 127.0.0.1)
			[ -n "$isp_dnss" ] && {
				for isp_dns in $isp_dnss; do
					echo server=$isp_dns >>/etc/dnsmasq.conf
				done
			}
			[ "$DNS1" != "dnsbyisp" ] && {
				echo server=$DNS1 >>/etc/dnsmasq.conf
			}
			[ "$DNS2" != "dnsbyisp" ] && {
				echo server=$DNS2 >>/etc/dnsmasq.conf
			}
		fi
	else
		wirteconf=$(cat /etc/dnsmasq.conf 2>/dev/null | grep "server=$DNS1")
		dnsconf=$(cat /etc/dnsmasq.conf 2>/dev/null | grep "server=$DNS2")
		if [ "$dnsport" != "0" ]; then
			failcount=0
			while [ "$failcount" -lt "10" ]; do
				interface=$(ifconfig | grep "$dnsport" | awk '{print $1}')
				if [ -z "$interface" ]; then
					echolog "找不到出口接口：$dnsport，1分钟后再重试"
					let "failcount++"
					[ "$failcount" -ge 10 ] && exit 0
					sleep 1m
				else
					route add -host ${DNS1} dev ${dnsport}
					echolog "添加DNS1出口路由表：$dnsport"
					route add -host ${DNS2} dev ${dnsport}
					echolog "添加DNS2出口路由表：$dnsport"
					break
				fi
			done
		fi
		if [ -z "$wirteconf" ] || [ -z "$dnsconf" ]; then
			cat >/etc/dnsmasq.conf <<EOF
all-servers
no-poll
no-resolv
server=$DNS1
server=$DNS2
cache-size=2048
local-ttl=60
neg-ttl=3600
max-cache-ttl=1200
EOF
			echolog "生成Dnsmasq配置文件。"
		fi
	fi
	# if [ -n "cat /var/state/network |grep pppoe|awk -F '.' '{print $2}'" ]; then
	# sed -i '/except-interface/d' /etc/dnsmasq.conf >/dev/null 2>&1 &
	# for wanname in $(cat /var/state/network |grep pppoe|awk -F '.' '{print $2}')
	# do
	# echo "except-interface=$(uci get network.$wanname.ifname)" >>/etc/dnsmasq.conf
	# done
	# fi

	subscribe_proxy=$(config_t_get global_subscribe subscribe_proxy 0)
	[ "$subscribe_proxy" -eq 1 ] && {
		subscribe_url=$(config_t_get global_subscribe subscribe_url)
		[ -n "$subscribe_url" ] && {
			for url in $subscribe_url; do
				if [ -n "$(echo -n "$url" | grep "//")" ]; then
					echo -n "$url" | awk -F'/' '{print $3}' | sed "s/^/server=&\/./g" | sed "s/$/\/127.0.0.1#$DNS_PORT/g" >>$TMP_DNSMASQ_PATH/subscribe.conf
					echo -n "$url" | awk -F'/' '{print $3}' | sed "s/^/ipset=&\/./g" | sed "s/$/\/router/g" >>$TMP_DNSMASQ_PATH/subscribe.conf
				else
					echo -n "$url" | awk -F'/' '{print $1}' | sed "s/^/server=&\/./g" | sed "s/$/\/127.0.0.1#$DNS_PORT/g" >>$TMP_DNSMASQ_PATH/subscribe.conf
					echo -n "$url" | awk -F'/' '{print $1}' | sed "s/^/ipset=&\/./g" | sed "s/$/\/router/g" >>$TMP_DNSMASQ_PATH/subscribe.conf
				fi
			done
			restdns=1
		}
	}

	if [ ! -f "$TMP_DNSMASQ_PATH/gfwlist.conf" -a "$DNS_MODE" != "nonuse" ]; then
		ln -s $RULE_PATH/gfwlist.conf $TMP_DNSMASQ_PATH/gfwlist.conf
		restdns=1
	fi

	if [ ! -f "$TMP_DNSMASQ_PATH/blacklist_host.conf" -a "$DNS_MODE" != "nonuse" ]; then
		cat $RULE_PATH/blacklist_host | awk '{print "server=/."$1"/127.0.0.1#'$DNS_PORT'\nipset=/."$1"/blacklist"}' >>$TMP_DNSMASQ_PATH/blacklist_host.conf
		restdns=1
	fi

	if [ ! -f "$TMP_DNSMASQ_PATH/whitelist_host.conf" ]; then
		cat $RULE_PATH/whitelist_host | sed "s/^/ipset=&\/./g" | sed "s/$/\/&whitelist/g" | sort | awk '{if ($0!=line) print;line=$0}' >$TMP_DNSMASQ_PATH/whitelist_host.conf
		restdns=1
	fi

	if [ ! -f "$TMP_DNSMASQ_PATH/router.conf" -a "$DNS_MODE" != "nonuse" ]; then
		cat $RULE_PATH/router | awk '{print "server=/."$1"/127.0.0.1#'$DNS_PORT'\nipset=/."$1"/router"}' >>$TMP_DNSMASQ_PATH/router.conf
		restdns=1
	fi

	userconf=$(grep -c "" $RULE_PATH/user.conf)
	if [ "$userconf" -gt 0 ]; then
		ln -s $RULE_PATH/user.conf $TMP_DNSMASQ_PATH/user.conf
		restdns=1
	fi

	backhome=$(config_t_get global proxy_mode gfwlist)
	if [ "$backhome" == "returnhome" ]; then
		rm -rf $TMP_DNSMASQ_PATH/gfwlist.conf
		rm -rf $TMP_DNSMASQ_PATH/blacklist_host.conf
		rm -rf $TMP_DNSMASQ_PATH/whitelist_host.conf
		restdns=1
		echolog "生成回国模式Dnsmasq配置文件。"
	fi

	echo "conf-dir=$TMP_DNSMASQ_PATH" >/var/dnsmasq.d/dnsmasq-$CONFIG.conf
	echo "conf-dir=$TMP_DNSMASQ_PATH" >$DNSMASQ_PATH/dnsmasq-$CONFIG.conf
	if [ "$restdns" == 1 ]; then
		echolog "重启Dnsmasq。。。"
		/etc/init.d/dnsmasq restart 2>/dev/null
	fi
}

gen_redsocks_config() {
	protocol=$2
	local_port=$3
	proxy_server=$4
	proxy_port=$5
	proxy_username=$6
	[ -n "$proxy_username" ] && proxy_username="login = $proxy_username;"
	proxy_password=$7
	[ -n "$proxy_password" ] && proxy_password="password = $proxy_password;"
	[ -n "$1" ] && {
		cat >$1 <<-EOF
			base {
			    log_debug = off;
			    log_info = off;
			    log = "file:/dev/null";
			    daemon = on;
			    redirector = iptables;
			}
			
		EOF
		if [ "$protocol" == "tcp" ]; then
			cat >>$1 <<-EOF
				redsocks {
				    local_ip = 0.0.0.0;
				    local_port = $local_port;
				    type = socks5;
				    autoproxy = 0;
				    ip = $proxy_server;
				    port = $proxy_port;
				    $proxy_username
				    $proxy_password
				}
				
				autoproxy {
				    no_quick_check_seconds = 300;
				    quick_connect_timeout = 2;
				}
				
				ipcache {
				    cache_size = 4;
				    stale_time = 7200;
				    autosave_interval = 3600;
				    port_check = 0;
				}
				
			EOF
		elif [ "$protocol" == "udp" ]; then
			cat >>$1 <<-EOF
				redudp {
				    local_ip = 0.0.0.0;
				    local_port = $local_port;
				    type = socks5;
				    ip = $proxy_server;
				    port = $proxy_port;
				    $proxy_username
				    $proxy_password
				    udp_timeout = 60;
				    udp_timeout_stream = 360;
				}
				
			EOF
		fi
	}
}

gen_pdnsd_config() {
	CACHEDIR=/var/pdnsd
	CACHE=$CACHEDIR/pdnsd.cache
	if ! test -f "$CACHE"; then
		mkdir -p $(dirname $CACHE)
		touch $CACHE
		chown -R root.nogroup $CACHEDIR
	fi
	cat >$CACHEDIR/pdnsd.conf <<-EOF
		global {
			perm_cache=1024;
			cache_dir="/var/pdnsd";
			run_as="root";
			server_ip = 127.0.0.1;
			server_port=$DNS_PORT;
			status_ctl = on;
			query_method=tcp_only;
			min_ttl=1d;
			max_ttl=1w;
			timeout=10;
			tcp_qtimeout=1;
			par_queries=2;
			neg_domain_pol=on;
			udpbufsize=1024;
			}
		server {
			label = "opendns";
			ip = 208.67.222.222, 208.67.220.220;
			edns_query=on;
			port = 5353;
			timeout = 4;
			interval=60;
			uptest = none;
			purge_cache=off;
			caching=on;
			}
		source {
			ttl=86400;
			owner="localhost.";
			serve_aliases=on;
			file="/etc/hosts";
			}
	EOF
}

stop_dnsmasq() {
	rm -rf /var/dnsmasq.d/dnsmasq-$CONFIG.conf
	rm -rf $DNSMASQ_PATH/dnsmasq-$CONFIG.conf
	rm -rf $TMP_DNSMASQ_PATH
	/etc/init.d/dnsmasq restart 2>/dev/null
}

start_haproxy() {
	enabled=$(config_t_get global_haproxy balancing_enable 0)
	[ "$enabled" = "1" ] && {
		haproxy_bin=$(find_bin haproxy)
		[ -n "$haproxy_bin" ] && {
			bport=$(config_t_get global_haproxy haproxy_port)
			cat <<-EOF >$HAPROXY_FILE
				global
				    log         127.0.0.1 local2
				    chroot      /usr/bin
				    pidfile     $RUN_PID_PATH/haproxy.pid
				    maxconn     60000
				    stats socket  $RUN_PID_PATH/haproxy.sock
				    user        root
				    daemon
					
				defaults
				    mode                    tcp
				    log                     global
				    option                  tcplog
				    option                  dontlognull
				    option http-server-close
				    #option forwardfor       except 127.0.0.0/8
				    option                  redispatch
				    retries                 2
				    timeout http-request    10s
				    timeout queue           1m
				    timeout connect         10s
				    timeout client          1m
				    timeout server          1m
				    timeout http-keep-alive 10s
				    timeout check           10s
				    maxconn                 3000
					
				listen passwall
				    bind 0.0.0.0:$bport
				    mode tcp
			EOF
			for i in $(seq 0 100); do
				bips=$(config_t_get balancing lbss '' $i)
				bports=$(config_t_get balancing lbort '' $i)
				bweight=$(config_t_get balancing lbweight '' $i)
				exports=$(config_t_get balancing export '' $i)
				bbackup=$(config_t_get balancing backup '' $i)
				if [ -z "$bips" ] || [ -z "$bports" ]; then
					break
				fi
				if [ "$bbackup" = "1" ]; then
					bbackup=" backup"
					echolog "添加故障转移备节点:$bips"
				else
					bbackup=""
					echolog "添加负载均衡主节点:$bips"
				fi
				#si=$(echo $bips | grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}")
				#if [ -z "$si" ]; then
				#	bips=$(resolveip -4 -t 2 $bips | awk 'NR==1{print}')
				#	if [ -z "$bips" ]; then
				#		bips=$(nslookup $bips localhost | sed '1,4d' | awk '{print $3}' | grep -v : | awk 'NR==1{print}')
				#	fi
				#	echolog "负载均衡${i} IP为：$bips"
				#fi
				echo "    server server_$i $bips:$bports weight $bweight check inter 1500 rise 1 fall 3 $bbackup" >>$HAPROXY_FILE
				if [ "$exports" != "0" ]; then
					failcount=0
					while [ "$failcount" -lt "10" ]; do
						interface=$(ifconfig | grep "$exports" | awk '{print $1}')
						if [ -z "$interface" ]; then
							echolog "找不到出口接口：$exports，1分钟后再重试"
							let "failcount++"
							[ "$failcount" -ge 10 ] && exit 0
							sleep 1m
						else
							route add -host ${bips} dev ${exports}
							echolog "添加SS出口路由表：$exports"
							echo "$bips" >>/tmp/balancing_ip
							break
						fi
					done
				fi
			done
			#生成负载均衡控制台
			console_port=$(config_t_get global_haproxy console_port)
			console_user=$(config_t_get global_haproxy console_user)
			console_password=$(config_t_get global_haproxy console_password)
			cat <<-EOF >>$HAPROXY_FILE
			
				listen status
				    bind 0.0.0.0:$console_port
				    mode http                   
				    stats refresh 30s
				    stats uri  /  
				    stats auth $console_user:$console_password
				    #stats hide-version
				    stats admin if TRUE
			EOF
			nohup $haproxy_bin -f $HAPROXY_FILE 2>&1
			echolog "负载均衡运行成功！"
		}
	}
}

add_vps_port() {
	multiwan=$(config_t_get global_dns wan_port 0)
	if [ "$multiwan" != "0" ]; then
		failcount=0
		while [ "$failcount" -lt "10" ]; do
			interface=$(ifconfig | grep "$multiwan" | awk '{print $1}')
			if [ -z "$interface" ]; then
				echolog "找不到出口接口：$multiwan，1分钟后再重试"
				let "failcount++"
				[ "$failcount" -ge 10 ] && exit 0
				sleep 1m
			else
				route add -host ${TCP_NODE1_IP} dev ${multiwan}
				route add -host ${UDP_NODE1_IP} dev ${multiwan}
				echolog "添加SS出口路由表：$multiwan"
				echo "$TCP_NODE1_IP" >$CONFIG_PATH/tcp_ip
				echo "$UDP_NODE1_IP" >$CONFIG_PATH/udp_ip
				break
			fi
		done
	fi
}

del_vps_port() {
	tcp_ip=$(cat $CONFIG_PATH/tcp_ip 2>/dev/null)
	udp_ip=$(cat $CONFIG_PATH/udp_ip 2>/dev/null)
	[ -n "$tcp_ip" ] && route del -host ${tcp_ip}
	[ -n "$udp_ip" ] && route del -host ${udp_ip}
}

kill_all() {
	kill -9 $(pidof $@) >/dev/null 2>&1 &
}

boot() {
	local delay=$(config_t_get global_delay start_delay 0)
	if [ "$delay" -gt 0 ]; then
		[ "$TCP_NODE1" != "nil" -o "$UDP_NODE1" != "nil" ] && {
			echolog "执行启动延时 $delay 秒后再启动!"
			sleep $delay && start >/dev/null 2>&1 &
		}
	else
		start
	fi
	return 0
}

start() {
	#防止并发启动
	[ -f "$LOCK_FILE" ] && return 3
	touch "$LOCK_FILE"
	echolog "开始运行脚本！"
	! load_config && return 1
	add_vps_port
	start_haproxy
	start_socks5_proxy
	start_tcp_redir
	start_udp_redir
	start_dns
	add_dnsmasq
	source $APP_PATH/iptables.sh start
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 &
	start_crontab
	set_cru
	rm -f "$LOCK_FILE"
	echolog "运行完成！"
	return 0
}

stop() {
	while [ -f "$LOCK_FILE" ]; do
		sleep 1s
	done
	clean_log
	source $APP_PATH/iptables.sh stop
	del_vps_port
	kill_all pdnsd brook dns2socks haproxy chinadns ipt2socks
	ps -w | grep -E "$CONFIG_TCP_FILE|$CONFIG_UDP_FILE|$CONFIG_SOCKS5_FILE" | grep -v "grep" | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1 &
	ps -w | grep -E "$CONFIG_PATH" | grep -v "grep" | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1 &
	ps -w | grep "kcptun_client" | grep "$KCPTUN_REDIR_PORT" | grep -v "grep" | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1 &
	rm -rf /var/pdnsd/pdnsd.cache
	rm -rf $TMP_DNSMASQ_PATH
	rm -rf $CONFIG_PATH
	stop_dnsmasq
	stop_crontab
	echolog "关闭相关程序，清理相关文件和缓存完成。\n"
	sleep 1s
}

case $1 in
stop)
	stop
	;;
start)
	start
	;;
boot)
	boot
	;;
*)
	echo "Usage: $0 (start|stop|restart)"
	;;
esac
