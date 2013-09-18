#!/usr/bin/env perl

# Copyright 2013, Patrick Bogen
#
# This file is part of pastebinfs.
# 
# pastebinfs is free software: you can redistribute it and/or modify it under 
# the terms of the GNU General Public License as published by the Free Software 
# Foundation, either version 3 of the License, or (at your option) any later 
# version.
# 
# pastebinfs is distributed in the hope that it will be useful, but WITHOUT ANY 
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR 
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License along with 
# pastebinfs.  If not, see <http://www.gnu.org/licenses/>.
	
use warnings;
use strict;

use 5.014;  # so push/pop/etc work on scalars (experimental)

use Fuse;
use Getopt::Long;
use POSIX qw(ENOENT EPERM EFAULT EEXIST strtol);
use LWP;
use Fcntl ':mode';
use URI::Encode qw( uri_encode );

my %inodes;
my %pastes;
my $pastes_last=0;
my $next_inode=1;
my $ua = LWP::UserAgent->new;
$ua->agent( "pastebinfs/0.1 (YUP!)" );

my( $api_key, $username, $password );
my( $evil, $debug, $cache ) = (0, 0, 30);

my $session_key;
my $pastebin_session_id;

GetOptions(
	"api-key|a=s" => \$api_key,
	"username|u=s" => \$username,
	"password|p=s" => \$password,
	"evil" => \$evil,
	"debug|d" => \$debug,
	"cache|c=i" => \$cache,
) or usage();

usage() unless defined $api_key && defined $username && defined $password;

my $pid;
if( $pid = fork() == 0 ) {
	if( fork() != 0 ) {
		exit;
	}
} else {
	wait;
	exit;
}

my $mountpoint = "";
$mountpoint = shift @ARGV if @ARGV;

Fuse::main(
	mountpoint => $mountpoint,
	readdir => \&readdir,
	getattr => \&getattr,
	read => \&read,
	readlink => \&pastebinfs_readlink,
	open => \&open,
	create => \&create,
	unlink => \&pastebinfs_unlink,
	write => \&write,
);

sub write {
}

sub pastebinfs_unlink {
	my( $path ) = shift;
	warn( "--> unlink( $path )" ) if $debug;
	my @parts = split( '/', $path );
	my $filename = pop @parts;

	my $req = HTTP::Request->new( POST => "http://pastebin.com/api/api_post.php" );

	if( exists( $pastes{ $path } ) && $pastes{ $path }->{ "type" } eq "paste" ) {
		$req->content_type( 'application/x-www-form-urlencoded' );
		$req->content( join( '&', map { uri_encode( $_ ) } (
			"api_dev_key=$api_key",
			"api_user_key=$session_key",
			"api_option=delete",
			"api_paste_key=$filename",
		) ) );
		my $res = $ua->request( $req );
		if( $res->is_success ) {
			$pastes_last=0; list_pastes();
			warn( "<-- unlink( $path ) == 0" ) if $debug;
			return 0;
		} else {
			warn( "failed while deleting $path:\n".$res->as_string );
			warn( "<-- unlink( $path ) == EFAULT" ) if $debug;
			return -EFAULT();
		}
	} elsif( exists( $pastes{ $path } ) && $pastes{ $path }->{ "type" } eq "link" ) {
		warn( "<-- unlink( $path ) == unlink( ".$pastes{ $path }->{ "to" }." )" ) if $debug;
		return pastebinfs_unlink( $pastes{ $path }->{ "to" } );
	} else {
		warn( "<-- unlink( $path ) == ENOENT" ) if $debug;
		return -ENOENT();
	}
}

sub create {
	my( $path, $mask, $mode ) = shift;
	my @parts = split( '/', $path );
	my $filename = pop @parts;
	
	return -EEXIST() if exists( $pastes{ $path } );

	my $req = HTTP::Request->new( POST => "http://pastebin.com/api/api_post.php" );
	$req->content_type( 'application/x-www-form-urlencoded' );
	$req->content( join( '&', map { uri_encode( $_ ) } (
		"api_dev_key=$api_key",
		"api_user_key=$session_key",
		"api_option=paste",
		"api_paste_name=$filename",
		"api_paste_code= ",
	) ) );
	my $res = $ua->request( $req );
	if( $res->is_success ) {
		if( $res->content =~ m!http://pastebin.com/[a-zA-Z0-9]+!i ) {
			$pastes_last=0; list_pastes();
		} else {
			warn( "malformed content received in response to api_post:\n".$res->as_string );
			return -EFAULT();
		}
	}
	return 0;
}

sub open {
	my( $path, $flags, $fileinfo ) = shift;
	return 0 unless exists( $pastes{ $path } );
	if( $pastes{ $path }->{ "private" } == 2 ) {
		if( $evil ) {
			return 0;
		}
		return -EPERM();
	}
	return 0;
}

sub read {
	my( $path, $bytes, $offset, $fh ) = @_;
	return -ENOENT() unless exists( $pastes{ $path } );
	return -EFAULT() unless $pastes{ $path }->{ "type" } eq "paste";
	if( exists( $pastes{ $path }->{ "content" } ) && $pastes{ $path }->{ "date" } <= $pastes{ $path }->{ "content_date" } ) {
		return substr $pastes{ $path }->{ "content" }, $offset, $bytes;
	}
	my @parts = split( '/', $path );
	my $filename = pop @parts;
	my $req = HTTP::Request->new(
		GET => "http://pastebin.com/raw.php?i=$filename"
	);
	if( $pastes{ $path }->{ "private" } == 2 ) {
		if( $evil ) {
			$req->header( "Cookie" => "realuser=1; pastebin_user=".$pastebin_session_id );
		} else {
			return -EPERM();
		}
	}
	my $response = $ua->request( $req );
	if( $response->is_success ) {
		$pastes{ $path }->{ "content" } = $response->content;
		$pastes{ $path }->{ "content_date" } = time;
		return substr $response->content, $offset, $bytes;
	} else {
		return -EFAULT();
	}
}

sub pastebinfs_readlink {
	my( $path ) = @_;
	warn( "--> readlink( $path )" ) if $debug;
	unless( exists $pastes{ $path } ) {
		warn( "<-- readlink( $path ) == ENOENT" ) if $debug;
		return -ENOENT();
	}
	unless( $pastes{ $path }->{ "type" } eq "link" ) {
		warn( "<-- readlink( $path ) == EFAULT" ) if $debug;
		return -EFAULT();
	}
	my $ret = $pastes{ $path }->{ "to" };
	$ret =~ s!^/!!;
	warn( "<-- readlink( $path ) == $ret" ) if $debug;
	return $ret;
}

sub readdir {
	my( $path ) = shift;
	return -ENOENT() unless exists $pastes{ $path } && $pastes{ $path }->{ "type" } eq "list";
	return ( ".", "..", @{$pastes{ $path }->{ "pastes" }}, 0 );
}

sub getattr {
	my $path = shift;
	warn( "--> getattr( $path )" ) if $debug;
	list_pastes();
	if( exists $pastes{ $path } ) {
		unless( exists $inodes{ $path } ) {
			$inodes{ $path } = $next_inode++;
		}
		my $mode = 0;
		my $debug_mode;
		my $size = 0;
		my $date = time;
		if( $pastes{ $path }->{ "type" } eq "paste" ) {
			$mode |= S_IFREG;
			$debug_mode = "S_IFREG";
			unless( $pastes{ $path }->{ "private" } == 2 && !$evil ) {
				$mode |= S_IRWXU | S_IRWXO;
				$debug_mode .= " | S_IRWXU | S_IRWXO";
			}
			$size = $pastes{ $path }->{ "size" };
			$date = strtol( $pastes{ $path }->{ "date" }, 10 );
		} elsif( $pastes{ $path }->{ "type" } eq "list" ) {
			$mode |= S_IFDIR | S_IRWXU | S_IRWXO;
			$debug_mode = "S_IFDIR | S_IRWXU | S_IRWXO";
		} elsif( $pastes{ $path }->{ "type" } eq "link" ) {
			$mode |= S_IFLNK | S_IRWXU | S_IRWXO;
			$debug_mode = "S_IFLNK | S_IRWXU | S_IRWXO";
		} else {
			warn "unexpected paste type ".$pastes{ $path }->{ "type" }." for $path";
			warn( "<-- getattr( $path ) == EFAULT" ) if $debug;
			return -EFAULT();
		}
		my @stat = (
				0,            # dev
				$inodes{ $path }, #ino
				$mode,        # mode
				1,            # nlink
				0,            # uid
				0,            # gid
				0,            # rdev
				$size,        # size
				time,         # atime
				$date,        # mtime
				time,         # ctime
				1024,         # blksize
				1             # blocks
		);
		warn( "                mode == ".$debug_mode ) if $debug;
		warn( "<-- getattr( $path ) == ".join( " -- ", @stat ) ) if $debug;
		return @stat;
	}
	warn( "<-- getattr( $path ) == ENOENT" ) if $debug;
	return -ENOENT();
}

sub usage {
#                  --------------------------------------------------------------------------------
	print( STDERR "usage: $0 -a <api-key> -u <username> -p <password> [--evil]\n" );
	print( STDERR "       [--cache|-c <seconds>] [--debug|-d] <mount point>\n" );
	print( STDERR "    -a     You need an API key. Get this from http://pastebin.com/api while\n" );
	print( STDERR "           logged in. You can't have mine. REQUIRED.\n" );
	print( STDERR "    -u     You also need a username. REQUIRED.\n" );
	print( STDERR "    -p     You also need a password. REQUIRED.\n" );
	print( STDERR "    <mount point>  Where to mount the filesystem. REQUIRED.\n\n" );
	print( STDERR "    Optional Options:\n" );
	print( STDERR "    --evil This will use the given username and password to pull an active web\n" );
	print( STDERR "           session. This will log that user out, and probably violate the terms\n" );
	print( STDERR "           of service. This is unfortunately required to be able to view\n" );
	print( STDERR "           private pastes. File modification, though not yet implemented, will\n" );
	print( STDERR "           also unfortunately require Evil Mode.\n" );
	print( STDERR "    --cache, -c <seconds>  Specify the attribute cache time in seconds. The\n" );
	print( STDERR "           default is 30.\n" );
	print( STDERR "    --debug, -d  Enable some call tracing.\n\n" );
	print( STDERR "    WARNING: LOLINSECURITY -- Pastebin works only via HTTP unless you're a Pro\n" );
	print( STDERR "             user. I am not a Pro user, so this only works via HTTP. This means\n" );
	print( STDERR "             your credentials and API key are transmitted in the clear.\n" );
	print( STDERR "\n" );
	print( STDERR "pastebinfs  Copyright (C) 2013  Patrick Bogen\n" );
	print( STDERR "This program comes with ABSOLUTELY NO WARRANTY; for details see README.md\n" );
	print( STDERR "This is free software, and you are welcome to redistribute it\n" );
	print( STDERR "under certain conditions; see LICENSE for details.\n" );
	exit 1;
}

sub list_pastes {
	get_session_key() unless defined $session_key;
	return undef unless defined $session_key;
	return ( keys %pastes, map { $pastes{ $_ }->{ "title" } } keys %pastes ) unless time > ( $pastes_last + $cache );
	%pastes = ( "/" => { "type" => "list", "pastes" => [] } );
	my $req = HTTP::Request->new(
		POST => 'http://pastebin.com/api/api_post.php',
	);
	$req->content_type( 'application/x-www-form-urlencoded' );
	$req->content( join( '&', map { uri_encode( $_ ) } (
		"api_dev_key=$api_key",
		"api_user_key=$session_key",
		"api_option=list",
	) ) );
	my $response = $ua->request( $req );
	if( $response->is_success ) {
		my $parse_state = 0;
		my %paste;
		for my $line ( split( /\n/, $response->content ) ) {
			$line =~ s/[\n\r]//gs;
			if( $line eq "<paste>" ) {
				$parse_state = 1; next;
			} elsif( $line eq "</paste>" ) {
				$pastes{ "/".$paste{ "paste_key" } } = {
					date => $paste{ "paste_date" },
					title => $paste{ "paste_title" },
					size => $paste{ "paste_size" },
					private => $paste{ "paste_private" },
					type => "paste",
				};
				push $pastes{ "/" }->{ "pastes" }, $paste{ "paste_key" };
				unless( $paste{ "paste_title" } eq "Untitled" ) {
					$pastes{ "/".$paste{ "paste_title" } } = {
						to => "/".$paste{ "paste_key" },
						type => "link",
					};
					push $pastes{ "/" }->{ "pastes" }, $paste{ "paste_title" };
				}
				%paste = ();
				$parse_state = 0; next;
			}
			if( $parse_state == 1 ) {
				if( $line =~ /^<([^>]+)>(.*)<\/\1>$/ ) {
					$paste{ $1 } = $2;
				} else {
					warn( "malformed line: $line" );
					next;
				}
			} else {
				warn( "unexpected line: $line" );
				next;
			}
		}
		$pastes_last = time;
		return 0;
	} else {
		print( $response->as_string, "\n" );
		return -EFAULT();
	}
}

sub get_session_key {
	return if defined $session_key;
	my $req = HTTP::Request->new(
		POST => "http://pastebin.com/api/api_login.php"
	);
	$req->content_type( 'application/x-www-form-urlencoded' );
	$req->content( join( '&', map { uri_encode( $_ ) } (
		"api_dev_key=$api_key",
		"api_user_name=$username",
		"api_user_password=$password",
	) ) );
	my $response = $ua->request( $req );
	if( $response->is_success ) {
		$session_key = $response->content;
	} else {
		warn( "couldn't retrieve session ID:\n".$response->content );
		return undef;
	}

	if( $evil ) {
		$req = HTTP::Request->new(
			POST => "http://pastebin.com/login.php"
		);
		$req->content_type( 'application/x-www-form-urlencoded' );
		$req->content( join( '&', map { uri_encode( $_ ) } (
			"submit_hidden=submit_hidden",
			"user_name=$username",
			"user_password=$password",
			"submit=Login"
		) ) );
		$response = $ua->request( $req );
		if( $response->is_success || $response->code == 302) {
			for my $cookie ( $response->header( "Set-cookie" ) ) {
				my @bits = split( /;/, $cookie );
				my( $key, $value ) = split( /=/, $bits[0] );
				if( $key eq "pastebin_user" ) {
					$pastebin_session_id = $value;
					last;
				}
			}
			unless( defined $pastebin_session_id ) {
				warn( "couldn't retrieve pastebin_user session ID:\n".$req->as_string."\n".("-"x80)."\n".$response->as_string );
				return undef;
			}
		} else {
			warn( "couldn't retrieve pastebin_user session ID:\n".$req->as_string."\n".("-"x80)."\n".$response->as_string );
			return undef;
		}
	}
}
