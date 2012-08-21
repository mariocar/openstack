#!/bin/bash -x

MYSQLCONF=/etc/my.cnf
#MySQL Pressure User-Data - Brain Fuck OLTP
SRVUID=$(echo `hostname`|tr -d "[a-z][A-Z]")
sed -i "s/%SERVERID%/${SRVUID}/g" /etc/server_id.cnf
MEM=`awk '/MemTotal/ {print $2}' /proc/meminfo`
GMEM=`echo "scale=10;$MEM/1024/1024"|bc|xargs printf "%1.0f"`
CPUS=`grep proc /proc/cpuinfo|wc -l`
function config_my_cnf(){
	CONFIG=$1
	mv $MYSQLCONF ${MYSQLCONF}.install
	cp /usr/share/mysql/my-${CONFIG}.cnf ${MYSQLCONF}.1
	sed -i 's/^#innodb/innodb/g' ${MYSQLCONF}.1
        sed -i 's/\(innodb_.*dir\).*/\1 = \/data\/data/g' ${MYSQLCONF}.1

	LINES=`wc -l ${MYSQLCONF}.1|awk '{print $1}'`
	HEAD=`grep -n "\[mysqld\]" ${MYSQLCONF}.1|cut -d":" -f1`
	TAIL=$(($LINES-$HEAD))

	head -${HEAD} ${MYSQLCONF}.1 > $MYSQLCONF        
cat <<EOF >>$MYSQLCONF
# Globo.com custom config
datadir                         = /data/data/
tmpdir                          = /data/tmp/
innodb_max_dirty_pages_pct      = 90
EOF
	tail -${TAIL} ${MYSQLCONF}.1 >> $MYSQLCONF
	rm ${MYSQLCONF}.1
}
VAL=$((${GMEM}*1024/2))
sed -i "s/innodb_buffer_pool_size[^=]*= [0-9]*\(.*\)/innodb_buffer_pool_size\t\t= ${VAL}M/g" $MYSQLCONF
#### USERDATA
#### MysqlSVC
#### mariocar@corp.globo.com - 201208
####
if [ ${GMEM} -gt 0 ]; then
	config_my_cnf huge
else
	config_my_cnf large
fi
mkdir -p /data/{logs,tmp}
chown mysql /data/{logs,tmp}
mysql_install_db --user=mysql > /var/log/sysbench-oltp.log 2>&1
service mysqld start >> /var/log/sysbench-oltp.log 2>&1
cat<<EOF >/etc/collectd.conf
LoadPlugin syslog
LoadPlugin cpu
LoadPlugin disk
LoadPlugin interface
LoadPlugin load
LoadPlugin memory
LoadPlugin mysql
LoadPlugin network
LoadPlugin uptime
<Plugin disk>
	Disk "/^[vhs]d[a-f][0-9]?$/"
	IgnoreSelected false
</Plugin>
<Plugin mysql>
	<Database sbtest>
		User "sbtest"
		Password "sbtest"
		Socket "/var/lib/mysql/mysql.sock"
	</Database>
</Plugin>
<Plugin network>
	Server "collectd."
	TimeToLive 128
	CacheFlush 1800
</Plugin>
Include "/etc/collectd.d"
EOF
service collectd start

logger "Mysql Brain Fuck - Waiting for MySQL..."
while ! mysql mysql <<< "show databases;" > /dev/null 2>&1;do printf "." >> /var/log/sysbench-oltp.log ;sleep 5 ;done

logger "Mysql Brain Fuck - Creating Database (sbtest)..."
mysql <<< "drop database if exists sbtest;create database sbtest; grant all on sbtest.* to sbtest@'localhost' identified by 'sbtest'; grant all on sbtest.* to sbtest@'%' identified by 'sbtest';flush privileges;" >> /var/log/sysbench-oltp.log 2>&1
logger "Mysql Brain Fuck - Populating Database (sbtest)..."
sysbench --test=oltp --db-driver=mysql --mysql-password=sbtest --oltp-table-size=2000000 prepare >> /var/log/sysbench-oltp.log 2>&1
logger "Mysql Brain Fuck - Test beggining, stand by"
sysbench --test=oltp --num-threads=4 --db-driver=mysql --mysql-host=localhost.localdomain --mysql-password=sbtest --oltp-point-selects=500 run >> /var/log/sysbench-oltp.log  2>&1
logger "Mysql Brain Fuck - Test finished"
