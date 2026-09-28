#!/usr/bin/env perl
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_NOFOLLOW O_NONBLOCK O_DIRECTORY S_ISREG);
use File::Basename qw(dirname basename);
use File::Temp qw(tempfile);
use Errno qw(ENOENT EINTR);

# All paths below are relative to a pinned directory handle. A replacement of
# the directory or the final name cannot redirect an operation through a link.
my ($operation, $path, $limit) = @ARGV;
die "invalid operation\n" unless defined $path && ($operation eq 'read' || $operation eq 'write');
$SIG{ALRM} = sub { die "I/O deadline exceeded\n" };
alarm 2;
sysopen(my $directory, dirname($path), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
  or die "cannot open note directory without following links\n";
chdir($directory) or die "cannot enter note directory\n";
my $name = basename($path);
die "invalid filename\n" if $name eq '.' || $name eq '..';

if ($operation eq 'read') {
  die "invalid read limit\n" unless defined $limit && $limit =~ /^\d+$/ && $limit <= 1048576;
  if (!sysopen(my $input, $name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)) {
    if ($! == ENOENT) { print "0 0\n"; exit 0 }
    die "cannot open note without following links\n";
  } else {
    my @info = stat($input);
    die "note is not a regular file\n" unless @info && S_ISREG($info[2]);
    my $data = '';
    while (length($data) < $limit + 1) {
      my $read = sysread($input, my $chunk, $limit + 1 - length($data));
      if (!defined $read) { next if $! == EINTR; die "cannot read note\n" }
      last if $read == 0;
      $data .= $chunk;
    }
    print length($data) . " $info[7]\n";
    print $data if length($data) <= $limit;
  }
} else {
  my @info = lstat($name);
  die "note is not a regular file\n" if @info && !S_ISREG($info[2]);
  die "cannot inspect note\n" if !@info && $! != ENOENT;
  my ($output, $temporary) = tempfile('.seven-XXXXXXXX', DIR => '.', UNLINK => 0);
  # Remove incomplete staging files on ordinary errors and timeout signals.
  my $committed = 0;
  my $cleanup = sub { unlink $temporary unless $committed };
  $SIG{TERM} = sub { $cleanup->(); exit 1 };
  my $ok = eval {
    while (1) {
      my $read = sysread(STDIN, my $chunk, 65536);
      if (!defined $read) { next if $! == EINTR; die "cannot read write payload\n" }
      last if $read == 0;
      my $offset = 0;
      while ($offset < $read) {
        my $written = syswrite($output, $chunk, $read - $offset, $offset);
        if (!defined $written) { next if $! == EINTR; die "cannot write note\n" }
        die "cannot write note\n" if $written == 0;
        $offset += $written;
      }
    }
    chmod($info[2] & 0777, $output) or die "cannot preserve note permissions\n" if @info;
    close($output) or die "cannot close note\n";
    # Recheck to refuse a link/FIFO introduced while receiving the payload.
    # rename itself never opens or follows the destination, including if the
    # name is replaced once more after this check.
    my @current = lstat($name);
    die "note is not a regular file\n" if @current && !S_ISREG($current[2]);
    die "cannot inspect note\n" if !@current && $! != ENOENT;
    rename($temporary, $name) or die "cannot replace note\n";
    $committed = 1;
    1;
  };
  my $error = $@;
  $cleanup->();
  die $error unless $ok;
}
