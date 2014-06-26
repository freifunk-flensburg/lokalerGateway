#!/bin/sh

###
# gateway creator v0.1
# by wiflix
# and forked by Wlanfr3ak for Client Direct connect
# Original: https://gist.github.com/foertel/ca97482119e1197bef7c
#
# this script will turn your ubuntu 14.04 minimal box into a working internet-to-freifunk-flensburg Server
# just run as root, add your VPN credentials and reboot!
###

echo 'Welcome to Client Creator

Please tell me some stuff about your Client.

IP (the Registered LAN IP from the wiki): '
read lan_ip

echo 'MAC of mash vpn (from wiki): '
read vpn_mac

# ubuntu / repair some out-of-the-box-fuckup
locale-gen en_US en_US.UTF-8 de_DE.UTF-8
dpkg-reconfigure locales

# batctl / install batctl from external apt-repository
echo "deb http://repo.universe-factory.net/debian/ sid main" > /etc/apt/sources.list.d/fastd.list
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 16EF3F64CB201D9C
apt-get update
apt-get install -y batctl git fastd isc-dhcp-server radvd openvpn iptables-persistent dnsmasq build-essential

# install new (old) kernel
# ubuntu 14.04 shipps 3.13 which shipps batman-adv 2014.0 gluon only supports batman-adv 2013.4 at the moment, so we have to downgrade to an older kernel which shipps it.

cd /tmp
wget http://kernel.ubuntu.com/~kernel-ppa/mainline/v3.12.6-trusty/linux-image-3.12.6-031206-generic_3.12.6-031206.201312201218_amd64.deb
dpkg --install linux-image*.deb

 # make new kernel default to boot
echo 'GRUB_DEFAULT="1>2"' >> /etc/default/grub
update-grub

# import peers
git clone https://github.com/freifunk-flensburg/fffl-fastd-peers.git /etc/fastd/vpn/peers

# iptables - everything routed through the external vpn has to be masqueraded (NAT)
tee /etc/iptables/rules.v4 <<DELIM
*nat
:PREROUTING ACCEPT [15:1459]
:INPUT ACCEPT [2:88]
:OUTPUT ACCEPT [1:74]
:POSTROUTING ACCEPT [1:74]
-A POSTROUTING -o eth1 -j MASQUERADE
COMMIT
DELIM

# routing - send all packages from bat0 (mesh vpn) through external vpn
tee /etc/rc.local <<DELIM
ip rule add from all iif bat0 table 42
ip route add unreachable default table 42
ip route add 10.129.0.0/16 dev bat0 table 42
exit 0
DELIM

###
# network device
#
# batman-adv will manage bat0. when the device is brought up
# it will include the mesh vpn (vpn-fffl) into the routing.
###
tee -a /etc/network/interfaces <<DELIM

allow-hotplug bat0
iface bat0 inet manual
 pre-up modprobe batman-adv
 pre-up batctl if add vpn-fffl
 pre-up batctl gw server 100mbit/100mbit
 up ip addr add $lan_ip/16 broadcast 10.192.255.255 dev bat0
 up ip link set up dev bat0
 post-up batctl it 10000
 down ip link set down dev bat0
DELIM

# set up fffl mesh vpn
mkdir -p /etc/fastd/vpn/
cd /etc/fastd/vpn/
tee fastd.conf <<DELIM
log to syslog level warn;
interface "vpn-fffl";
method "salsa2012+gmac"; # new method, between gateways for the moment (faster)
bind 0.0.0.0:10000;
hide ip addresses yes;
hide mac addresses yes;
include "secret.conf";
mtu 1426;
include peers from "peers";
on up "
 ifup bat0 --force
 ip link set address $vpn_mac up dev \$INTERFACE
";
DELIM

echo 'Nun werden fastd Keys generiert'
fastd --generate-key >> /etc/fastd/vpn/secret.conf
echo 'Nun bitte den Secret Key kopieren (UMSCH+STRG+C):'
echo /etc/fastd/vpn/secret.conf
echo 'Bitte Secret kopieren, einfügen dann mit Enter bestätigen!'
read vpn_secret
echo 'Wenn euer Publickey und euer Host nicht im Peering der Clients ist wird es nicht klappen !'
echo 'secret "'$vpn_secret'";' > secret.conf

# external vpn
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
rm -rf /etc/sysctl.d/99-hetzner.conf

# when the vpn comes up, we set an outbound route to our table 42
tee /etc/openvpn/mullvad-up <<DELIM
#!/bin/sh
ip route replace default via \$5 table 42
exit 0
DELIM
chmod u+x /etc/fastd/fastd/vpn/fastd-up
 
# when the vpn goes down, we remove our outbound route, so no mesh vpn traffic
# will leaver our gateway through eth0.
tee /etc/openvpn/mullvad-down <<DELIM
#!/bin/sh
ip route replace unreachable default table 42
exit 0
DELIM
chmod u+x /etc/fastd/fastd/vpn/fastd-down

# autostart on boot
update-rc.d openvpn defaults
update-rc.d iptables-persistent defaults
