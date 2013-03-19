#!/usr/bin/perl

######################################################################
#
#  git-remote-s3bundle
#
#  Released under MIT License - See LICENSE file in this directory
#
######################################################################

use strict;
use warnings;

#
# Dependencies
#
# CentOS / RHEL / Fedora:
# yum install perl-libwww-perl perl-JSON perl-Digest-HMAC
#
# Debian / Ubuntu
# apt-get install libnet-perl
#

use JSON;
use LWP::Simple;
use LWP::UserAgent;
use HTTP::Date;
use Digest::HMAC_SHA1;
use MIME::Base64;
use File::Temp qw/ tempfile /;

use constant IAM_METADATA_URL => "http://169.254.169.254/latest/meta-data/iam";

# globals are bad
my @refs;
my $packfile;
my $verbose = 0;

sub valid_aws_credentials
{
    my $id  = shift;
    my $key = shift;

    return 0 unless defined $id;
    return 0 unless defined $key;

    return 0 unless ( length($id) == 20 );
    return 0 unless ( length($key) == 40 );

    return 1;
}

sub s3sign
{
    my $path = shift || die;
    my $date = shift || die;
    my $key  = shift || die;
    my $token = shift;

    my $headers = "";
    if ($token) {
        $headers = "x-amz-security-token:$token\n";
    }

    my $stringToSign = sprintf( "GET\n\n\n%s\n%s%s", $date, $headers, $path );
    my $hmac = Digest::HMAC_SHA1->new($key);
    $hmac->add($stringToSign);
    my $digest = encode_base64( $hmac->digest, '' );
    return $digest;
}

sub get_iam_role_creds
{
    my $roles = get( IAM_METADATA_URL . "/security-credentials/" );
    die "No IAM credentials available from EC2 metadata sevice" unless $roles;

    my @roles = split( "\n", $roles );
    die "IAM must return a single role" unless ( scalar @roles == 1 );

    my $role = $roles[0];
    print STDERR "$0: Using AWS IAM role for S3 fetch: $role\n";

    my $results = get( IAM_METADATA_URL . "/security-credentials/$role" );
    my $json    = from_json($results);
    my %h       = %{$json};

    die "invalid credential type from IAM" unless $h{Type} eq "AWS-HMAC";
    die "invalid credentials from IAM"
      unless valid_aws_credentials( $h{AccessKeyId}, $h{SecretAccessKey} );
    die "invalid token from IAM" if ( length( $h{Token} ) < 100 );
    return ( $h{AccessKeyId}, $h{SecretAccessKey}, $h{Token} );
}

sub create_s3_request
{

    my $s3url = shift || die;

    if ( $s3url !~ /^s3:\/\/([^\/]+)\/(.+)/ ) {
        die "Bad S3 URL: $s3url";
    }

    my $bucket = $1;
    my $path   = $2;
    my $date   = time2str();

    my $url = "https://$bucket.s3.amazonaws.com/$path";
    print STDERR "$0: Bundle URL = $url\n" if ($verbose);

    # Get credentials from environment
    my $AccessKeyId     = $ENV{AWS_ACCESS_KEY_ID};
    my $SecretAccessKey = $ENV{AWS_SECRET_ACCESS_KEY};
    my $Token           = undef;

    # Get credentials IAM
    if ( !valid_aws_credentials( $AccessKeyId, $SecretAccessKey ) ) {
        ( $AccessKeyId, $SecretAccessKey, $Token ) = get_iam_role_creds();
    }

    my $sig = s3sign( "/$bucket/$path", $date, $SecretAccessKey, $Token );

    my $req = HTTP::Request->new( GET => $url );
    $req->header(
        "Date"                 => $date,
        "Authorization"        => "AWS $AccessKeyId:$sig",
        "x-amz-security-token" => $Token
    );

    return $req;
}

sub get_bundle
{
    my $s3url = shift;
    $s3url =~ s/s3bundle/s3/;

    my $ua  = LWP::UserAgent->new;
    my $req = create_s3_request($s3url);

    my ( $fh, $tempfile ) = tempfile();

    #close($fh);
    print STDERR "$0: Temp file is $tempfile\n" if ($verbose);

    my $res = $ua->request( $req, $tempfile );
    if ( !$res->is_success ) {
        die "Failed to fetch bundle:"
          . $res->status_line . "\n"
          . $res->content . "\n";
    }

    open( BUNDLE, $tempfile ) || die;
    my $header = <BUNDLE>;
    die "unable to retrieve bundle $s3url" unless ($header);
    die "bad bundle header" unless ( $header eq "# v2 git bundle\n" );

    while ( my $line = <BUNDLE> ) {
        chomp $line;
        last if ( $line eq "" );
        push @refs, $line;
    }

    local $/ = undef;
    $packfile = <BUNDLE>;
    my $len = length($packfile);
    print STDERR "$0: Got $len bytes pack file\n" if ($verbose);
    die "invalid packfile" unless ( $packfile =~ /\APACK/ );
}

# main
{
    $| = 1;

    my $unpacked = 0;

    print STDERR "$0: Starting up with @ARGV\n" if ($verbose);
    my $remote = $ARGV[0];
    my $url    = $ARGV[1];

    get_bundle($url);

    while ( my $command = <STDIN> ) {
        chomp $command;

        next if $command eq "";
        print STDERR "$0: Got command: $command\n" if ($verbose);

        if ( $command eq 'capabilities' ) {
            print STDOUT "fetch\n\n";
        }

        elsif ( $command =~ /^fetch/ ) {
            if ( !$unpacked ) {
                open( UNPACK, "|git unpack-objects" ) || die;
                print UNPACK $packfile;
                close(UNPACK);
                $unpacked++;
            }
            print STDOUT "\n";
        }

        elsif ( $command eq 'list' ) {
            foreach (@refs) { print STDOUT "$_\n"; }
            print STDOUT "\n";

        }

        else {
            die "received unknown command from git: $command\n";
        }

    }
}

