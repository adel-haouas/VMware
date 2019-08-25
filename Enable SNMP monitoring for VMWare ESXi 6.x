esxcli system snmp set --communities COMMUNITY_NAME
esxcli system snmp set --enable true

# Restrict access to a range of IPs or a particular host
esxcli network firewall ruleset set --ruleset-id snmp --allowed-all false
esxcli network firewall ruleset allowedip add --ruleset-id snmp --ip-address 192.168.0.0/24

# Allow access from any ip address
esxcli network firewall ruleset set --ruleset-id snmp --allowed-all true

#Enable snmpd in the firewall & restart the service
esxcli network firewall ruleset set --ruleset-id snmp --enabled true
/etc/init.d/snmpd restart

##Source: https://tylermade.net/2017/04/28/how-to-enable-snmp-monitoring-for-vmware-esxi-6-06-5/
