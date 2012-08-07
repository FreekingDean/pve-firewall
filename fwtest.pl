#!/usr/bin/perl -w

use strict;
use lib qw(.);
use PVE::Firewall;
use File::Path;
use IO::File;
use Data::Dumper;

use PVE::SafeSyslog;
use PVE::Cluster;
use PVE::INotify;
use PVE::RPCEnvironment;
use PVE::QemuServer;

use PVE::JSONSchema qw(get_standard_option);

use PVE::CLIHandler;

use base qw(PVE::CLIHandler);

$ENV{'PATH'} = '/sbin:/bin:/usr/sbin:/usr/bin';

initlog ('pvefw');

die "please run as root\n" if $> != 0;

PVE::INotify::inotify_init();

my $rpcenv = PVE::RPCEnvironment->init('cli');

$rpcenv->init_request();
$rpcenv->set_language($ENV{LANG});
$rpcenv->set_user('root@pam');

sub parse_fw_rules {
    my ($filename, $fh) = @_;

    my $section;

    my $res = { in => [], out => [] };

    while (defined(my $line = <$fh>)) {
	next if $line =~ m/^#/;
	next if $line =~ m/^\s*$/;

	if ($line =~ m/^\[(in|out)\]\s*$/i) {
	    $section = lc($1);
	    next;
	}
	next if !$section;

	my ($action, $iface, $source, $dest, $proto, $dport, $sport) =
	    split(/\s+/, $line);

	if (!($action && $iface && $source && $dest)) {
	    warn "skip incomplete line\n";
	    next;
	}

	if ($action !~ m/^(ACCEPT|DROP)$/) {
	    warn "unknown action '$action'\n";
#	    next;
	}

	if ($iface !~ m/^(all|net0|net1|net2|net3|net4|net5)$/) {
	    warn "unknown interface '$iface'\n";
	    next;
	}

	if ($proto && $proto !~ m/^(icmp|tcp|udp)$/) {
	    warn "unknown protokol '$proto'\n";
	    next;
	}

	if ($source !~ m/^(any)$/) {
	    warn "unknown source '$source'\n";
	    next;
	}

	if ($dest !~ m/^(any)$/) {
	    warn "unknown destination '$dest'\n";
	    next;
	}

	my $rule = {
	    action => $action,
	    iface => $iface,
	    source => $source,
	    dest => $dest,
	    proto => $proto,
	    dport => $dport,
	    sport => $sport,
	};

	push @{$res->{$section}}, $rule;
    }

    return $res;
}

sub read_local_vm_config {

    my $openvz = {};

    my $qemu = {};

    my $list = PVE::QemuServer::config_list();

    foreach my $vmid (keys %$list) {
	my $cfspath = PVE::QemuServer::cfs_config_path($vmid);
	if (my $conf = PVE::Cluster::cfs_read_file($cfspath)) {
	    $qemu->{$vmid} = $conf;
	}
    }

    my $vmdata = { openvz => $openvz, qemu => $qemu };

    return $vmdata;
};

sub read_vm_firewall_rules {
    my ($vmdata) = @_;

    my $rules = {};
    foreach my $vmid (keys %{$vmdata->{qemu}}, keys %{$vmdata->{openvz}}) {
	my $filename = "/etc/pve/$vmid.fw";
	my $fh = IO::File->new($filename, O_RDONLY);
	next if !$fh;

	$rules->{$vmid} = parse_fw_rules($filename, $fh);
    }

    return $rules;
}

__PACKAGE__->register_method ({
    name => 'compile',
    path => 'compile',
    method => 'POST',
    description => "Compile firewall rules.",
    parameters => {
    	additionalProperties => 0,
	properties => {},
    },
    returns => { type => 'null' },

    code => sub {
	my ($param) = @_;

	my $vmdata = read_local_vm_config();
	my $rules = read_vm_firewall_rules();

	# print Dumper($vmdata);

	my $swdir = '/etc/shorewall';
	mkdir $swdir;

	PVE::Firewall::compile($swdir, $vmdata, $rules);

	PVE::Tools::run_command(['shorewall', 'compile']);

	return undef;

    }});

__PACKAGE__->register_method ({
    name => 'start',
    path => 'start',
    method => 'POST',
    description => "Start firewall.",
    parameters => {
    	additionalProperties => 0,
	properties => {},
    },
    returns => { type => 'null' },

    code => sub {
	my ($param) = @_;

	PVE::Tools::run_command(['shorewall', 'start']);

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'stop',
    path => 'stop',
    method => 'POST',
    description => "Stop firewall.",
    parameters => {
    	additionalProperties => 0,
	properties => {},
    },
    returns => { type => 'null' },

    code => sub {
	my ($param) = @_;

	PVE::Tools::run_command(['shorewall', 'stop']);

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'clear',
    path => 'clear',
    method => 'POST',
    description => "Clear will remove all rules installed by this script. The host is then unprotected.",
    parameters => {
    	additionalProperties => 0,
	properties => {},
    },
    returns => { type => 'null' },

    code => sub {
	my ($param) = @_;

	PVE::Tools::run_command(['shorewall', 'clear']);

	return undef;
    }});

my $nodename = PVE::INotify::nodename();

my $cmddef = {
    compile => [ __PACKAGE__, 'compile', []],
    start => [ __PACKAGE__, 'start', []],
    stop => [ __PACKAGE__, 'stop', []],
    clear => [ __PACKAGE__, 'clear', []],
};

my $cmd = shift;

PVE::CLIHandler::handle_cmd($cmddef, "pvefw", $cmd, \@ARGV, undef, $0);

exit(0);

