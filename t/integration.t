#!perl -w
# Copyright (C) unicorn hackers <unicorn-public@yhbt.net>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>

# This is the main integration test for fast-ish things to minimize
# Ruby startup time penalties.

use v5.14; BEGIN { require './t/lib.perl' };
use autodie;
our $srv = tcp_server();
our $host_port = tcp_host_port($srv);
my $t0 = time;
my $conf = "$tmpdir/u.conf.rb";
open my $conf_fh, '>', $conf;
$conf_fh->autoflush(1);
my $u1 = "$tmpdir/u1";
print $conf_fh <<EOM;
early_hints true
listen "$u1"
EOM
my $ar = unicorn(qw(-E none t/integration.ru -c), $conf, { 3 => $srv });
my $curl = which('curl');
my $fifo = "$tmpdir/fifo";
POSIX::mkfifo($fifo, 0600) or die "mkfifo: $!";
my %PUT = (
	chunked_md5 => sub {
		my ($in, $out, $path, %opt) = @_;
		my $dig = Digest::MD5->new;
		print $out <<EOM;
PUT $path HTTP/1.1\r
Transfer-Encoding: chunked\r
Trailer: Content-MD5\r
\r
EOM
		my ($buf, $r);
		while (1) {
			$r = read($in, $buf, 999 + int(rand(0xffff)));
			last if $r == 0;
			printf $out "%x\r\n", length($buf);
			print $out $buf, "\r\n";
			$dig->add($buf);
		}
		print $out "0\r\nContent-MD5: ", $dig->b64digest, "\r\n\r\n";
	},
	identity => sub {
		my ($in, $out, $path, %opt) = @_;
		my $clen = $opt{-s} // -s $in;
		print $out <<EOM;
PUT $path HTTP/1.0\r
Content-Length: $clen\r
\r
EOM
		my ($buf, $r, $len, $bs);
		while ($clen) {
			$bs = 999 + int(rand(0xffff));
			$len = $clen > $bs ? $bs : $clen;
			$r = read($in, $buf, $len);
			die 'premature EOF' if $r == 0;
			print $out $buf;
			$clen -= $r;
		}
	},
);

my ($c, $status, $hdr);

# response header tests
$c = tcp_start($srv, 'GET /rack-2-newline-headers HTTP/1.0');
($status, $hdr) = slurp_hdr($c);
like($status, qr!\AHTTP/1\.[01] 200\b!, 'status line valid');
my $orig_200_status = $status;
is_deeply([ grep(/^X-R2: /, @$hdr) ],
	[ 'X-R2: a', 'X-R2: b', 'X-R2: c' ],
	'rack 2 LF-delimited headers supported') or diag(explain($hdr));

SKIP: { # Date header check
	my @d = grep(/^Date: /i, @$hdr);
	is(scalar(@d), 1, 'got one date header') or diag(explain(\@d));
	eval { require HTTP::Date } or skip "HTTP::Date missing: $@", 1;
	$d[0] =~ s/^Date: //i or die 'BUG: did not strip date: prefix';
	my $t = HTTP::Date::str2time($d[0]);
	ok($t >= $t0 && $t > 0 && $t <= time, 'valid date') or
		diag(explain([$t, $!, \@d]));
};


$c = tcp_start($srv, 'GET /rack-3-array-headers HTTP/1.0');
($status, $hdr) = slurp_hdr($c);
is_deeply([ grep(/^x-r3: /, @$hdr) ],
	[ 'x-r3: a', 'x-r3: b', 'x-r3: c' ],
	'rack 3 array headers supported') or diag(explain($hdr));

SKIP: {
	eval { require JSON::PP } or skip "JSON::PP missing: $@", 1;
	my $c = tcp_start($srv, 'GET /env_dump');
	my $json = do { local $/; readline($c) };
	unlike($json, qr/^Connection: /smi, 'no connection header for 0.9');
	unlike($json, qr!\AHTTP/!s, 'no HTTP/1.x prefix for 0.9');
	my $env = JSON::PP->new->decode($json);
	is(ref($env), 'HASH', 'JSON decoded body to hashref');
	is($env->{SERVER_PROTOCOL}, 'HTTP/0.9', 'SERVER_PROTOCOL is 0.9');
}

# cf. <CAO47=rJa=zRcLn_Xm4v2cHPr6c0UswaFC_omYFEH+baSxHOWKQ@mail.gmail.com>
$c = tcp_start($srv, 'GET /nil-header-value HTTP/1.0');
($status, $hdr) = slurp_hdr($c);
is_deeply([grep(/^X-Nil:/, @$hdr)], ['X-Nil: '],
	'nil header value accepted for broken apps') or diag(explain($hdr));

my $ck_early_hints = sub {
	my ($note) = @_;
	$c = unix_start($u1, 'GET /early_hints_rack2 HTTP/1.0');
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 103\b!, 'got 103 for rack 2 value');
	is_deeply(['link: r', 'link: 2'], $hdr, 'rack 2 hints match '.$note);
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 200\b!, 'got 200 afterwards');
	is(readline($c), 'String', 'early hints used a String for rack 2');

	$c = unix_start($u1, 'GET /early_hints_rack3 HTTP/1.0');
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 103\b!, 'got 103 for rack 3');
	is_deeply(['link: r', 'link: 3'], $hdr, 'rack 3 hints match '.$note);
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 200\b!, 'got 200 afterwards');
	is(readline($c), 'Array', 'early hints used a String for rack 3');
};
$ck_early_hints->('ccc off'); # we'll retest later

if ('TODO: ensure Rack::Utils::HTTP_STATUS_CODES is available') {
	$c = tcp_start($srv, 'POST /tweak-status-code HTTP/1.0');
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 200 HI\b!, 'status tweaked');

	$c = tcp_start($srv, 'POST /restore-status-code HTTP/1.0');
	($status, $hdr) = slurp_hdr($c);
	is($status, $orig_200_status, 'original status restored');
}

SKIP: {
	eval { require HTTP::Tiny } or skip "HTTP::Tiny missing: $@", 1;
	my $ht = HTTP::Tiny->new;
	my $res = $ht->get("http://$host_port/write_on_close");
	is($res->{content}, 'Goodbye', 'write-on-close body read');
}

if ('bad requests') {
	$c = tcp_start($srv, 'GET /env_dump HTTP/1/1');
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 400 \b!, 'got 400 on bad request');

	$c = tcp_start($srv);
	print $c 'GET /';;
	my $buf = join('', (0..9), 'ab');
	for (0..1023) { print $c $buf }
	print $c " HTTP/1.0\r\n\r\n";
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 414 \b!,
		'414 on REQUEST_PATH > (12 * 1024)');

	$c = tcp_start($srv);
	print $c 'GET /hello-world?a';
	$buf = join('', (0..9));
	for (0..1023) { print $c $buf }
	print $c " HTTP/1.0\r\n\r\n";
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 414 \b!,
		'414 on QUERY_STRING > (10 * 1024)');

	$c = tcp_start($srv);
	print $c 'GET /hello-world#a';
	$buf = join('', (0..9), 'a'..'f');
	for (0..63) { print $c $buf }
	print $c " HTTP/1.0\r\n\r\n";
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 414 \b!, '414 on FRAGMENT > (1024)');
}

# input tests
my ($blob_size, $blob_hash);
SKIP: {
	skip 'SKIP_EXPENSIVE on', 1 if $ENV{SKIP_EXPENSIVE};
	CORE::open(my $rh, '<', 't/random_blob') or
		skip "t/random_blob not generated $!", 1;
	$blob_size = -s $rh;
	require Digest::MD5;
	$blob_hash = Digest::MD5->new->addfile($rh)->hexdigest;

	my $ck_hash = sub {
		my ($sub, $path, %opt) = @_;
		seek($rh, 0, SEEK_SET);
		$c = tcp_start($srv);
		$c->autoflush($opt{sync} // 0);
		$PUT{$sub}->($rh, $c, $path, %opt);
		defined($opt{overwrite}) and
			print { $c } ('x' x $opt{overwrite});
		$c->flush or die $!;
		($status, $hdr) = slurp_hdr($c);
		is(readline($c), $blob_hash, "$sub $path");
	};
	$ck_hash->('identity', '/rack_input', -s => $blob_size);
	$ck_hash->('chunked_md5', '/rack_input');
	$ck_hash->('identity', '/rack_input/size_first', -s => $blob_size);
	$ck_hash->('identity', '/rack_input/rewind_first', -s => $blob_size);
	$ck_hash->('chunked_md5', '/rack_input/size_first');
	$ck_hash->('chunked_md5', '/rack_input/rewind_first');

	$ck_hash->('identity', '/rack_input', -s => $blob_size, sync => 1);
	$ck_hash->('chunked_md5', '/rack_input', sync => 1);

	# ensure small overwrites don't get checksummed
	$ck_hash->('identity', '/rack_input', -s => $blob_size,
			overwrite => 1); # one extra byte

	# excessive overwrite truncated
	$c = tcp_start($srv);
	$c->autoflush(0);
	print $c "PUT /rack_input HTTP/1.0\r\nContent-Length: 1\r\n\r\n";
	if (1) {
		local $SIG{PIPE} = 'IGNORE';
		my $buf = "\0" x 8192;
		my $n = 0;
		my $end = time + 5;
		$! = 0;
		while (print $c $buf and time < $end) { ++$n }
		ok($!, 'overwrite truncated') or diag "n=$n err=$! ".time;
	}
	undef $c;

	$curl // skip 'no curl found in PATH', 1;

	my ($copt, $cout);
	my $url = "http://$host_port/rack_input";
	my $do_curl = sub {
		my (@arg) = @_;
		pipe(my $cout, $copt->{1});
		open $copt->{2}, '>', "$tmpdir/curl.err";
		my $cpid = spawn($curl, '-sSf', @arg, $url, $copt);
		close(delete $copt->{1});
		is(readline($cout), $blob_hash, "curl @arg response");
		is(waitpid($cpid, 0), $cpid, "curl @arg exited");
		is($?, 0, "no error from curl @arg");
		is(slurp("$tmpdir/curl.err"), '', "no stderr from curl @arg");
	};

	$do_curl->(qw(-T t/random_blob));

	seek($rh, 0, SEEK_SET);
	$copt->{0} = $rh;
	$do_curl->('-T-');

	diag 'testing Unicorn::PrereadInput...';
	local $srv = tcp_server();
	local $host_port = tcp_host_port($srv);
	check_stderr;
	truncate($errfh, 0);

	my $pri = unicorn(qw(-E none t/preread_input.ru), { 3 => $srv });
	$url = "http://$host_port/";

	$do_curl->(qw(-T t/random_blob));
	seek($rh, 0, SEEK_SET);
	$copt->{0} = $rh;
	$do_curl->('-T-');

	my @pr_err = slurp("$tmpdir/err.log");
	is(scalar(grep(/app dispatch:/, @pr_err)), 2, 'app dispatched twice');

	# abort a chunked request by blocking curl on a FIFO:
	$c = tcp_start($srv, "PUT / HTTP/1.1\r\nTransfer-Encoding: chunked");
	close $c;
	@pr_err = slurp("$tmpdir/err.log");
	is(scalar(grep(/app dispatch:/, @pr_err)), 2,
			'app did not dispatch on aborted request');
	undef $pri;
	check_stderr;
	diag 'Unicorn::PrereadInput middleware tests done';
}

# ... more stuff here

# SIGHUP-able stuff goes here

if ('check_client_connection') {
	print $conf_fh <<EOM; # appending to existing
check_client_connection true
after_fork { |_,_| File.open('$fifo', 'w') { |fp| fp.write "pid=#\$\$" } }
EOM
	$ar->do_kill('HUP');
	open my $fifo_fh, '<', $fifo;
	my $wpid = readline($fifo_fh);
	like($wpid, qr/\Apid=\d+\z/a , 'new worker ready');
	$ck_early_hints->('ccc on');
}

if ('max_header_len internal API') {
	undef $c;
	my $req = 'GET / HTTP/1.0';
	my $len = length($req."\r\n\r\n");
	print $conf_fh <<EOM; # appending to existing
Unicorn::HttpParser.max_header_len = $len
EOM
	$ar->do_kill('HUP');
	open my $fifo_fh, '<', $fifo;
	my $wpid = readline($fifo_fh);
	like($wpid, qr/\Apid=\d+\z/a , 'new worker ready');
	close $fifo_fh;
	$wpid =~ s/\Apid=// or die;
	ok(CORE::kill(0, $wpid), 'worker PID retrieved');

	$c = tcp_start($srv, $req);
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 200\b!, 'minimal request succeeds');

	$c = tcp_start($srv, 'GET /xxxxxx HTTP/1.0');
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 413\b!, 'big request fails');
}


undef $ar;

check_stderr;

undef $tmpdir;
done_testing;
