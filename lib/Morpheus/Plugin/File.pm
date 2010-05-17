package Morpheus::Plugin::File;
use strict;

use Data::Dumper;
use File::Find;
use Digest::MD5 qw(md5_hex);

my @config_path;

sub _package($) {
    my ($ns) = @_;
    my $md5 = md5_hex(__PACKAGE__, $ns);
    $ns =~ s/[^\w]/_/g;
    return __PACKAGE__."::Package::${ns}_${md5}";
}

sub content ($) {
    my ($ns) = @_;
    my $file = _find_file($ns);
    open my $fh, "<", "$file" or die "open $file failed: $!";
    my $content = do { local $/; <$fh> };
    close $fh or die "close failed: $!";
    return ($file => $content);
}

my %cache;

sub _process_file ($) {
    my ($ns) = @_;
    return if exists $cache{$ns};
    $cache{$ns} = undef;
    my $package = _package($ns);
    my ($file, $content) = content($ns);
    my @eval = eval qq{
no strict;
no warnings;
package $package;
# line 1 "$file"
$content
};
    die $@ if $@;

    $cache{$ns} = _get($ns);
    unless (defined $cache{$ns}) {
        if (@eval == 1) {
            ($cache{$ns}) = @eval;
        } else {
            $cache{$ns} = {@eval};
        }
    }
    die "$file: config block should return or define something" unless defined $cache{$ns};
}

sub _get ($) {
    my ($ns) = @_;
    return $cache{$ns} if defined $cache{$ns};

    # maybe a partially evaluated config block
    my $package = _package($ns);
    my $stash = do { no strict 'refs'; \%{"${package}::"} };
    my $value;
    for (keys %$stash) {
        next unless $_;
        my $glob = $stash->{$_};
        if (defined *{$glob}{ARRAY} or defined *{$glob}{HASH}) {
            $value->{$_} = \*{$glob};
        } elsif (defined ${$glob}) {
            $value->{$_} = ${$glob};
        }
    }
    return $value;
}

sub _find_file($) {
    my ($ns) = @_;
    my $config = $ns;
    my $file;

    for my $config_path (@config_path) {
        my @suffix = (qw(.cfg .conf));
        @suffix = ("") if ($ns =~ m{^stream/});
        for my $suffix (@suffix) {
            $file = "$config_path/$config$suffix";
            return $file if -e $file;
        }
    }
    return;
}

sub list ($$) {
    my ($class, $main_ns) = @_;

    @config_path = @{Morpheus::morph("morpheus/plugin/file/options/path")}
        unless @config_path; #FIXME: move caching to Morpheus.pm itself

    my %list;
    for my $config_path (@config_path) {
        $config_path =~ s{/+$}{};
        if (-d "$config_path/$main_ns") {
            find({
                no_chdir => 1,
                follow_skip => 2,
                wanted => sub {
                    -f or return;
                    die unless $File::Find::name =~ m{^\Q$config_path\E/(.*)};
                    my $ns = $1;
                    return unless $ns =~ m{^stream/} or $ns =~ s{\.(?:cfg|conf)$}{};
                    die "mystery: $ns" unless _find_file($ns);
                    $list{$ns} = 1;
                }
            }, "$config_path/$main_ns");
        }
    }
    my @list = keys %list;

    my $ns = $main_ns;
    while ($ns) {
        push @list, $ns if _find_file($ns);
        $ns =~ s{/?[^/]+$}{};
    }

    return @list;
}

sub morph ($$) {

    my ($class, $ns) = @_;
    _process_file($ns);
    return _get($ns);
}

1;
