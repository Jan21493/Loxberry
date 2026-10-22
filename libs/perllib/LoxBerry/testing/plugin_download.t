#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir tempfile);
use FindBin;
use IO::Socket::INET;
use POSIX ();
use Time::HiRes qw(time sleep);
use lib "$FindBin::Bin/../..";
use LoxBerry::PluginDownload qw(download_plugin_archive);

my $dir = tempdir(CLEANUP => 1);
my $fake = "$dir/curl";
open(my $fixture, '>', $fake) or die $!;
print {$fixture} "#!$^X\n", <<'CURL';
use strict;
use warnings;
my @expected = ('-q', '-fsSLk', '--connect-timeout', '20', '--max-time', '1800',
	'--speed-limit', '1024', '--speed-time', '60', '--retry', '2', '-o');
for my $expected (@expected) {
	die "Unexpected curl arguments" unless shift(@ARGV) eq $expected;
}
my $file = shift @ARGV;
die "Missing URL separator" unless shift(@ARGV) eq '--';
my $url = shift @ARGV;
die "URL split into multiple arguments" if @ARGV;
open(my $fh, '>', $file) or die $!;
print {$fh} $url unless $url eq 'empty';
close $fh;
if ($url eq 'fail') {
	print STDERR "download timed out\n";
	exit 28;
}
if ($url eq 'signal') {
	kill 15, $$;
}
CURL
close $fixture;
chmod 0755, $fake or die $!;

my $destination = "$dir/archive.zip";
my $url = "https://example.invalid/a'b?x=1&y=2;touch $dir/injected";
my ($ok, $error) = download_plugin_archive($fake, $url, $destination);
ok($ok, 'download succeeds with expected timeout and retry options');
is($error, undef, 'no error on success');
open(my $archive, '<', $destination) or die $!;
is(do { local $/; <$archive> }, $url, 'URL is passed literally as one argument');
close $archive;
ok(!-e "$dir/injected", 'URL never executes shell commands');
ok(!-e "$destination.part", 'successful download is renamed');

for my $case (
	['fail', qr/code 28.*download timed out/s],
	['empty', qr/empty or missing/],
	['signal', qr/signal 15/],
) {
	my ($ok, $error) = download_plugin_archive($fake, $case->[0], $destination);
	ok(!$ok, "$case->[0] is a download failure");
	like($error, $case->[1], "$case->[0] reports its cause");
	ok(!-e "$destination.part", "$case->[0] removes partial archive");
	open(my $fh, '<', $destination) or die $!;
	is(do { local $/; <$fh> }, $url, 'failed attempt does not overwrite final archive');
	close $fh;
}

($ok, $error) = download_plugin_archive("$dir/missing-curl", 'test', $destination);
ok(!$ok, 'missing curl fails explicitly');
like($error, qr/Could not start curl/, 'spawn failure is diagnosed');
mkdir "$dir/existing-directory" or die $!;
($ok, $error) = download_plugin_archive($fake, 'test', "$dir/existing-directory");
ok(!$ok, 'rename failure prevents success');
like($error, qr/Could not rename/, 'rename failure is diagnosed');
ok(!-e "$dir/existing-directory.part", 'rename failure removes partial archive');

# Exercise the actual status handler, without bootstrapping a LoxBerry system.
my $root = "$FindBin::Bin/../../../..";
open(my $handler, '<', "$root/webfrontend/htmlauth/system/ajax/ajax-config-handler.cgi") or die $!;
my $handler_source = do { local $/; <$handler> };
close $handler;
my ($status_sub) = $handler_source =~ /(sub plugininstall_status\b.*?)(?=\n#{10})/s;
die 'Status handler not found' unless $status_sub;
$status_sub =~ s/\bexit;/return;/g;
my %response;
eval $status_sub;
die $@ if $@;
my ($status_fh, $statusfile) = tempfile('lb-plugin-download-XXXXXX', DIR => '/tmp', UNLINK => 1);
close $status_fh;
unlink $statusfile or die $!;
(my $statusname = $statusfile) =~ s{.*/}{};
{
	no warnings 'once';
	$R::value = $statusname;
}
plugininstall_status();
is($response{error}, -1, 'missing status is an error, not success');
open(my $download_fh, '>', "$statusfile.download") or die $!;
print {$download_fh} '4';
close $download_fh;
plugininstall_status();
is($response{message}, '4', 'download status is returned before installer starts');
open($download_fh, '>', "$statusfile.download") or die $!;
print {$download_fh} '1';
close $download_fh;
open(my $install_fh, '>', $statusfile) or die $!;
print {$install_fh} '0';
close $install_fh;
plugininstall_status();
is($response{message}, '1', 'CGI keeps installation pending until the installer exits');
open($download_fh, '>', "$statusfile.download") or die $!;
print {$download_fh} '2';
close $download_fh;
plugininstall_status();
is($response{message}, '2', 'CGI can report failure without overwriting root-owned installer status');
unlink "$statusfile.download" or die $!;
plugininstall_status();
is($response{message}, '0', 'installer result is used after CGI releases its status file');
unlink $statusfile or die $!;

# Run the actual CGI child with a fake installer, never sudo or a real installation.
open(my $cgi_fh, '<', "$root/webfrontend/htmlauth/system/plugininstall.cgi") or die $!;
my $cgi_source = do { local $/; <$cgi_fh> };
close $cgi_fh;
my ($child_source) = $cgi_source =~ /if \(\$pid == 0\) \{(.*?)\n\s*\} # End Child process/s;
die 'CGI child not found' unless $child_source;
open(my $sudo, '>', "$dir/sudo") or die $!;
print {$sudo} "#!$^X\n", <<'INSTALLER';
use strict;
use warnings;
open(my $marker, '>', $ENV{INSTALLER_MARKER}) or die $!;
print {$marker} join("\n", @ARGV);
close $marker;
print "fake installer output\n";
exit($ENV{INSTALLER_EXIT} || 0);
INSTALLER
close $sudo;
chmod 0755, "$dir/sudo" or die $!;
my $runner = "$dir/cgi-child.pl";
open(my $runner_fh, '>', $runner) or die $!;
print {$runner_fh} <<'RUNNER', $child_source;
use strict;
use warnings;
use IO::Handle;
use LoxBerry::PluginDownload qw(download_plugin_archive);
sub LoxBerry::System::currtime {
	die 'Unexpected timestamp format' unless $_[0] eq 'hrtimehires';
	return '12:34:56.789';
}
sub LoxBerry::System::write_file {
	my ($path, $content) = @_;
	open(my $fh, '>', $path) or return "$!";
	print {$fh} $content or return "$!";
	close $fh or return "$!";
	return '';
}
my ($archiveurl, $tempfile, $uploadpath, $curl, $downloadstatus) = @ARGV;
my $bins = { CURL => $curl };
my $lbhomedir = '/fake-loxberry';
my $securepin = '1234';
RUNNER
close $runner_fh;
for my $case (['fail', 0], ['success', 0], ['success', 7]) {
	my ($token_fh, $token_path) = tempfile('lb-plugin-child-XXXXXX', DIR => '/tmp', UNLINK => 1);
	close $token_fh;
	(my $token = $token_path) =~ s{.*/}{};
	my $downloadstatus = "$token_path.status.download";
	my $marker = "$dir/installer-marker";
	unlink $marker if -e $marker;
	local $ENV{PATH} = "$dir:$ENV{PATH}";
	local $ENV{PERL5LIB} = "$FindBin::Bin/../..";
	local $ENV{INSTALLER_MARKER} = $marker;
	local $ENV{INSTALLER_EXIT} = $case->[1];
	system($^X, $runner, $case->[0], $token, $dir, $fake, $downloadstatus);
	my $child_status = $? >> 8;
	is($child_status, ($case->[0] eq 'fail' || $case->[1]) ? 1 : 0,
		"CGI child exits correctly for download=$case->[0], installer=$case->[1]");
	is(-e $marker ? 1 : 0, $case->[0] eq 'fail' ? 0 : 1,
		'CGI starts installer only after a successful download');
	if ($child_status) {
		open(my $fh, '<', $downloadstatus) or die $!;
		is(do { local $/; <$fh> }, '2', 'CGI publishes terminal error status');
		close $fh;
		unlink $downloadstatus or die $!;
	} else {
		ok(!-e $downloadstatus, 'CGI releases status file after successful installation');
	}
	open(my $log_fh, '<', "$token_path.log") or die $!;
	my $contents = do { local $/; <$log_fh> };
	close $log_fh;
	my @messages = grep { /<(?:INFO|ERROR)>/ } split /\n/, $contents;
	ok(@messages && !grep(!/^\d{2}:\d{2}:\d{2}\.\d{3} <(?:INFO|ERROR)> /, @messages),
		'CGI messages use the same millisecond timestamp column as installer logs');
	if ($case->[0] eq 'fail') {
		like($contents, qr/code 28.*download timed out/s, 'CGI logs curl diagnostics');
		ok(!-e "$dir/$token.zip", 'CGI does not publish a failed download');
	} else {
		like($contents, qr/Archive download completed.*fake installer output/s,
			'CGI keeps download and installer output in the same log');
		unlink "$dir/$token.zip" or die $!;
	}
	unlink "$token_path.log" or die $!;
}

SKIP: {
	my $curl = $ENV{CURL} || '/usr/bin/curl';
	skip 'curl is unavailable', 12 unless -x $curl;
	my $server = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, ReuseAddr => 1,
	) or die $!;
	my $port = $server->sockport;
	my $server_pid = fork();
	die $! unless defined $server_pid;
	if (!$server_pid) {
		$SIG{PIPE} = 'IGNORE';
		my $transient_requests = 0;
		while (my $client = $server->accept) {
			$client->autoflush(1);
			my $request = <$client>;
			while (my $line = <$client>) { last if $line eq "\r\n"; }
			my ($path) = $request =~ m{GET (\S+)};
			if ($path eq '/redirect') {
				print {$client} "HTTP/1.1 302 Found\r\nLocation: /large\r\nContent-Length: 0\r\n\r\n";
			} elsif ($path eq '/missing') {
				print {$client} "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
			} elsif ($path eq '/truncated') {
				print {$client} "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort";
			} elsif ($path eq '/transient') {
				if (++$transient_requests == 1) {
					print {$client} "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n";
				} else {
					print {$client} "HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\narchive";
				}
			} else {
				print {$client} "HTTP/1.1 200 OK\r\nContent-Length: 104857600\r\n\r\n";
				for (1..100) {
					last unless print {$client} 'x' x (1024 * 1024);
					sleep 0.65 if $ENV{LB_DOWNLOAD_SLOW_TEST};
				}
			}
			close $client;
		}
		POSIX::_exit(0);
	}
	close $server;
	my $start = time;
	($ok, $error) = download_plugin_archive($curl, "http://127.0.0.1:$port/redirect", "$dir/large.zip");
	my $elapsed = time - $start;
	ok($ok, 'real curl follows redirects and downloads a 100 MiB archive') or diag($error);
	is(-s "$dir/large.zip", 104857600, 'entire 100 MiB archive is written to disk');
	ok(!-e "$dir/large.zip.part", 'real curl publishes only the completed archive');
	if ($ENV{LB_DOWNLOAD_SLOW_TEST}) {
		cmp_ok($elapsed, '>', 60, '100 MiB transfer succeeds beyond the old 60-second limit');
	} else {
		pass('set LB_DOWNLOAD_SLOW_TEST=1 to exercise a transfer exceeding 60 seconds');
	}
	for my $case (['missing', 22], ['truncated', 18]) {
		($ok, $error) = download_plugin_archive($curl, "http://127.0.0.1:$port/$case->[0]", "$dir/$case->[0].zip");
		ok(!$ok, "real curl rejects $case->[0] response");
		like($error, qr/code $case->[1]/, "real curl reports $case->[0] exit code");
	}
	ok(!-e "$dir/truncated.zip.part", 'real truncated download is removed');
	($ok, $error) = download_plugin_archive($curl, "http://127.0.0.1:$port/transient", "$dir/retry.zip");
	ok($ok, 'real curl retries a transient HTTP 503') or diag($error);
	is($error, undef, 'successful retry does not report a terminal error');
	is(-s "$dir/retry.zip", 7, 'successful retry publishes the complete response');
	kill 'TERM', $server_pid;
	waitpid($server_pid, 0);
}

done_testing();
