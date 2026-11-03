##############################################################################
# $Id: 98_GOVEE.pm v1.0.7 2026-11-03 $
#
# 98_GOVEE.pm - Govee-Lampen direkt in FHEM, LAN zuerst
#
# Ein Geraet "BRIDGE" haelt den UDP-Port 4002 und spricht fuer alle Lampen,
# weil die Antworten aller Lampen an denselben Port gehen und jeder Port nur
# einmal belegt werden kann.
#
# Wege, in dieser Reihenfolge:
#   LAN    Schalten, Helligkeit, Farbe, Status und Szenen der Typen 0 und 2
#          (UDP 4001-4003)
#   Cloud  Govee Developer API fuer Szenen vom Typ 5, fuer DIY-Szenen und fuer
#          Lampen, die per LAN nicht antworten. Braucht einen API-Key.
#
# Die Lampen melden Aenderungen nicht von sich aus, das LAN-Protokoll kennt
# nur Anfrage und Antwort. Deshalb fragt die Bridge alle <lanInterval> Sekunden.
#
# Szenen stammen aus der Szenenbibliothek der Govee-App. Sie ist nicht
# dokumentiert, aber ohne Anmeldung abrufbar. Eine Kopie je Modell liegt im
# Log-Verzeichnis, damit die Auswahl auch ohne Internet vollstaendig bleibt.
#
# Autor:  TechTobi83
# Dank:   Paketaufbau der Szenen nach govee2mqtt von Wez Furlong
#         (https://github.com/wez/govee2mqtt, MIT-Lizenz).
# Govee ist eine Marke der Shenzhen Intellirocks Tech. Co., Ltd. Dieses Modul
# steht in keiner Verbindung zu Govee.
#
# This file is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 2 of the License, or (at your option)
# any later version. It is distributed WITHOUT ANY WARRANTY; see
# <https://www.gnu.org/licenses/> for details.
##############################################################################

package main;

use strict;
use warnings;
use HttpUtils;
use JSON;
use Color;
use SetExtensions;
use IO::Socket::INET;
use MIME::Base64;
use Socket qw(inet_aton pack_sockaddr_in sockaddr_in inet_ntoa SO_BROADCAST);

my $GOVEE_version = '1.0.7';

my $GOVEE_mcast    = '239.255.255.250';
my $GOVEE_portScan = 4001;
my $GOVEE_portRecv = 4002;
my $GOVEE_portCmd  = 4003;

# LAN-Status hinkt nach einem Befehl ein paar Sekunden hinterher, die Cloud noch mehr
my $GOVEE_holdLan   = 3;
my $GOVEE_holdCloud = 6;
my $GOVEE_lanMisses = 3;

my $GOVEE_scanRepeats = 4;
my $GOVEE_scanGap     = 2;

my $GOVEE_libUrl    = 'https://app2.govee.com/appsku/v1/light-effect-libraries?sku=';
my $GOVEE_libHeader = "AppVersion: 6.5.02\r\nUser-Agent: GoveeHome/6.5.02 (com.ihoment.GoVeeSensor; build:2; iOS 16.5.0) Alamofire/5.6.4";
my $GOVEE_libMaxAge = 86400;
my $GOVEE_libRetry  = 600;

our $GOVEE_cloudBase = 'https://openapi.api.govee.com/router/api/v1';
my $GOVEE_keyName    = 'GOVEE_apiKey';
my $GOVEE_selectKey  = 'GOVEE.udp';

sub GOVEE_Initialize {
  my ($hash) = @_;
  $hash->{DefFn}    = 'GOVEE_Define';
  $hash->{UndefFn}  = 'GOVEE_Undef';
  $hash->{DeleteFn} = 'GOVEE_Delete';
  $hash->{SetFn}    = 'GOVEE_Set';
  $hash->{AttrFn}   = 'GOVEE_Attr';
  $hash->{ReadFn}   = 'GOVEE_Read';
  $hash->{AttrList} = 'disable:0,1 lanInterval scanInterval scanTargets sendGap cloudInterval '
                    . 'lanIP sceneFilter sceneRoute:auto,lan,cloud ' . $readingFnAttributes;
  # Nur die Zeitfunktionen: SetExtensions haengt sonst attrTemplate an, fuer GOVEE gibt es keine Vorlagen
  $hash->{SetExtensionsFn} = ['DoSetExtensions'];
  $hash->{seInitDone}      = 1;
  return;
}

sub GOVEE_Define {
  my ($hash, $def) = @_;
  my @a = split('[ \t]+', $def);
  return 'Syntax: define <name> GOVEE BRIDGE | define <name> GOVEE <Geraete-ID> [<Modell>]'
    if (@a < 3 || @a > 4);

  my $name = $a[0];
  $hash->{VERSION} = $GOVEE_version;

  if (uc($a[2]) eq 'BRIDGE') {
    my $other = GOVEE_Bridge();
    return "Es gibt schon eine Bridge: $other->{NAME}" if ($other && $other != $hash);
    $modules{GOVEE}{bridge} = $hash;
    $hash->{ROLE} = 'BRIDGE';
    GOVEE_CloseSocket($hash);
    GOVEE_OpenSocket($hash);
    RemoveInternalTimer($hash, 'GOVEE_BridgeTimer');
    InternalTimer(gettimeofday() + ($init_done ? 1 : 10), 'GOVEE_BridgeTimer', $hash);
    return;
  }

  (my $id = uc($a[2])) =~ s/://g;
  return 'Die Geraete-ID hat 16 Hex-Zeichen, zum Beispiel AA:BB:CC:DD:EE:FF:00:11'
    if ($id !~ /^[0-9A-F]{16}$/);
  my $other = $modules{GOVEE}{defptr}{$id};
  return "Diese Lampe gibt es schon: $other->{NAME}" if ($other && $other != $hash);

  delete $modules{GOVEE}{defptr}{$hash->{ID}} if ($hash->{ID});
  $hash->{ROLE} = 'LAMP';
  $hash->{ID}   = $id;
  $hash->{SKU}  = uc($a[3]) if ($a[3]);
  $modules{GOVEE}{defptr}{$id} = $hash;
  delete $hash->{helper}{setlist};
  return;
}

sub GOVEE_Undef {
  my ($hash) = @_;
  RemoveInternalTimer($hash);
  if (GOVEE_IsBridge($hash)) {
    GOVEE_CloseSocket($hash);
    delete $modules{GOVEE}{bridge};
  } else {
    delete $modules{GOVEE}{defptr}{$hash->{ID}} if ($hash->{ID});
  }
  return;
}

sub GOVEE_Delete {
  my ($hash) = @_;
  setKeyValue($GOVEE_keyName, undef) if (GOVEE_IsBridge($hash));
  return;
}

sub GOVEE_Attr {
  my ($cmd, $name, $attr, $val) = @_;
  my $hash = $defs{$name};
  if ($cmd eq 'set') {
    return 'lanInterval muss eine Zahl >= 5 (Sekunden) sein'
      if ($attr eq 'lanInterval' && ($val !~ /^\d+$/ || $val < 5));
    return 'scanInterval muss eine Zahl >= 60 (Sekunden) sein'
      if ($attr eq 'scanInterval' && ($val !~ /^\d+$/ || $val < 60));
    return 'cloudInterval muss 0 (aus) oder eine Zahl >= 60 (Sekunden) sein'
      if ($attr eq 'cloudInterval' && ($val !~ /^\d+$/ || ($val != 0 && $val < 60)));
    return 'sendGap muss zwischen 0 und 2 (Sekunden) liegen'
      if ($attr eq 'sendGap' && ($val !~ /^\d*\.?\d+$/ || $val > 2));
    return 'lanIP muss eine IPv4-Adresse sein'
      if ($attr eq 'lanIP' && $val !~ /^\d+\.\d+\.\d+\.\d+$/);
    if ($attr eq 'sceneFilter') {
      eval { qr/$val/ };
      return "sceneFilter ist kein gueltiger regulaerer Ausdruck: $@" if ($@);
    }
  }
  if ($attr eq 'sceneFilter') {
    delete $hash->{helper}{setlist};
  }
  if ($attr eq 'lanIP') {
    my $bridge = GOVEE_Bridge();
    if ($bridge) {
      delete $bridge->{helper}{byIp}{$hash->{IP}} if ($hash->{IP});
      $bridge->{helper}{byIp}{$val} = $name if ($cmd eq 'set');
    }
    $hash->{IP} = $val if ($cmd eq 'set');
    delete $hash->{IP} if ($cmd eq 'del');
  }
  return;
}

########################################
# Kleine Helfer

sub GOVEE_IsBridge {
  my ($hash) = @_;
  return ($hash->{ROLE} // '') eq 'BRIDGE';
}

# Der Verweis ueberlebt kein reload, FHEM behaelt nur defptr und ldata
sub GOVEE_Bridge {
  return $modules{GOVEE}{bridge} if ($modules{GOVEE}{bridge});
  my ($bridge) = grep { ($_->{TYPE} // '') eq 'GOVEE' && GOVEE_IsBridge($_) } values %defs;
  $modules{GOVEE}{bridge} = $bridge if ($bridge);
  return $bridge;
}

sub GOVEE_Lamps {
  return grep { !IsDisabled($_->{NAME}) } values %{ $modules{GOVEE}{defptr} // {} };
}

sub GOVEE_Sku {
  my ($hash) = @_;
  return $hash->{SKU} // ReadingsVal($hash->{NAME}, 'sku', undef);
}

sub GOVEE_CloudId {
  my ($hash) = @_;
  return join(':', $hash->{ID} =~ /(..)/g);
}

sub GOVEE_ClearSetlists {
  my ($sku) = @_;
  for my $lamp (values %{ $modules{GOVEE}{defptr} // {} }) {
    delete $lamp->{helper}{setlist} if (!$sku || (GOVEE_Sku($lamp) // '') eq $sku);
  }
  return;
}

########################################
# Zugangsschluessel verschleiert im FHEM-Schluesselspeicher (nicht in fhem.cfg)

sub GOVEE_SetApiKey {
  my ($value) = @_;
  my $key = getUniqueId() . 'GOVEE';
  my $enc = '';
  for my $char (split //, $value) {
    my $encode = chop($key);
    $enc .= sprintf('%.2x', ord($char) ^ ord($encode));
    $key = $encode . $key;
  }
  return setKeyValue($GOVEE_keyName, $enc);
}

sub GOVEE_ApiKey {
  my ($err, $enc) = getKeyValue($GOVEE_keyName);
  return if ($err || !defined($enc) || $enc eq '');
  my $key = getUniqueId() . 'GOVEE';
  my $dec = '';
  for my $char (map { pack('C', hex($_)) } ($enc =~ /(..)/g)) {
    my $decode = chop($key);
    $dec .= chr(ord($char) ^ ord($decode));
    $key = $decode . $key;
  }
  return $dec;
}

########################################
# Socket

sub GOVEE_OpenSocket {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $sock = IO::Socket::INET->new(Proto => 'udp', LocalPort => $GOVEE_portRecv);
  if (!$sock) {
    readingsSingleUpdate($hash, 'state', "Port $GOVEE_portRecv belegt", 1);
    Log3($name, 2, "$name: UDP-Port $GOVEE_portRecv nicht verfuegbar: $!");
    return 0;
  }
  $sock->blocking(0);
  $sock->sockopt(SO_BROADCAST, 1);
  $hash->{helper}{sock} = $sock;
  $hash->{FD} = $sock->fileno();
  $selectlist{$GOVEE_selectKey} = $hash;
  readingsSingleUpdate($hash, 'state', 'bereit', 1);
  return 1;
}

sub GOVEE_CloseSocket {
  my ($hash) = @_;
  delete $selectlist{$GOVEE_selectKey};
  delete $hash->{FD};
  my $sock = delete $hash->{helper}{sock};
  close($sock) if ($sock);
  return;
}

sub GOVEE_Send {
  my ($hash, $ip, $port, $msg) = @_;
  my $sock = $hash->{helper}{sock};
  return if (!$sock);
  my $addr = inet_aton($ip);
  return if (!$addr);
  my $text = encode_json({ msg => $msg });
  Log3($hash->{NAME}, 5, "$hash->{NAME}: an $ip:$port $text");
  my $ok = send($sock, $text, 0, pack_sockaddr_in($port, $addr));
  Log3($hash->{NAME}, 4, "$hash->{NAME}: Senden an $ip fehlgeschlagen: $!") if (!defined $ok);
  return;
}

########################################
# Takt der Bridge

sub GOVEE_BridgeTimer {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  RemoveInternalTimer($hash, 'GOVEE_BridgeTimer');
  InternalTimer(gettimeofday() + AttrVal($name, 'lanInterval', 30), 'GOVEE_BridgeTimer', $hash);
  return if (IsDisabled($name));

  GOVEE_OpenSocket($hash) if (!$hash->{helper}{sock});
  my $now = gettimeofday();

  if (!$hash->{helper}{started}) {
    $hash->{helper}{started} = 1;
    GOVEE_RestoreLamps($hash);
    readingsSingleUpdate($hash, 'apiKey', GOVEE_ApiKey() ? 'gesetzt' : 'fehlt', 0);
    GOVEE_CloudDevices($hash, 0) if (GOVEE_ApiKey());
  }

  if ($now - ($hash->{helper}{lastScan} // 0) >= AttrVal($name, 'scanInterval', 300)) {
    GOVEE_Scan($hash);
  }
  for my $lamp (GOVEE_Lamps()) {
    GOVEE_LampPoll($hash, $lamp);
    my $sku = GOVEE_Sku($lamp);
    GOVEE_LibEnsure($hash, $sku);
    my $lib = $sku ? $modules{GOVEE}{lib}{$sku} : undef;
    readingsSingleUpdate($lamp, 'scenes', scalar(@{ $lib->{scenes} }), 0)
      if ($lib && ReadingsVal($lamp->{NAME}, 'scenes', 0) != @{ $lib->{scenes} });
    GOVEE_UpdateSceneList($lamp);
  }
  GOVEE_CloudCycle($hash, $now);
  return;
}

sub GOVEE_RestoreLamps {
  my ($hash) = @_;
  for my $lamp (values %{ $modules{GOVEE}{defptr} // {} }) {
    my $ip = AttrVal($lamp->{NAME}, 'lanIP', ReadingsVal($lamp->{NAME}, 'ip', undef));
    next if (!$ip);
    $lamp->{IP} = $ip;
    $hash->{helper}{byIp}{$ip} = $lamp->{NAME};
  }
  return;
}

# Multicast geht im WLAN leicht verloren, deshalb mehrere Versuche
sub GOVEE_Scan {
  my ($hash) = @_;
  $hash->{helper}{lastScan} = gettimeofday();
  $hash->{helper}{scanLeft} = $GOVEE_scanRepeats;
  RemoveInternalTimer($hash, 'GOVEE_ScanSend');
  GOVEE_ScanSend($hash);
  return;
}

sub GOVEE_ScanSend {
  my ($hash) = @_;
  InternalTimer(gettimeofday() + $GOVEE_scanGap, 'GOVEE_ScanSend', $hash)
    if (--$hash->{helper}{scanLeft} > 0);
  my $msg = { cmd => 'scan', data => { account_topic => 'reserve' } };
  GOVEE_Send($hash, $GOVEE_mcast, $GOVEE_portScan, $msg);
  for my $target (split(/[ ,]+/, AttrVal($hash->{NAME}, 'scanTargets', ''))) {
    GOVEE_Send($hash, $target, $GOVEE_portScan, $msg);
  }
  for my $lamp (GOVEE_Lamps()) {
    my $ip = AttrVal($lamp->{NAME}, 'lanIP', undef);
    GOVEE_Send($hash, $ip, $GOVEE_portScan, $msg) if ($ip);
  }
  return;
}

sub GOVEE_LampPoll {
  my ($bridge, $lamp) = @_;
  if ($lamp->{IP}) {
    if (++$lamp->{helper}{missed} > $GOVEE_lanMisses) {
      $lamp->{helper}{lanOk} = 0;
    }
    GOVEE_Send($bridge, $lamp->{IP}, $GOVEE_portCmd, { cmd => 'devStatus', data => {} });
    # Nur die Suche nennt das Modell, das braucht die Szenenliste
    GOVEE_Send($bridge, $lamp->{IP}, $GOVEE_portScan, { cmd => 'scan', data => { account_topic => 'reserve' } })
      if (!GOVEE_Sku($lamp));
  }
  GOVEE_Connection($lamp);
  return;
}

sub GOVEE_Connection {
  my ($hash) = @_;
  my $conn = $hash->{helper}{lanOk}     ? 'lan'
           : $hash->{helper}{cloudOk}   ? 'cloud'
           :                              'offline';
  readingsBeginUpdate($hash);
  readingsBulkUpdateIfChanged($hash, 'connection', $conn);
  readingsBulkUpdateIfChanged($hash, 'state',
    $conn eq 'offline' ? 'offline' : lc(ReadingsVal($hash->{NAME}, 'powerSwitch', 'off')));
  readingsEndUpdate($hash, 1);
  return;
}

########################################
# Eingehende Pakete

sub GOVEE_Read {
  my ($hash) = @_;
  my $sock = $hash->{helper}{sock};
  return if (!$sock);
  my $buf  = '';
  my $from = recv($sock, $buf, 4096, 0);
  return if (!$from || !length($buf));
  my (undef, $addr) = sockaddr_in($from);
  my $ip = inet_ntoa($addr);
  Log3($hash->{NAME}, 5, "$hash->{NAME}: von $ip $buf");

  my $json = eval { decode_json($buf) };
  return if (ref($json) ne 'HASH' || ref($json->{msg}) ne 'HASH');
  my ($cmd, $data) = ($json->{msg}{cmd} // '', $json->{msg}{data});
  return if (ref($data) ne 'HASH');

  return GOVEE_ParseScan($hash, $ip, $data) if ($cmd eq 'scan');
  return GOVEE_ParseStatus($hash, $ip, $data) if ($cmd eq 'devStatus');
  return;
}

sub GOVEE_ParseScan {
  my ($hash, $peer, $data) = @_;
  (my $id = uc($data->{device} // '')) =~ s/://g;
  return if ($id !~ /^[0-9A-F]{16}$/);
  my $ip  = $data->{ip} && $data->{ip} ne '0.0.0.0' ? $data->{ip} : $peer;
  my $sku = $data->{sku} // '';

  $hash->{helper}{found}{$id} = "$sku $id $ip";
  readingsSingleUpdate($hash, 'discovered',
    join(', ', map { $hash->{helper}{found}{$_} } sort keys %{ $hash->{helper}{found} }), 0);

  my $lamp = $modules{GOVEE}{defptr}{$id};
  if (!$lamp) {
    GOVEE_Autocreate($hash, $id, $sku) if (($hash->{helper}{manualUntil} // 0) > gettimeofday());
    $lamp = $modules{GOVEE}{defptr}{$id};
    return if (!$lamp);
  }

  my $static = AttrVal($lamp->{NAME}, 'lanIP', undef);
  $ip = $static if ($static);
  if (($lamp->{IP} // '') ne $ip) {
    delete $hash->{helper}{byIp}{ $lamp->{IP} } if ($lamp->{IP});
    $lamp->{IP} = $ip;
  }
  $hash->{helper}{byIp}{$ip} = $lamp->{NAME};
  GOVEE_LanAlive($lamp);

  readingsBeginUpdate($lamp);
  readingsBulkUpdateIfChanged($lamp, 'ip', $ip);
  readingsBulkUpdateIfChanged($lamp, 'sku', $sku) if ($sku);
  readingsBulkUpdateIfChanged($lamp, 'wifiVersion', $data->{wifiVersionSoft}) if ($data->{wifiVersionSoft});
  readingsBulkUpdateIfChanged($lamp, 'bleVersion', $data->{bleVersionSoft}) if ($data->{bleVersionSoft});
  readingsEndUpdate($lamp, 0);
  GOVEE_ClearSetlists($sku) if ($sku);
  return;
}

sub GOVEE_Autocreate {
  my ($hash, $id, $sku) = @_;
  my $name = 'GOVEE_' . ($sku || 'Lampe') . '_' . substr($id, -6);
  my $err  = CommandDefine(undef, "$name GOVEE $id $sku");
  if ($err) {
    Log3($hash->{NAME}, 2, "$hash->{NAME}: $name nicht angelegt: $err");
    return;
  }
  CommandAttr(undef, "$name room " . AttrVal($hash->{NAME}, 'room', 'Govee'));
  CommandAttr(undef, "$name icon light_led_stripe_rgb");
  return;
}

sub GOVEE_LanAlive {
  my ($lamp) = @_;
  $lamp->{helper}{missed} = 0;
  my $was = $lamp->{helper}{lanOk};
  $lamp->{helper}{lanOk} = 1;
  return if ($was);
  GOVEE_Connection($lamp);
  GOVEE_StatusNow($lamp);
  return;
}

sub GOVEE_ParseStatus {
  my ($hash, $ip, $data) = @_;
  my $name = $hash->{helper}{byIp}{$ip};
  my $lamp = $name ? $defs{$name} : undef;
  return if (!$lamp);
  GOVEE_LanAlive($lamp);
  return if (gettimeofday() < ($lamp->{helper}{holdUntil} // 0));

  my $color = ref($data->{color}) eq 'HASH' ? $data->{color} : {};
  GOVEE_Apply($lamp, {
    on         => $data->{onOff},
    brightness => $data->{brightness},
    r          => $color->{r},
    g          => $color->{g},
    b          => $color->{b},
    kelvin     => $data->{colorTemInKelvin},
  });
  return;
}

# Schreibt nur Aenderungen, damit der Abfragetakt keine Events erzeugt
sub GOVEE_Apply {
  my ($hash, $s) = @_;
  my $name = $hash->{NAME};
  readingsBeginUpdate($hash);
  if (defined $s->{on}) {
    my $on = $s->{on} ? 'ON' : 'OFF';
    readingsBulkUpdateIfChanged($hash, 'powerSwitch', $on);
    readingsBulkUpdateIfChanged($hash, 'state', lc($on)) if (ReadingsVal($name, 'connection', '') ne 'offline');
  }
  readingsBulkUpdateIfChanged($hash, 'brightness', $s->{brightness}) if (defined $s->{brightness});
  if (defined $s->{r} && defined $s->{g} && defined $s->{b}) {
    readingsBulkUpdateIfChanged($hash, 'color_r', $s->{r});
    readingsBulkUpdateIfChanged($hash, 'color_g', $s->{g});
    readingsBulkUpdateIfChanged($hash, 'color_b', $s->{b});
    readingsBulkUpdateIfChanged($hash, 'rgb', sprintf('%02X%02X%02X', $s->{r}, $s->{g}, $s->{b}));
  }
  if (defined $s->{kelvin}) {
    readingsBulkUpdateIfChanged($hash, 'color_mode', $s->{kelvin} > 0 ? 'color_temp' : 'rgb');
    if ($s->{kelvin} > 0) {
      readingsBulkUpdateIfChanged($hash, 'color_kelvin', $s->{kelvin});
      readingsBulkUpdateIfChanged($hash, 'color_temp', int(1000000 / $s->{kelvin} + 0.5));
    }
  }
  readingsBulkUpdateIfChanged($hash, 'effect', $s->{effect}) if (defined $s->{effect});
  readingsEndUpdate($hash, 1);
  return;
}

########################################
# Set

sub GOVEE_Set {
  my ($hash, $name, $cmd, @args) = @_;
  return GOVEE_BridgeSet($hash, $name, $cmd, @args) if (GOVEE_IsBridge($hash));

  my $list = GOVEE_Setlist($hash);
  $cmd //= '?';

  if ($cmd eq 'on' || $cmd eq 'off') {
    return GOVEE_Power($hash, $cmd eq 'on' ? 1 : 0);
  }
  if ($cmd eq 'toggle') {
    return GOVEE_Power($hash, ReadingsVal($name, 'powerSwitch', 'OFF') eq 'ON' ? 0 : 1);
  }
  if ($cmd eq 'brightness') {
    my $val = $args[0] // '';
    return 'Syntax: set <name> brightness <0..100>' if ($val !~ /^\d+$/ || $val > 100);
    return GOVEE_Power($hash, 0) if ($val == 0);
    return GOVEE_Brightness($hash, $val);
  }
  if ($cmd eq 'rgb') {
    return 'Syntax: set <name> rgb <RRGGBB>' if (!@args);
    # Automatiken reichen gesicherte Werte oft verpackt oder leer durch, zum Beispiel
    # [FFDD80 replace('#','')]. Ein Fehler wuerde ihre restlichen Befehle abbrechen.
    (my $val = $args[0]) =~ s/[^0-9A-Fa-f]//g;
    if ($val eq '') {
      Log3($name, 3, "$name: rgb ohne Farbwert ignoriert: $args[0]");
      return;
    }
    return 'Syntax: set <name> rgb <RRGGBB>' if ($val !~ /^[0-9A-Fa-f]{6}$/);
    return GOVEE_Rgb($hash, $val);
  }
  if ($cmd eq 'hsv') {
    my $val = $args[0] // '';
    return 'Syntax: set <name> hsv <HHSSVV>' if ($val !~ /^([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})$/);
    my ($r, $g, $b) = Color::hsv2rgb(hex($1) / 255, hex($2) / 255, hex($3) / 255);
    return GOVEE_Rgb($hash, sprintf('%02X%02X%02X', $r * 255, $g * 255, $b * 255));
  }
  if ($cmd eq 'ct') {
    my $val = $args[0] // '';
    return 'Syntax: set <name> ct <Mired 100..999 oder Kelvin 1000..10000>'
      if ($val !~ /^\d+$/ || $val < 100 || $val > 10000);
    return GOVEE_Ct($hash, $val < 1000 ? int(1000000 / $val + 0.5) : $val);
  }
  if ($cmd eq 'effect' || $cmd eq 'effect_custom' || $cmd eq 'diy_scene') {
    my $val = join(' ', @args);
    $val =~ s/#/ /g;
    return "Syntax: set <name> $cmd <Szene>" if ($val eq '');
    return GOVEE_Scene($hash, $val, $cmd eq 'diy_scene');
  }
  if ($cmd eq 'updateScenes') {
    my $bridge = GOVEE_Bridge();
    return 'Keine Bridge definiert' if (!$bridge);
    my $sku = GOVEE_Sku($hash);
    return 'Modell noch unbekannt' if (!$sku);
    GOVEE_LibFetch($bridge, $sku);
    GOVEE_CloudScenes($bridge, $hash) if (GOVEE_ApiKey());
    return;
  }
  if ($cmd eq 'statusRequest') {
    my $bridge = GOVEE_Bridge();
    return 'Keine Bridge definiert' if (!$bridge);
    GOVEE_StatusNow($hash);
    return;
  }
  return SetExtensions($hash, $list, $name, $cmd, @args);
}

sub GOVEE_BridgeSet {
  my ($hash, $name, $cmd, @args) = @_;
  my $list = 'scan:noArg apiKey deleteApiKey:noArg';
  $cmd //= '?';
  if ($cmd eq 'scan') {
    $hash->{helper}{manualUntil} = gettimeofday() + 10;
    delete $hash->{helper}{found};
    GOVEE_Scan($hash);
    GOVEE_CloudDevices($hash, 1) if (GOVEE_ApiKey());
    return;
  }
  if ($cmd eq 'apiKey') {
    return 'Syntax: set <name> apiKey <Schluessel>' if (@args != 1);
    my $err = GOVEE_SetApiKey($args[0]);
    return "API-Key nicht gespeichert: $err" if ($err);
    delete $hash->{helper}{cloudBlockedUntil};
    readingsSingleUpdate($hash, 'apiKey', 'gesetzt', 1);
    GOVEE_CloudDevices($hash, 0);
    return;
  }
  if ($cmd eq 'deleteApiKey') {
    setKeyValue($GOVEE_keyName, undef);
    readingsSingleUpdate($hash, 'apiKey', 'fehlt', 1);
    return;
  }
  return "Unknown argument $cmd, choose one of $list";
}

sub GOVEE_SceneNames {
  my ($hash) = @_;
  my $filter = AttrVal($hash->{NAME}, 'sceneFilter', undef);
  my $sku    = GOVEE_Sku($hash);
  my $lib    = $sku ? $modules{GOVEE}{lib}{$sku} : undef;
  my @names;
  if ($lib) {
    @names = map { $_->{name} }
             grep { !defined($filter) || "$_->{cat}:$_->{name}" =~ /$filter/ } @{ $lib->{scenes} };
  } else {
    @names = sort keys %{ $hash->{helper}{cloudScenes} // {} };
  }
  my @diy = sort keys %{ $hash->{helper}{cloudDiy} // {} };
  return (\@names, \@diy);
}

# Fuer Oberflaechen wie FTUI, die eine Auswahl aus einem Reading fuellen
sub GOVEE_UpdateSceneList {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my ($names, $diy) = GOVEE_SceneNames($hash);
  my $plain = sub { return map { (my $n = $_) =~ s/,/ /g; $n } @_ };
  my $value = join(',', $plain->(@$names, @$diy));
  return if ($value eq '');

  # Welche davon ueber die Cloud gehen, damit eine Oberflaeche sie kennzeichnen kann
  my $sku  = GOVEE_Sku($hash);
  my $lib  = $sku ? $modules{GOVEE}{lib}{$sku} : undef;
  my $key  = GOVEE_ApiKey();
  my @viaCloud = grep {
    my $scene = $lib ? $lib->{lookup}{ lc($_) } : undef;
    $scene ? GOVEE_SceneViaCloud($hash, $scene) : $key;
  } @$names;
  push @viaCloud, @$diy if ($key);
  my $cloud = join(',', $plain->(@viaCloud));

  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, 'sceneList', $value) if ($value ne ReadingsVal($name, 'sceneList', ''));
  readingsBulkUpdate($hash, 'sceneListCloud', $cloud) if ($cloud ne ReadingsVal($name, 'sceneListCloud', "\0"));
  readingsEndUpdate($hash, 1);
  return;
}

# Gleiche Entscheidung wie beim Senden: Typ 5 ueber die Cloud, sofern Schluessel und
# Cloud-Eintrag vorhanden sind; sceneRoute lan oder cloud legt den Weg fest
sub GOVEE_SceneViaCloud {
  my ($hash, $scene) = @_;
  my $mode = AttrVal($hash->{NAME}, 'sceneRoute', 'auto');
  return 0 if ($mode eq 'lan' || !GOVEE_ApiKey());
  my $key = lc($scene->{name});
  return 0 if (!grep { lc($_) eq $key } keys %{ $hash->{helper}{cloudScenes} // {} });
  return 1 if ($mode eq 'cloud' || !defined($scene->{type}) || $scene->{type} == 5);
  return 0;
}

sub GOVEE_Setlist {
  my ($hash) = @_;
  return $hash->{helper}{setlist} if ($hash->{helper}{setlist});

  my ($names, $diy) = GOVEE_SceneNames($hash);
  my @names = @$names;
  my @diy   = @$diy;

  my $select = sub { return join(',', map { (my $n = $_) =~ s/,/ /g; $n =~ s/ +/#/g; $n } @_) };
  my $list = 'on:noArg off:noArg toggle:noArg brightness:slider,0,1,100 rgb:colorpicker,RGB '
           . 'hsv:colorpicker,HSV ct:colorpicker,CT,153,1,370 '
           . 'effect_custom:textField updateScenes:noArg statusRequest:noArg';
  $list .= ' effect:select,' . $select->(@names, @diy) if (@names || @diy);
  $list .= ' effect:textField' if (!@names && !@diy);
  $list .= ' diy_scene:select,' . $select->(@diy) if (@diy);
  $list .= ' diy_scene:textField' if (!@diy);
  $hash->{helper}{setlist} = $list;
  return $list;
}

# LAN, wenn die Lampe antwortet. Cloud nur als Rueckfall. Ohne Cloud trotzdem LAN,
# denn UDP kostet nichts und die Lampe kann gerade wieder da sein.
sub GOVEE_Route {
  my ($hash) = @_;
  return if (!GOVEE_Bridge());
  return 'lan' if ($hash->{IP} && $hash->{helper}{lanOk});
  return 'cloud' if (GOVEE_ApiKey() && GOVEE_Sku($hash));
  return 'lan' if ($hash->{IP});
  return;
}

sub GOVEE_NoRoute {
  my ($hash) = @_;
  return "$hash->{NAME}: keine Bridge definiert" if (!GOVEE_Bridge());
  return "$hash->{NAME}: per LAN nicht gefunden und kein API-Key in der Bridge";
}

sub GOVEE_Hold {
  my ($hash, $route) = @_;
  my $hold = $route eq 'lan' ? $GOVEE_holdLan : $GOVEE_holdCloud;
  $hash->{helper}{holdUntil} = gettimeofday() + $hold;
  RemoveInternalTimer($hash, 'GOVEE_ConfirmTimer');
  InternalTimer(gettimeofday() + $hold + 0.5, 'GOVEE_ConfirmTimer', $hash);
  return;
}

sub GOVEE_ConfirmTimer {
  my ($hash) = @_;
  GOVEE_StatusNow($hash);
  return;
}

sub GOVEE_StatusNow {
  my ($hash) = @_;
  my $bridge = GOVEE_Bridge();
  return if (!$bridge);
  if ($hash->{IP} && $hash->{helper}{lanOk}) {
    GOVEE_Send($bridge, $hash->{IP}, $GOVEE_portCmd, { cmd => 'devStatus', data => {} });
  } elsif (GOVEE_ApiKey() && GOVEE_Sku($hash)) {
    GOVEE_CloudStatus($bridge, $hash);
  }
  return;
}

sub GOVEE_Power {
  my ($hash, $on) = @_;
  my $route = GOVEE_Route($hash) // return GOVEE_NoRoute($hash);
  if ($route eq 'lan') {
    GOVEE_LanQueue($hash, 'turn', { value => $on });
  } else {
    GOVEE_CloudControl($hash, 'devices.capabilities.on_off', 'powerSwitch', $on);
  }
  GOVEE_Hold($hash, $route);
  GOVEE_Apply($hash, { on => $on });
  return;
}

# Helligkeit und Farbe schalten die Lampe wie bisher mit ein
sub GOVEE_EnsureOn {
  my ($hash) = @_;
  return if (ReadingsVal($hash->{NAME}, 'powerSwitch', 'OFF') eq 'ON');
  GOVEE_Power($hash, 1);
  return;
}

sub GOVEE_Brightness {
  my ($hash, $val) = @_;
  my $route = GOVEE_Route($hash) // return GOVEE_NoRoute($hash);
  GOVEE_EnsureOn($hash);
  if ($route eq 'lan') {
    GOVEE_LanQueue($hash, 'brightness', { value => int($val) });
  } else {
    GOVEE_CloudControl($hash, 'devices.capabilities.range', 'brightness', int($val));
  }
  GOVEE_Hold($hash, $route);
  GOVEE_Apply($hash, { brightness => int($val) });
  return;
}

sub GOVEE_Rgb {
  my ($hash, $hex) = @_;
  my $route = GOVEE_Route($hash) // return GOVEE_NoRoute($hash);
  my ($r, $g, $b) = map { hex($_) } ($hex =~ /(..)(..)(..)/);
  GOVEE_EnsureOn($hash);
  if ($route eq 'lan') {
    GOVEE_LanQueue($hash, 'colorwc', { color => { r => $r, g => $g, b => $b }, colorTemInKelvin => 0 });
  } else {
    GOVEE_CloudControl($hash, 'devices.capabilities.color_setting', 'colorRgb', ($r << 16) | ($g << 8) | $b);
  }
  GOVEE_Hold($hash, $route);
  GOVEE_Apply($hash, { r => $r, g => $g, b => $b, kelvin => 0, effect => '' });
  return;
}

sub GOVEE_Ct {
  my ($hash, $kelvin) = @_;
  my $route = GOVEE_Route($hash) // return GOVEE_NoRoute($hash);
  GOVEE_EnsureOn($hash);
  if ($route eq 'lan') {
    GOVEE_LanQueue($hash, 'colorwc', { color => { r => 0, g => 0, b => 0 }, colorTemInKelvin => int($kelvin) });
  } else {
    GOVEE_CloudControl($hash, 'devices.capabilities.color_setting', 'colorTemperatureK', int($kelvin));
  }
  GOVEE_Hold($hash, $route);
  GOVEE_Apply($hash, { kelvin => int($kelvin), effect => '' });
  return;
}

sub GOVEE_Scene {
  my ($hash, $want, $diyOnly) = @_;
  my $route = GOVEE_Route($hash) // return GOVEE_NoRoute($hash);
  my $key   = lc($want);
  my $sku   = GOVEE_Sku($hash);
  GOVEE_LibEnsure(GOVEE_Bridge(), $sku) if ($sku && !$modules{GOVEE}{lib}{$sku});
  my $lib   = $sku ? $modules{GOVEE}{lib}{$sku} : undef;

  my $diy;
  for my $n (keys %{ $hash->{helper}{cloudDiy} // {} }) {
    $diy = $hash->{helper}{cloudDiy}{$n} if (lc($n) eq $key);
  }
  my $scene = !$diyOnly && $lib ? $lib->{lookup}{$key} : undef;

  my $cloudName;
  if (!$diyOnly) {
    ($cloudName) = grep { lc($_) eq $key } keys %{ $hash->{helper}{cloudScenes} // {} };
  }

  # Das LAN-Paket ist nur fuer Szenen vom Typ 0 und 2 entschluesselt. Typ 5 kodiert
  # die Parameter anders, ein H61D5 kehrte danach zur letzten DIY-Szene zurueck.
  # Ohne gespeicherten Typ (alte Szenenkopie) ist die Cloud der sichere Weg.
  my $preferCloud = defined($cloudName)
                  && ($scene ? GOVEE_SceneViaCloud($hash, $scene)
                             : GOVEE_ApiKey() && AttrVal($hash->{NAME}, 'sceneRoute', 'auto') ne 'lan');

  if ($scene && $route eq 'lan' && !$preferCloud) {
    GOVEE_EnsureOn($hash);
    GOVEE_LanQueue($hash, 'ptReal', { command => [ GOVEE_SceneFrames($scene->{code}, $scene->{param}) ] });
    GOVEE_Hold($hash, 'lan');
    GOVEE_Apply($hash, { effect => $scene->{name} });
    return;
  }
  if (defined $diy) {
    return 'DIY-Szenen laufen ueber die Cloud, dafuer fehlt der API-Key' if (!GOVEE_ApiKey());
    GOVEE_CloudControl($hash, 'devices.capabilities.dynamic_scene', 'diyScene', $diy);
    GOVEE_Hold($hash, 'cloud');
    GOVEE_Apply($hash, { on => 1, effect => $want });
    return;
  }
  if (defined $cloudName) {
    GOVEE_CloudControl($hash, 'devices.capabilities.dynamic_scene', 'lightScene', $hash->{helper}{cloudScenes}{$cloudName});
    GOVEE_Hold($hash, 'cloud');
    GOVEE_Apply($hash, { on => 1, effect => $cloudName });
    return;
  }
  return 'DIY-Szenen laufen ueber die Cloud, dafuer fehlt der API-Key' if ($diyOnly && !GOVEE_ApiKey());
  return "Szene '$want' gibt es fuer dieses Geraet nicht" . ($lib || $hash->{helper}{cloudScenes} ? '' : ' (Szenenliste noch nicht geladen)');
}

########################################
# LAN-Befehle gehen mit Abstand raus, schnelle Folgen verschlucken die Lampen sonst.
# Ein neuerer Wert ersetzt einen noch wartenden gleichen Befehl, das haelt Regler fluessig.

sub GOVEE_LanQueue {
  my ($hash, $cmd, $data) = @_;
  my $bridge = GOVEE_Bridge();
  return if (!$bridge);
  my $queue = $bridge->{helper}{queue} //= [];
  my $last  = @$queue ? $queue->[-1] : undef;
  if ($last && $last->{ip} eq $hash->{IP} && $last->{cmd} eq $cmd && $cmd ne 'ptReal' && $cmd ne 'turn') {
    $last->{data} = $data;
  } else {
    push @$queue, { ip => $hash->{IP}, cmd => $cmd, data => $data };
  }
  GOVEE_LanFlush($bridge) if (!$bridge->{helper}{flushing});
  return;
}

sub GOVEE_LanFlush {
  my ($bridge) = @_;
  my $item = shift @{ $bridge->{helper}{queue} // [] };
  if (!$item) {
    $bridge->{helper}{flushing} = 0;
    return;
  }
  GOVEE_Send($bridge, $item->{ip}, $GOVEE_portCmd, { cmd => $item->{cmd}, data => $item->{data} });
  $bridge->{helper}{flushing} = 1;
  InternalTimer(gettimeofday() + AttrVal($bridge->{NAME}, 'sendGap', 0.1), 'GOVEE_LanFlush', $bridge);
  return;
}

# Szenen-Paket: Parameter in Zeilen zu 19 Byte, Zeile 0 mit Kopf a3 00 01 <Zeilen> 02,
# Folgezeilen a3 <Nummer>, letzte Zeile a3 ff. Danach eine Zeile 33 05 04 mit dem Code.
sub GOVEE_SceneFrames {
  my ($code, $param) = @_;
  my @data = (0xa3, 0x00, 0x01, 0x00, 0x02);
  my ($lines, $marker) = (0, 1);
  for my $byte (unpack('C*', decode_base64($param // ''))) {
    if (@data % 19 == 0) {
      $lines++;
      push @data, 0xa3;
      $marker = @data;
      push @data, $lines;
    }
    push @data, $byte;
  }
  $data[$marker] = 0xff;
  $data[3] = $lines + 1;

  my @frames;
  while (@data) {
    push @frames, GOVEE_Frame(splice(@data, 0, 19));
  }
  push @frames, GOVEE_Frame(0x33, 0x05, 0x04, $code & 0xff, $code >> 8);
  return map { encode_base64($_, '') } @frames;
}

sub GOVEE_Frame {
  my @bytes = @_;
  my $sum = 0;
  $sum ^= $_ for (@bytes);
  push @bytes, (0) x (19 - @bytes), $sum;
  return pack('C*', @bytes);
}

########################################
# Szenenbibliothek je Modell

sub GOVEE_LibFile {
  my ($sku) = @_;
  return AttrVal('global', 'logdir', './log') . "/GOVEE_scenes_$sku.json";
}

sub GOVEE_LibEnsure {
  my ($bridge, $sku) = @_;
  return if (!$sku);
  my $mod = $modules{GOVEE};
  if (!$mod->{lib}{$sku}) {
    my ($err, @lines) = FileRead({ FileName => GOVEE_LibFile($sku), ForceType => 'file' });
    if (!$err && @lines) {
      my $cached = eval { JSON->new->utf8(0)->decode(join("\n", @lines)) };
      GOVEE_LibStore($sku, $cached->{scenes}, $cached->{ts}) if (ref($cached) eq 'HASH');
    }
  }
  my $now = gettimeofday();
  return if ($mod->{lib}{$sku} && $now - $mod->{lib}{$sku}{ts} < $GOVEE_libMaxAge);
  return if ($now - ($mod->{libTry}{$sku} // 0) < $GOVEE_libRetry);
  GOVEE_LibFetch($bridge, $sku);
  return;
}

sub GOVEE_LibFetch {
  my ($bridge, $sku) = @_;
  $modules{GOVEE}{libTry}{$sku} = gettimeofday();
  HttpUtils_NonblockingGet({
    url      => $GOVEE_libUrl . urlEncode($sku),
    method   => 'GET',
    header   => $GOVEE_libHeader,
    timeout  => 15,
    hash     => $bridge,
    sku      => $sku,
    callback => \&GOVEE_LibDone,
  });
  return;
}

sub GOVEE_LibDone {
  my ($param, $err, $data) = @_;
  my ($bridge, $sku) = ($param->{hash}, $param->{sku});
  my $name = $bridge->{NAME};
  if ($err) {
    readingsSingleUpdate($bridge, 'sceneError', "$sku: $err", 1);
    return;
  }
  my $json = eval { decode_json($data) };
  if (ref($json) ne 'HASH' || ref($json->{data}) ne 'HASH' || ref($json->{data}{categories}) ne 'ARRAY') {
    readingsSingleUpdate($bridge, 'sceneError', "$sku: unerwartete Antwort", 1);
    return;
  }

  my (@scenes, %seen);
  for my $cat (@{ $json->{data}{categories} }) {
    for my $scene (@{ $cat->{scenes} // [] }) {
      my $label = $scene->{sceneName};
      next if (!defined $label || $label eq '');
      my ($fx) = grep { $_->{sceneCode} } @{ $scene->{lightEffects} // [] };
      next if (!$fx);
      # Derselbe Name kommt in mehreren Kategorien vor und bedeutet dort etwas anderes
      my $unique = $label;
      if ($seen{ lc($unique) }) {
        $unique = "$label ($cat->{categoryName})";
        my $n = 2;
        $unique = "$label ($cat->{categoryName} " . $n++ . ')' while ($seen{ lc($unique) });
      }
      $seen{ lc($unique) } = 1;
      push @scenes, { name => $unique, cat => $cat->{categoryName} // '', code => int($fx->{sceneCode}),
                        param => $fx->{scenceParam} // '', type => int($fx->{sceneType} // 0) };
    }
  }
  if (!@scenes) {
    readingsSingleUpdate($bridge, 'sceneError', "$sku: keine Szenen", 1);
    return;
  }
  my $ts = gettimeofday();
  my $err2 = FileWrite({ FileName => GOVEE_LibFile($sku), ForceType => 'file' },
                       JSON->new->ascii->canonical->encode({ ts => int($ts), scenes => \@scenes }));
  Log3($name, 3, "$name: Szenenkopie $sku nicht gespeichert: $err2") if ($err2);
  GOVEE_LibStore($sku, \@scenes, $ts);
  readingsSingleUpdate($bridge, 'sceneError', 'none', 0);
  Log3($name, 4, "$name: $sku hat " . scalar(@scenes) . ' Szenen');
  return;
}

# Govee trennt manche Namen mit geschuetztem Leerzeichen. Readings muessen UTF-8-Bytes
# sein, sonst verwirft FTUI die ganze Liste.
sub GOVEE_CleanName {
  my ($name) = @_;
  $name =~ s/\x{a0}/ /g;
  utf8::encode($name);
  return $name;
}

sub GOVEE_LibStore {
  my ($sku, $scenes, $ts) = @_;
  return if (ref($scenes) ne 'ARRAY');
  for my $scene (@$scenes) {
    $scene->{$_} = GOVEE_CleanName($scene->{$_}) for (qw(name cat));
  }
  my %lookup = map { lc($_->{name}) => $_ } @$scenes;
  # Kopien von vor 1.0.4 kennen den Szenentyp nicht, sie werden beim naechsten Takt neu geladen
  $ts = 0 if (@$scenes && !defined($scenes->[0]{type}));
  $modules{GOVEE}{lib}{$sku} = { scenes => $scenes, lookup => \%lookup, ts => $ts // 0 };
  GOVEE_ClearSetlists($sku);
  for my $lamp (values %{ $modules{GOVEE}{defptr} // {} }) {
    next if ((GOVEE_Sku($lamp) // '') ne $sku);
    readingsSingleUpdate($lamp, 'scenes', scalar(@$scenes), 0);
  }
  return;
}

########################################
# Govee Developer API

sub GOVEE_CloudCall {
  my ($bridge, $method, $path, $payload, $cb, $lamp) = @_;
  my $key = GOVEE_ApiKey();
  return if (!$key);
  return if (gettimeofday() < ($bridge->{helper}{cloudBlockedUntil} // 0));
  HttpUtils_NonblockingGet({
    url      => $GOVEE_cloudBase . $path,
    method   => $method,
    header   => "Govee-API-Key: $key\r\nContent-Type: application/json",
    data     => $payload ? encode_json({ requestId => genUUID(), payload => $payload }) : undef,
    timeout  => 15,
    hash     => $bridge,
    lamp     => $lamp,
    cb       => $cb,
    callback => \&GOVEE_CloudDone,
  });
  return;
}

sub GOVEE_CloudDone {
  my ($param, $err, $data) = @_;
  my $bridge = $param->{hash};
  my $code   = $param->{code} // 0;
  if ($code == 429) {
    $bridge->{helper}{cloudBlockedUntil} = gettimeofday() + 600;
    readingsSingleUpdate($bridge, 'cloudError', 'Limit erreicht, Pause 10 Minuten', 1);
    return;
  }
  if ($err || $code != 200) {
    readingsSingleUpdate($bridge, 'cloudError', $err || "HTTP $code", 1);
    return;
  }
  my $json = eval { decode_json($data) };
  if (ref($json) ne 'HASH' || ($json->{code} // 200) != 200) {
    my $msg = ref($json) eq 'HASH' ? ($json->{message} // $json->{msg} // 'Fehler') : 'unerwartete Antwort';
    readingsSingleUpdate($bridge, 'cloudError', $msg, 1);
    return;
  }
  readingsSingleUpdate($bridge, 'cloudError', 'none', 0);
  $param->{cb}->($bridge, $param->{lamp}, $json) if ($param->{cb});
  return;
}

sub GOVEE_CloudDevices {
  my ($bridge, $manual) = @_;
  GOVEE_CloudCall($bridge, 'GET', '/user/devices', undef,
    sub { GOVEE_CloudDevicesDone($_[0], $_[2], $manual) });
  return;
}

sub GOVEE_CloudDevicesDone {
  my ($bridge, $json, $manual) = @_;
  $bridge->{helper}{lastDevices} = gettimeofday();
  return if (ref($json->{data}) ne 'ARRAY');
  for my $dev (@{ $json->{data} }) {
    next if (($dev->{type} // '') ne 'devices.types.light');
    (my $id = uc($dev->{device} // '')) =~ s/://g;
    GOVEE_Autocreate($bridge, $id, $dev->{sku}) if ($manual && !$modules{GOVEE}{defptr}{$id});
    my $lamp = $modules{GOVEE}{defptr}{$id};
    next if (!$lamp);
    readingsBeginUpdate($lamp);
    readingsBulkUpdateIfChanged($lamp, 'sku', $dev->{sku}) if ($dev->{sku});
    readingsBulkUpdateIfChanged($lamp, 'deviceName', GOVEE_CleanName($dev->{deviceName})) if ($dev->{deviceName});
    readingsEndUpdate($lamp, 0);
    GOVEE_ClearSetlists($dev->{sku});
    GOVEE_CloudScenes($bridge, $lamp);
    GOVEE_CloudStatus($bridge, $lamp) if ($manual && !$lamp->{helper}{lanOk});
  }
  return;
}

sub GOVEE_CloudPayload {
  my ($lamp) = @_;
  return { sku => GOVEE_Sku($lamp), device => GOVEE_CloudId($lamp) };
}

sub GOVEE_CloudScenes {
  my ($bridge, $lamp) = @_;
  return if (!GOVEE_Sku($lamp));
  $lamp->{helper}{lastCloudScenes} = gettimeofday();
  GOVEE_CloudCall($bridge, 'POST', '/device/scenes', GOVEE_CloudPayload($lamp),
    sub { GOVEE_CloudOptions($_[1], $_[2], 'cloudScenes') }, $lamp);
  GOVEE_CloudCall($bridge, 'POST', '/device/diy-scenes', GOVEE_CloudPayload($lamp),
    sub { GOVEE_CloudOptions($_[1], $_[2], 'cloudDiy') }, $lamp);
  return;
}

sub GOVEE_CloudOptions {
  my ($lamp, $json, $slot) = @_;
  my %options;
  my $caps = ref($json->{payload}) eq 'HASH' ? $json->{payload}{capabilities} : undef;
  for my $cap (ref($caps) eq 'ARRAY' ? @$caps : ()) {
    my $opts = ref($cap->{parameters}) eq 'HASH' ? $cap->{parameters}{options} : undef;
    for my $opt (ref($opts) eq 'ARRAY' ? @$opts : ()) {
      next if (!defined $opt->{name} || $opt->{name} eq '');
      # Die App erlaubt gleiche Namen, zum Beispiel zweimal "Neuer Effekt"
      my $base = GOVEE_CleanName($opt->{name});
      my ($label, $n) = ($base, 1);
      $label = "$base " . ++$n while (exists $options{$label});
      $options{$label} = $opt->{value};
    }
  }
  $lamp->{helper}{$slot} = \%options;
  delete $lamp->{helper}{setlist};
  return;
}

# Status aus der Cloud nur fuer Lampen, die per LAN nicht antworten
sub GOVEE_CloudCycle {
  my ($bridge, $now) = @_;
  return if (!GOVEE_ApiKey());
  my $name = $bridge->{NAME};
  GOVEE_CloudDevices($bridge, 0) if ($now - ($bridge->{helper}{lastDevices} // 0) >= $GOVEE_libMaxAge);
  my $interval = AttrVal($name, 'cloudInterval', 300);
  return if (!$interval);
  for my $lamp (GOVEE_Lamps()) {
    next if ($lamp->{helper}{lanOk} || !GOVEE_Sku($lamp));
    next if ($now - ($lamp->{helper}{lastCloud} // 0) < $interval);
    GOVEE_CloudStatus($bridge, $lamp);
  }
  return;
}

sub GOVEE_CloudStatus {
  my ($bridge, $lamp) = @_;
  $lamp->{helper}{lastCloud} = gettimeofday();
  GOVEE_CloudCall($bridge, 'POST', '/device/state', GOVEE_CloudPayload($lamp),
    sub { GOVEE_CloudStatusDone($_[1], $_[2]) }, $lamp);
  return;
}

sub GOVEE_CloudStatusDone {
  my ($lamp, $json) = @_;
  my $caps = ref($json->{payload}) eq 'HASH' ? $json->{payload}{capabilities} : undef;
  return if (ref($caps) ne 'ARRAY');

  my (%state, $online);
  for my $cap (@$caps) {
    next if (ref($cap->{state}) ne 'HASH');
    my ($inst, $val) = ($cap->{instance} // '', $cap->{state}{value});
    next if (!defined $val || $val eq '');
    if    ($inst eq 'online')            { $online = $val ? 1 : 0; }
    elsif ($inst eq 'powerSwitch')       { $state{on} = $val; }
    elsif ($inst eq 'brightness')        { $state{brightness} = $val; }
    elsif ($inst eq 'colorTemperatureK') { $state{kelvin} = $val; }
    elsif ($inst eq 'colorRgb') {
      ($state{r}, $state{g}, $state{b}) = (($val >> 16) & 255, ($val >> 8) & 255, $val & 255);
    }
  }
  $lamp->{helper}{cloudOk} = $online // 1;
  GOVEE_Connection($lamp);
  return if (gettimeofday() < ($lamp->{helper}{holdUntil} // 0));
  GOVEE_Apply($lamp, \%state);
  return;
}

sub GOVEE_CloudControl {
  my ($lamp, $type, $instance, $value) = @_;
  my $bridge = GOVEE_Bridge();
  return if (!$bridge);
  my $payload = GOVEE_CloudPayload($lamp);
  $payload->{capability} = { type => $type, instance => $instance, value => $value };
  GOVEE_CloudCall($bridge, 'POST', '/device/control', $payload, undef, $lamp);
  return;
}

1;

=pod
=item device
=item summary Govee lamps: LAN control and status, all app scenes per model
=item summary_DE Govee-Lampen: LAN-Steuerung und Status, alle App-Szenen je Modell

=begin html

<a id="GOVEE"></a>
<h3>GOVEE</h3>
<ul>
  Controls Govee lamps and LED strips directly from FHEM, without a bridge container and
  without MQTT. Switching, brightness, colour, colour temperature and status run locally on the
  LAN, and so do most scenes. Govee marks every scene with a type: types 0 and 2 run on the LAN,
  type 5 is not decoded yet and runs through the Govee cloud when an API key is stored. DIY scenes
  and lamps that do not answer on the LAN also use the cloud.<br><br>

  The list of scenes is loaded for each lamp model from the scene library of the Govee app, so
  the selection in FHEM shows the same scenes as the app. A copy is kept in the log directory,
  so the selection stays complete without an internet connection.<br><br>

  <b>Status updates</b>: Govee lamps do not report changes by themselves on the LAN. The bridge
  therefore asks them every <code>lanInterval</code> seconds. A change made in the Govee app
  appears in FHEM within that time. Readings only produce events when a value really changed,
  so polling does not flood the event log.<br><br>

  <b>Prerequisites</b>
  <ul>
    <li>LAN control enabled for each lamp in the Govee Home app (device settings).</li>
    <li>FHEM in the same network as the lamps. Inside Docker this requires host networking.</li>
    <li>UDP port 4002 free on the FHEM host. Only one program per host can use the Govee LAN
        interface.</li>
    <li>Recommended: a Govee API key, used for scenes, DIY scenes and the cloud fallback. In the Govee
        Home app: profile, settings (gear icon), "Apply for API Key".</li>
    <li>Perl module JSON (Debian: <code>libjson-perl</code>).</li>
  </ul>
  <br>

  <a id="GOVEE-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; GOVEE BRIDGE</code><br>
    <code>define &lt;name&gt; GOVEE &lt;deviceId&gt; [&lt;model&gt;]</code><br><br>
    One bridge is required and holds the UDP port for all lamps. There can only be one. Lamps
    are created with <code>set &lt;bridge&gt; scan</code> or by hand. The device id has 16 hex
    digits, with or without colons.<br><br>
    Example:
    <pre>
define GoveeBridge GOVEE BRIDGE
set GoveeBridge scan
define Lamp GOVEE AA:BB:CC:DD:EE:FF:00:11 H705D
set Lamp effect Sunrise</pre>
  </ul>

  <a id="GOVEE-set"></a>
  <b>Set (bridge)</b>
  <ul>
    <a id="GOVEE-set-scan"></a>
    <li><code>scan</code><br>
        Searches the network, and the cloud if a key is stored, and creates a device for each
        lamp found. New lamps get the room of the bridge, or Govee if it has none. Automatic
        background scans never create devices, so a deleted lamp stays deleted.</li>
    <a id="GOVEE-set-apiKey"></a>
    <li><code>apiKey &lt;key&gt;</code><br>
        Stores the API key obfuscated in the FHEM key store, not in fhem.cfg.</li>
    <a id="GOVEE-set-deleteApiKey"></a>
    <li><code>deleteApiKey</code><br>
        Removes the stored key.</li>
  </ul>
  <br>

  <b>Set (lamp)</b>
  <ul>
    <a id="GOVEE-set-on"></a>
    <li><code>on, off, toggle</code><br>
        Switches the lamp. The usual <a href="#setExtensions">set extensions</a> such as
        <code>on-for-timer</code> also work.</li>
    <a id="GOVEE-set-brightness"></a>
    <li><code>brightness &lt;0..100&gt;</code><br>
        Sets the brightness and switches the lamp on. 0 switches it off.</li>
    <a id="GOVEE-set-rgb"></a>
    <li><code>rgb &lt;RRGGBB&gt;</code>, <code>hsv &lt;HHSSVV&gt;</code><br>
        Sets a colour and switches the lamp on.</li>
    <a id="GOVEE-set-ct"></a>
    <li><code>ct &lt;value&gt;</code><br>
        Sets the colour temperature, as mired (below 1000) or kelvin.</li>
    <a id="GOVEE-set-effect"></a>
    <li><code>effect &lt;scene&gt;</code><br>
        Starts a scene. The selection contains the scenes of this lamp model, followed by your
        DIY scenes. In commands, write spaces as <code>#</code> or as spaces. A name that exists
        in several categories gets the category appended, for example
        <code>Rainbow (Shape)</code>. An unknown name returns an error message. The list does not show
        which scenes run through the cloud, the reading <code>sceneListCloud</code> names them.</li>
    <a id="GOVEE-set-effect_custom"></a>
    <li><code>effect_custom &lt;scene&gt;</code><br>
        The same as <code>effect</code> with free text input.</li>
    <a id="GOVEE-set-diy_scene"></a>
    <li><code>diy_scene &lt;scene&gt;</code><br>
        Starts a DIY scene from the Govee app. These always run through the cloud.</li>
    <a id="GOVEE-set-updateScenes"></a>
    <li><code>updateScenes</code><br>
        Reloads the scene list now. Otherwise this happens once a day.</li>
    <a id="GOVEE-set-statusRequest"></a>
    <li><code>statusRequest</code><br>
        Asks the lamp for its status now.</li>
  </ul>
  <br>

  <a id="GOVEE-attr"></a>
  <b>Attributes</b>
  <ul>
    <li><a href="#disable">disable</a> 0|1</li>
    <a id="GOVEE-attr-lanInterval"></a>
    <li><code>lanInterval</code> (bridge)<br>
        Seconds between status requests on the LAN, at least 5, default 30.</li>
    <a id="GOVEE-attr-scanInterval"></a>
    <li><code>scanInterval</code> (bridge)<br>
        Seconds between searches for lamps and changed IP addresses, at least 60, default 300.</li>
    <a id="GOVEE-attr-scanTargets"></a>
    <li><code>scanTargets</code> (bridge)<br>
        Additional addresses for the search, separated by commas, for example a broadcast
        address of another network.</li>
    <a id="GOVEE-attr-sendGap"></a>
    <li><code>sendGap</code> (bridge)<br>
        Seconds between LAN commands, default 0.1.</li>
    <a id="GOVEE-attr-cloudInterval"></a>
    <li><code>cloudInterval</code> (bridge)<br>
        Seconds between cloud status requests for lamps that do not answer on the LAN. At least
        60, 0 switches this off, default 300. Govee allows about 10,000 requests per day.</li>
    <a id="GOVEE-attr-lanIP"></a>
    <li><code>lanIP</code> (lamp)<br>
        Fixed address for a lamp that does not answer the multicast search.</li>
    <a id="GOVEE-attr-sceneFilter"></a>
    <li><code>sceneFilter</code> (lamp)<br>
        Regular expression that limits the selection list, checked against
        <code>category:name</code>. Example: <code>^(Natural|Life):</code>. Scenes outside the
        list can still be started by name.</li>
    <a id="GOVEE-attr-sceneRoute"></a>
    <li><code>sceneRoute</code> (lamp) auto|lan|cloud<br>
        auto sends scenes of type 0 and 2 on the LAN and type 5 through the cloud, if a key is
        stored and the cloud knows the scene. lan always uses the LAN, cloud always the cloud.
        Default auto.</li>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li>
  </ul>
  <br>

  <a id="GOVEE-readings"></a>
  <b>Readings (lamp)</b>
  <ul>
    <li><code>state</code>: on, off or offline</li>
    <li><code>powerSwitch</code>: ON or OFF</li>
    <li><code>brightness</code>: 1 to 100</li>
    <li><code>rgb</code>, <code>color_r</code>, <code>color_g</code>, <code>color_b</code>: colour</li>
    <li><code>color_mode</code>: rgb or color_temp</li>
    <li><code>color_temp</code>, <code>color_kelvin</code>: colour temperature in mired and kelvin</li>
    <li><code>effect</code>: the last scene started by FHEM. Lamps do not report the running scene,
        so a scene started in the app is not shown.</li>
    <li><code>connection</code>: lan, cloud or offline</li>
    <li><code>ip</code>, <code>sku</code>, <code>deviceName</code>, <code>wifiVersion</code>,
        <code>bleVersion</code>, <code>scenes</code> (number of scenes)</li>
    <li><code>sceneList</code>: the selectable scenes, separated by commas, for example to fill a
        selection list in FTUI. It follows <code>sceneFilter</code>.</li>
    <li><code>sceneListCloud</code>: those scenes from <code>sceneList</code> that are sent through
        the cloud, so a user interface can mark them. Empty when all run on the LAN.</li>
  </ul>
  <br>

  <b>Readings (bridge)</b>
  <ul>
    <li><code>state</code>: bereit, or a message that the port is in use</li>
    <li><code>discovered</code>: lamps found by the last search (model, id, address)</li>
    <li><code>apiKey</code>: gesetzt or fehlt</li>
    <li><code>cloudError</code>, <code>sceneError</code>: last error, or none</li>
  </ul>
  <br>

  <a id="GOVEE-lightscene"></a>
  <b>Saved states with LightScene</b>
  <ul>
    FHEM's <a href="#LightScene">LightScene</a> stores the state of a lamp under a name and restores it on
    command. Automations then switch to a name instead of a fixed colour, and the colour or scene behind the
    name can be changed without touching the automation. This attribute tells LightScene what to save: off,
    or brightness with the running scene, colour temperature or colour.
    <pre>
define LampScenes LightScene Lamp
attr Lamp lightSceneParamsToSave {ReadingsVal($DEVICE,"powerSwitch","OFF") ne "ON" ? "state" : ReadingsVal($DEVICE,"effect","") ne "" ? "brightness,effect" : ReadingsVal($DEVICE,"color_mode","") eq "color_temp" ? "brightness,color_temp -&gt; ct" : "brightness,rgb"}</pre>
    Set the lamp as wanted and save it, for example <code>set LampScenes save Night</code>, then recall it
    with <code>set LampScenes scene Night</code>. To return to the previous state later, save it first
    under its own name, for example <code>save beforeMotion</code>. A scene started in the Govee app is not
    known to FHEM, so it cannot be saved.
  </ul>
  <br>

  <b>Troubleshooting</b>
  <ul>
    <li><code>connection</code> stays cloud or offline: the lamp does not answer on the LAN.
        Switch LAN control off and on again in the app, and check that the lamp is in the same
        network segment. Some WLAN setups block multicast, in that case set
        <code>lanIP</code>.</li>
    <li>Bridge state says the port is in use: another program uses the Govee LAN interface on
        this host, for example a govee2mqtt container with host networking.</li>
    <li>Scene does not start, but no error: not all models support all scenes on the LAN. Set
        verbose 5 on the bridge to see what is sent.</li>
    <li>A scene sent over the LAN turns the lamp off briefly and the last DIY scene comes back:
        this happens with scenes of type 5, whose LAN packet is not decoded. Store an API key, these
        scenes then run through the cloud. If a lamp also rejects other scenes on the LAN, set
        <code>sceneRoute</code> to cloud.</li>
  </ul>
</ul>

=end html

=begin html_DE

<a id="GOVEE"></a>
<h3>GOVEE</h3>
<ul>
  Steuert Govee-Lampen und LED-Streifen direkt aus FHEM, ohne Bridge-Container und ohne MQTT.
  Schalten, Helligkeit, Farbe, Farbtemperatur und Status laufen lokal im LAN, ebenso die meisten
  Szenen. Govee kennzeichnet jede Szene mit einem Typ: Typ 0 und 2 laufen per LAN, Typ 5 ist noch
  nicht entschlüsselt und läuft mit API-Key über die Govee-Cloud. Auch DIY-Szenen und Lampen, die
  im LAN nicht antworten, nutzen die Cloud.<br><br>

  Die Szenenliste wird je Lampenmodell aus der Szenenbibliothek der Govee-App geladen. Die
  Auswahl in FHEM zeigt also dieselben Szenen wie die App. Eine Kopie liegt im Log-Verzeichnis,
  dadurch bleibt die Auswahl auch ohne Internet vollständig.<br><br>

  <b>Statusmeldungen</b>: Govee-Lampen melden Änderungen im LAN nicht von sich aus. Die Bridge
  fragt sie deshalb alle <code>lanInterval</code> Sekunden ab. Eine Änderung in der Govee-App
  erscheint innerhalb dieser Zeit in FHEM. Readings erzeugen nur dann Events, wenn sich ein Wert
  wirklich geändert hat, die Abfragen belasten das Event-Log also nicht.<br><br>

  <b>Voraussetzungen</b>
  <ul>
    <li>LAN-Steuerung je Lampe in der Govee-Home-App aktiviert (Geräteeinstellungen).</li>
    <li>FHEM im selben Netz wie die Lampen. In Docker ist dafür Host-Netzwerk nötig.</li>
    <li>UDP-Port 4002 auf dem FHEM-Rechner frei. Die Govee-LAN-Schnittstelle kann je Rechner nur
        ein Programm nutzen.</li>
    <li>Empfohlen: ein Govee-API-Key für Szenen, DIY-Szenen und den Cloud-Rückfall. In der Govee-Home-App:
        Profil, Einstellungen (Zahnrad), „Apply for API Key“.</li>
    <li>Perl-Modul JSON (Debian: <code>libjson-perl</code>).</li>
  </ul>
  <br>

  <a id="GOVEE-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; GOVEE BRIDGE</code><br>
    <code>define &lt;name&gt; GOVEE &lt;Geräte-ID&gt; [&lt;Modell&gt;]</code><br><br>
    Eine Bridge ist nötig, sie hält den UDP-Port für alle Lampen. Es kann nur eine geben. Lampen
    entstehen mit <code>set &lt;bridge&gt; scan</code> oder von Hand. Die Geräte-ID hat 16
    Hex-Zeichen, mit oder ohne Doppelpunkte.<br><br>
    Beispiel:
    <pre>
define GoveeBridge GOVEE BRIDGE
set GoveeBridge scan
define Lampe GOVEE AA:BB:CC:DD:EE:FF:00:11 H705D
set Lampe effect Sunrise</pre>
  </ul>

  <a id="GOVEE-set"></a>
  <b>Set (Bridge)</b>
  <ul>
    <a id="GOVEE-set-scan"></a>
    <li><code>scan</code><br>
        Sucht im Netz und, falls ein Schlüssel gespeichert ist, in der Cloud und legt für jede
        gefundene Lampe ein Gerät an. Neue Lampen übernehmen den Raum der Bridge, ohne Raum
        landen sie in Govee. Die automatische Suche im Hintergrund legt nie Geräte an, eine
        gelöschte Lampe bleibt also gelöscht.</li>
    <a id="GOVEE-set-apiKey"></a>
    <li><code>apiKey &lt;Schlüssel&gt;</code><br>
        Speichert den API-Key verschleiert im FHEM-Schlüsselspeicher, nicht in der fhem.cfg.</li>
    <a id="GOVEE-set-deleteApiKey"></a>
    <li><code>deleteApiKey</code><br>
        Entfernt den gespeicherten Schlüssel.</li>
  </ul>
  <br>

  <b>Set (Lampe)</b>
  <ul>
    <a id="GOVEE-set-on"></a>
    <li><code>on, off, toggle</code><br>
        Schaltet die Lampe. Die üblichen <a href="#setExtensions">set extensions</a> wie
        <code>on-for-timer</code> funktionieren ebenfalls.</li>
    <a id="GOVEE-set-brightness"></a>
    <li><code>brightness &lt;0..100&gt;</code><br>
        Setzt die Helligkeit und schaltet die Lampe ein. 0 schaltet sie aus.</li>
    <a id="GOVEE-set-rgb"></a>
    <li><code>rgb &lt;RRGGBB&gt;</code>, <code>hsv &lt;HHSSVV&gt;</code><br>
        Setzt eine Farbe und schaltet die Lampe ein.</li>
    <a id="GOVEE-set-ct"></a>
    <li><code>ct &lt;Wert&gt;</code><br>
        Setzt die Farbtemperatur, als Mired (unter 1000) oder Kelvin.</li>
    <a id="GOVEE-set-effect"></a>
    <li><code>effect &lt;Szene&gt;</code><br>
        Startet eine Szene. Die Auswahl enthält die Szenen dieses Lampenmodells, danach deine
        DIY-Szenen. In Befehlen schreibst du Leerzeichen als <code>#</code> oder als Leerzeichen.
        Kommt ein Name in mehreren Kategorien vor, steht die Kategorie dahinter, zum Beispiel
        <code>Rainbow (Shape)</code>. Bei einem unbekannten Namen kommt eine Fehlermeldung. Welche Szenen
        über die Cloud laufen, zeigt die Auswahl nicht, das Reading <code>sceneListCloud</code> nennt sie.</li>
    <a id="GOVEE-set-effect_custom"></a>
    <li><code>effect_custom &lt;Szene&gt;</code><br>
        Wie <code>effect</code>, aber mit freier Texteingabe.</li>
    <a id="GOVEE-set-diy_scene"></a>
    <li><code>diy_scene &lt;Szene&gt;</code><br>
        Startet eine DIY-Szene aus der Govee-App. Diese laufen immer über die Cloud.</li>
    <a id="GOVEE-set-updateScenes"></a>
    <li><code>updateScenes</code><br>
        Lädt die Szenenliste sofort neu. Sonst passiert das einmal am Tag.</li>
    <a id="GOVEE-set-statusRequest"></a>
    <li><code>statusRequest</code><br>
        Fragt den Status der Lampe sofort ab.</li>
  </ul>
  <br>

  <a id="GOVEE-attr"></a>
  <b>Attribute</b>
  <ul>
    <li><a href="#disable">disable</a> 0|1</li>
    <a id="GOVEE-attr-lanInterval"></a>
    <li><code>lanInterval</code> (Bridge)<br>
        Sekunden zwischen den Statusabfragen im LAN, mindestens 5, Vorgabe 30.</li>
    <a id="GOVEE-attr-scanInterval"></a>
    <li><code>scanInterval</code> (Bridge)<br>
        Sekunden zwischen den Suchen nach Lampen und geänderten IP-Adressen, mindestens 60,
        Vorgabe 300.</li>
    <a id="GOVEE-attr-scanTargets"></a>
    <li><code>scanTargets</code> (Bridge)<br>
        Weitere Adressen für die Suche, durch Kommas getrennt, zum Beispiel die
        Broadcast-Adresse eines anderen Netzes.</li>
    <a id="GOVEE-attr-sendGap"></a>
    <li><code>sendGap</code> (Bridge)<br>
        Sekunden zwischen LAN-Befehlen, Vorgabe 0.1.</li>
    <a id="GOVEE-attr-cloudInterval"></a>
    <li><code>cloudInterval</code> (Bridge)<br>
        Sekunden zwischen Cloud-Statusabfragen für Lampen, die im LAN nicht antworten. Mindestens
        60, 0 schaltet das ab, Vorgabe 300. Govee erlaubt rund 10.000 Anfragen am Tag.</li>
    <a id="GOVEE-attr-lanIP"></a>
    <li><code>lanIP</code> (Lampe)<br>
        Feste Adresse für eine Lampe, die auf die Multicast-Suche nicht antwortet.</li>
    <a id="GOVEE-attr-sceneFilter"></a>
    <li><code>sceneFilter</code> (Lampe)<br>
        Regulärer Ausdruck, der die Auswahlliste begrenzt, geprüft gegen
        <code>Kategorie:Name</code>. Beispiel: <code>^(Natural|Life):</code>. Szenen außerhalb
        der Liste lassen sich weiter über den Namen starten.</li>
    <a id="GOVEE-attr-sceneRoute"></a>
    <li><code>sceneRoute</code> (Lampe) auto|lan|cloud<br>
        auto schickt Szenen vom Typ 0 und 2 per LAN und Typ 5 über die Cloud, wenn ein Schlüssel
        gespeichert ist und die Cloud die Szene kennt. lan nimmt immer das LAN, cloud immer die
        Cloud. Vorgabe auto.</li>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li>
  </ul>
  <br>

  <a id="GOVEE-readings"></a>
  <b>Readings (Lampe)</b>
  <ul>
    <li><code>state</code>: on, off oder offline</li>
    <li><code>powerSwitch</code>: ON oder OFF</li>
    <li><code>brightness</code>: 1 bis 100</li>
    <li><code>rgb</code>, <code>color_r</code>, <code>color_g</code>, <code>color_b</code>: Farbe</li>
    <li><code>color_mode</code>: rgb oder color_temp</li>
    <li><code>color_temp</code>, <code>color_kelvin</code>: Farbtemperatur in Mired und Kelvin</li>
    <li><code>effect</code>: die zuletzt von FHEM gestartete Szene. Lampen melden die laufende
        Szene nicht, eine in der App gestartete Szene erscheint hier also nicht.</li>
    <li><code>connection</code>: lan, cloud oder offline</li>
    <li><code>ip</code>, <code>sku</code>, <code>deviceName</code>, <code>wifiVersion</code>,
        <code>bleVersion</code>, <code>scenes</code> (Anzahl der Szenen)</li>
    <li><code>sceneList</code>: die wählbaren Szenen, durch Kommas getrennt, zum Beispiel für eine
        Auswahlliste in FTUI. Sie folgt <code>sceneFilter</code>.</li>
    <li><code>sceneListCloud</code>: die Szenen aus <code>sceneList</code>, die über die Cloud
        gesendet werden, damit eine Oberfläche sie kennzeichnen kann. Leer, wenn alle per LAN laufen.</li>
  </ul>
  <br>

  <b>Readings (Bridge)</b>
  <ul>
    <li><code>state</code>: bereit, oder der Hinweis, dass der Port belegt ist</li>
    <li><code>discovered</code>: bei der letzten Suche gefundene Lampen (Modell, ID, Adresse)</li>
    <li><code>apiKey</code>: gesetzt oder fehlt</li>
    <li><code>cloudError</code>, <code>sceneError</code>: letzter Fehler oder none</li>
  </ul>
  <br>

  <a id="GOVEE-lightscene"></a>
  <b>Gespeicherte Zustände mit LightScene</b>
  <ul>
    FHEMs <a href="#LightScene">LightScene</a> speichert den Zustand einer Lampe unter einem Namen und
    stellt ihn per Befehl wieder her. Automatiken schalten dann auf einen Namen statt auf eine feste Farbe,
    und die Farbe oder Szene dahinter lässt sich ändern, ohne die Automatik anzufassen. Dieses Attribut sagt
    LightScene, was es speichern soll: aus, oder Helligkeit mit laufender Szene, Farbtemperatur oder Farbe.
    <pre>
define LampenSzenen LightScene Lampe
attr Lampe lightSceneParamsToSave {ReadingsVal($DEVICE,"powerSwitch","OFF") ne "ON" ? "state" : ReadingsVal($DEVICE,"effect","") ne "" ? "brightness,effect" : ReadingsVal($DEVICE,"color_mode","") eq "color_temp" ? "brightness,color_temp -&gt; ct" : "brightness,rgb"}</pre>
    Stelle die Lampe wie gewünscht ein und speichere sie, zum Beispiel mit
    <code>set LampenSzenen save Nacht</code>, und rufe sie mit <code>set LampenSzenen scene Nacht</code> auf.
    Um später zum vorherigen Zustand zurückzukehren, speichere ihn vorher unter einem eigenen Namen, zum
    Beispiel <code>save vorBewegung</code>. Eine in der Govee-App gestartete Szene kennt FHEM nicht, sie
    lässt sich also nicht speichern.
  </ul>
  <br>

  <b>Fehlersuche</b>
  <ul>
    <li><code>connection</code> bleibt cloud oder offline: Die Lampe antwortet nicht im LAN.
        Schalte die LAN-Steuerung in der App aus und wieder ein und prüfe, ob die Lampe im selben
        Netzsegment hängt. Manche WLAN-Netze sperren Multicast, setze dann
        <code>lanIP</code>.</li>
    <li>Die Bridge meldet einen belegten Port: Ein anderes Programm nutzt auf diesem Rechner die
        Govee-LAN-Schnittstelle, zum Beispiel ein govee2mqtt-Container mit Host-Netzwerk.</li>
    <li>Eine Szene startet nicht, aber es kommt kein Fehler: Nicht jedes Modell kann jede Szene
        im LAN. Setze verbose 5 an der Bridge, um zu sehen, was gesendet wird.</li>
    <li>Eine per LAN gesendete Szene lässt die Lampe kurz ausgehen und die letzte DIY-Szene kommt
        zurück: Das passiert bei Szenen vom Typ 5, deren LAN-Paket nicht entschlüsselt ist.
        Hinterlege einen API-Key, dann laufen diese Szenen über die Cloud. Lehnt eine Lampe auch
        andere Szenen im LAN ab, setze <code>sceneRoute</code> auf cloud.</li>
  </ul>
</ul>

=end html_DE

=cut
