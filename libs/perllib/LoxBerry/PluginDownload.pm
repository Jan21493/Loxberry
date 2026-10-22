package LoxBerry::PluginDownload;

use strict;
use warnings;
use Exporter 'import';
use IPC::Open3;
use Symbol qw(gensym);

our @EXPORT_OK = qw(download_plugin_archive);
our $VERSION = '1.00';

sub download_plugin_archive {
	my ($curl, $url, $destination) = @_;
	my $partial = "$destination.part";
	my $output = gensym;
	my ($input, $pid);
	my $error;

	# Capture diagnostics, not the archive, and never pass the URL through a shell.
	eval {
		$pid = open3($input, $output, $output,
			$curl, '-q', '-fsSLk',
			'--connect-timeout', '20', '--max-time', '1800',
			'--speed-limit', '1024', '--speed-time', '60',
			'--retry', '2', '-o', $partial, '--', $url);
		1;
	} or $error = "Could not start curl: $@";

	if (defined $pid) {
		close $input;
		my $diagnostics = do { local $/; <$output> };
		close $output;
		my $waited = waitpid($pid, 0);
		my $status = $?;
		if ($waited == -1) {
			$error = "Could not wait for curl: $!";
		} elsif ($status != 0) {
			$error = ($status & 127)
				? "curl terminated by signal " . ($status & 127)
				: "curl exited with code " . ($status >> 8);
			$error .= ": $diagnostics" if defined $diagnostics && length $diagnostics;
		} elsif (!-s $partial) {
			$error = "Downloaded archive is empty or missing";
		} elsif (!rename($partial, $destination)) {
			$error = "Could not rename downloaded archive: $!";
		}
	}

	if (defined $error) {
		if (-e $partial && !unlink($partial)) {
			$error .= "; could not remove partial archive: $!";
		}
		return (0, $error);
	}
	return (1, undef);
}

1;

=head1 NAME

LoxBerry::PluginDownload - shared archive download for plugin installs and updates

=head1 DESCRIPTION

download_plugin_archive($curl, $url, $destination) returns (success, error).
Archives are streamed to a .part file and renamed only after curl succeeds.
Each attempt allows 30 minutes, with a 20-second connection timeout and a
60-second low-speed timeout below 1 KiB/s. Transient failures are retried twice.
TLS verification remains disabled for compatibility with existing downloads.
Callers must log errors and must not start installation after a failed download.

=head1 TESTING

Run C<prove libs/perllib/LoxBerry/testing/plugin_download.t> for download,
CGI error handling and status handoff regressions. Set
C<LB_DOWNLOAD_SLOW_TEST=1> to include a 100 MiB transfer taking over 60 seconds.
Run C<node libs/perllib/LoxBerry/testing/plugin_download_status.js> for the
web interface status regressions (no npm dependencies required).

=cut
