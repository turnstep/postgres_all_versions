#!/usr/bin/perl

use strict;
use warnings;
use LWP::UserAgent;
use Data::Dumper;
use Getopt::Long qw/ GetOptions /;

our $VERSION = '1.15';

my $USAGE = "$0 [--noindexcache] [--nocache] [--verbose]";

my $EOLURL = 'https://www.postgresql.org/support/versioning/';
my $EOL = '9.2';
my $EOLPLUS = '9.3';

my %opt;
GetOptions(
    \%opt,
    'noindexcache',
    'nocache',
    'verbose',
    'help',
);
if ($opt{help}) {
    print "$USAGE\n";
    exit 0;
}

my $verbose = $opt{verbose} || 0;
my $cachedir = '/tmp/cache';
my $index = 'http://www.postgresql.org/docs/current/static/release.html';
my $baseurl = 'http://www.postgresql.org/docs/current/static';

my $pagecache = {};

my $ua = LWP::UserAgent->new;
$ua->agent("GSM/$VERSION");

my $content = fetch_page($index);

my $total = 0;
my $bigpage = "$cachedir/postgres_all_versions.html";
open my $fh, '>', $bigpage or die qq{Could not open "$bigpage": $!\n};
print {$fh} qq{<html>

<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<style><!--
span.gsm_v { color: #990000; font-family: monospace;}
span.gsm_nowrap { white-space: nowrap;}
table td.eol { color: #111111; font-size: smaller; }
span.eol { color: #dd0000 }
--></style>
<title>Postgres Release Notes - All Versions</title>
</head>
<body>
};

my @pagelist;

## Each bulleted item may be in more than one version!
my %bullet;
## When it was released
my %versiondate;
## First run to gather version information
while ($content =~ m{a href="(release.*?)">(.+?)</a>}gs) {
	my ($page,$title) = ($1,$2);
	$title =~ s/\s+/ /;
	my $version = '?';
	if ($title =~ s/.*(Release)\s+([\d\.]+)$/$1 $2/) {
		$version = $2;
	}
	else {
		die "No release found for page ($page) and title ($title)\n";
	}
	#print "GOT $page and $title\n";
	(my $pageurl = $index) =~ s/release.html/$page/;
	my $pageinfo = fetch_page($pageurl);
	$total++;

	push @pagelist => [$page, $title, $pageurl, $version, $pageinfo];

	while ($pageinfo =~ m{<li>\s*<p>(.+?)</li>}sg) {
		my $blurb = $1;
		push @{$bullet{$blurb}} => $version;
	}

	## Gather the release date for each version

    my $founddate = 0;
    if ($pageinfo =~ /Release date:\D+(\d\d\d\d\-\d\d\-\d\d)/) {
        $versiondate{$version} = $1;
        $verbose and warn "Found $version as $1\n";
        $founddate = 1;
    }
    elsif ($pageinfo =~ m{Release date:.+(never released)}) {
        $versiondate{$version} = $1;
        $verbose and warn "Version $version never released\n";
        $founddate = 1;
    }
    if (!$founddate) {
        die "No date found for version $title at page $page!\n";
    }
}


my $date = qx{date +"%B %d, %Y"};
chomp $date;

my $oldselect = select $fh;
print qq{
<h1>Postgres Changelog - All Versions</h1>

<p>This is a complete, one-page listing of changes across all Postgres versions. All versions $EOL and older are EOL (<a href="$EOLURL">end of life</a>) and unsupported. This page was generated on $date and contains information for $total versions of Postgres. This is version $VERSION, and was created by Greg Sabino Mullane.</p>

};


## Table of Contents
print "<table border=1>\n";
my $COLS = 6;
my $startrow=1;
my $startcell=1;
my $oldmajor = 0;
my $highversion = 1.0;
my $highrevision = 0;
my $revision = 0;
my $seeneol = 0;
my $oldfirstnum = 10;
my %version_is_eol;
for my $row (@pagelist) {
	my ($page,$title,$url,$version,$data) = @$row;
    my $major = 0;
    my $firstnum = 0;
    ## Version is x.y or x.y.z or x or x.z
    if ($version =~ /^\d\d+$/) { ## Major version 10 or higher
        $major = $firstnum = $version;
        $revision = 0;
    }
    elsif ($version =~ /^(\d\d+)\.(\d+)$/) { ## Major version 10 or higher, plus revision
        $major = $firstnum = $1;
        $revision = $2;
        $revision < 1 and die "Why is revision 0 of $version showing??";
    }
    elsif ($version =~ /^(\d)\.\d+$/) { ## Major version < 10
        $firstnum = $1;
        $major = $version;
        $revision = 0;
    }
    elsif ($version =~ /^((\d)\.\d+)\.(\d+)$/) { ## Major version < 10, plus revision
        $major = $1;
        $firstnum = $2;
        $revision = $3;
        $revision < 1 and die "Why is revision 0 of $version showing??";
    }
    else {
        die "Could not parse version '$version'";
    }

    if ($major >= $highversion) {
        $highversion = $major;
        if ($revision > $highrevision) {
            $highrevision = $revision;
        }
    }

    ## Are we at the start of a row, or at the start of a cell?
    my ($startrow,$startcell) = (0,0);

    ## Store EOL flag for later
    $version_is_eol{$version} = $major <= $EOL ? 1 : 0;

    ## We start a new row for EOL, and for first-number change
    if (!$seeneol and $major <= $EOL) {
        $seeneol = 1;
        $startrow = 1;
        $oldfirstnum = $firstnum;
    }
    elsif ($seeneol and $oldfirstnum != $firstnum and $firstnum >= 6) {
        $oldfirstnum = $firstnum;
        $startrow = 1;
    }

    ## We start a new row if the major has changed, except for super-old stuff
    if ($startrow or $oldmajor != $major and $major >= 6) {
        $oldmajor = $major;
        $startcell = 1;
    }

    if ($startrow) {
        ## Close old row if needed
        if ($major != $highversion) {
            print "</tr>\n";
        }
        print "<tr>\n";
    }

    if ($startcell) {
        ## Close old cell if needed
        if ($major != $highversion) {
            print "</td>\n";
        }
        my $showver = $major;
        my $span = 1;
        ## Last one before EOL
        if ($major eq $EOLPLUS) {
            $span = 2;
        }
        elsif (9.0 == $major) {
            $span = 4;
        }
        elsif (8.0 == $major or 7.0 == $major) {
            $span = 2;
        }
        if ($major eq '6.0') {
            $showver = '6.0<br>and earlier...';
            $span = 3;
        }
		printf " <td colspan=%s valign=top%s><b>Postgres %s%s</b>\n",
            $span,
                $seeneol ? ' class="eol"' : '',
                    $showver,
                        $major <= $EOL ? ' <br><span class="eol">(end of life)</span>' : '';
    }

    die "No version date found for $version!\n" if ! $versiondate{$version};
	printf qq{<br><span class="gsm_nowrap"><a href="#version_%s">%s</a> (%s)</span>\n},
		$version,
			($revision>=1 ? $version : qq{<b>$version</b>}),
				$versiondate{$version} =~ /never/ ? "<em>never released!</em>" : "$versiondate{$version}";
	$oldmajor = $major;
}
print "</table>";
print STDOUT "Highest version: $highversion (revision $highrevision)\n";

my $names = 0;
my %namesmatch;
my %fail;

my $totalfail=0;

for my $row (@pagelist) {
	my ($page,$title,$url,$version,$data) = @$row;

    ## Old style:
 	$data =~ s{.*?(<div class="SECT1")}{$1}s;
	$data =~ s{<div class="NAVFOOTER".+}{}s;

    ## New as of version 10:
    $data =~ s{.*(<p><strong>Release date)}{$1}s;
	$data =~ s{<div class="navfooter".+}{}s;

	## Add pretty version information for each bullet
	$data =~ s{<li>\s*<p>(.+?)</li>}{
		my $blurb = $1;
		die "Mismatch blurb!!" if ! exists $bullet{$blurb};
		my $pversion = join ',' => @{ $bullet{$blurb} };
		die "Another version mismatch!\n" if $pversion !~ /\b$version\b/;
		$pversion =~ s{(\b)$version,?}{$1};
		$pversion = sprintf '<b>%s</b>%s%s', $version, ($pversion =~ /\d/ ? ',' : ''), $pversion;
		$pversion =~ s/,$//;
		"<li><p><span class='gsm_v'>($pversion) </span>$blurb</li>"
	}sgex;

	## Remove mailtos
	$data =~ s{<a href=\s*"mailto:.+?">(.+?)</a>}{$1}gs;

	## Put Postgres in the version title (no longer there!)
	## $data =~ s{Release (\S+)}{Postgres version $1};

	## Drop the headers down a level
	$data =~ s{<h4}{<h5}sg;	$data =~ s{</h4>}{</h5>}sg;
	$data =~ s{<h3}{<h4}sg;	$data =~ s{</h3>}{</h4>}sg;
	$data =~ s{<h2}{<h3}sg;	$data =~ s{</h2>}{</h3>}sg;
	$data =~ s{<h1}{<h2}sg;	$data =~ s{</h1>}{</h2>}sg;

	## Remove all the not important "E-dot" stuff
	$data =~ s{>E\.[\d+\.]+\s*}{>}gsm;

	## Add a header for quick jumping
	print qq{<a name="version_$version"></a>\n};

	## Redirect internal version links
	## <a href="release-9-3-5.html">Section E.4</a>
	$data =~ s{href=\s*"release-([\d\-]+)\.html">Section.*?</a>}{
		(my $ver = $1) =~ s/\-/./g;
		qq{href="#version_$ver">Version $ver</a>}
	}gmsex;

	## Redirect simple links
	## <a href="postgres-fdw.html"><span class=
	$data =~ s{href=\s*"(.+?)"}{href="$baseurl/$1"}g;

	## LINK CVE notices
	my $mitre = 'https://cve.mitre.org/cgi-bin/cvename.cgi?name=';
	my $redhat = 'https://access.redhat.com/security/cve';

	$data =~ s{(CVE-[\d\-]+)}{<a href="$mitre$1">$1</a> or <a href="$redhat/$1">$1</a>}g;

	## Put spaces before some parens
	$data =~ s{(...\w)\(([A-Z]...)}{$1 ($2}g;

	## Expand some names
my $namelist = q{
Adrian      : Adrian Hall
Aldrin      : Aldrin Leal
Alfred      : Alfred Perlstein
Alvaro      : Alvaro Herrera
Anand       : Anand Surelia
Anders      : Anders Hammarquist
Andreas     : Andreas Zeugswetter
Andrew      : Andrew Dunstan
Barry       : Barry Lind
Billy       : Billy G. Allie
Brook       : Brook Milligan
Bruce       : Bruce Momjian
Bryan       : Bryan Henderson
Bryan?      : Bryan Henderson
Byron       : Byron Nikolaidis
Christof    : Christof Petig
Christopher : Christopher Kings-Lynne
Claudio     : Claudio Natoli
Constantin  : Constantin Teodorescu
Dan         : Dan McGuirk
Darcy       : D'Arcy J.M. Cain
D'Arcy      : D'Arcy J.M. Cain
Darren      : Darren King
Dave        : Dave Cramer
David       : David Hartwig
Edmund      : Edmund Mergl
Erich       : Erich Stamberger
Fabien      : Fabien Coelho
Frankpitt   : Bernard Frankpitt
Gavin       : Gavin Sherry
Giles       : Giles Lean
Goran       : Goran Thyni
Heikki      : Heikki Linnakangas
Heiko       : Heiko Lehmann
Henry       : Henry B. Hotz
Hiroshi     : Hiroshi Inoue
Igor        : Igor Natanzon
Jacek       : Jacek Lasecki
James       : James Hughes
Jan         : Jan Wieck
Jeroen      : Jeroen van Vianen
Joe         : Joe Conway
Jun         : Jun Kuwamura
Karel       : Karel Zak
Kataoka     : Hiroki Kataoka
Keith       : Keith Parks
Kurt        : Kurt Lidl
Leo         : Leo Shuster
Maarten     : Maarten Boekhold
Magnus      : Magnus Hagander
Marc        : Marc Fournier
Mark        : Mark Hollomon
Martin      : Martin Pitt
Massimo     : Massimo Dal Zotto
Matt        : Matt Maycock
Maurizio    : Maurizio Cauci
Michael     : Michael Meskes
Neil        : Neil Conway
Oleg        : Oleg Bartunov
Oliver      : Oliver Elphick
Pascal      : Pascal André
Patrice     : Patrice Hédé
Patrick     : Patrick van Kleef
Paul        : Paul M. Aoki
Peter E     : Peter Eisentraut
Peter       : Peter T. Mount
Philip      : Philip Warner
Phil        : Phil Thompson
Raymond     : Raymond Toy
Rod         : Rod Taylor
Ross        : Ross J. Reedstrom
Ryan        : Ryan Bradetich : view|varchar
Ryan        : Ryan Kirkpatrick : Solaris|Alpha
Simon       : Simon Riggs
Stan        : Stan Brown
Stefan      : Stefan Simkovics
Stephan     : Stephan Szabo
Sven        : Sven Verdoolaege
Tatsuo      : Tatsuo Ishii
Teodor      : Teodor Sigaev
Terry       : Terry Mackintosh
Thomas      : Thomas Lockhart
Todd        : Todd A. Brandys
TomH        : Tom I. Helbekkmo
TomS        : Tom Szybist
Tom         : Tom Lane
Travis      : Travis Melhiser
Vadim       : Vadim Mikheev
Vadmin      : Vadim Mikheev
Vince       : Vince Vielhaber
Zeugswetter : Andreas Zeugswetter
Zeugswetter Andres : Andreas Zeugswetter

};


## RYAN! Ryan is Ryan Bradetich &lt;<A HREF="mailto:rbrad@hpb50023.boi.hp.com">
## Ryan        : Ryan Kirkpatrick

## alpha and solaris are Kirk
## psql charlen is from Date:   Sun Mar 14 05:23:12 1999 +0000
## psql show view is Date:   Mon Mar 15 02:18:37 1999 +0000
## Gonna call them Ryan B.

##Peter       : Peter Eisentraut
##Peter       : Peter Mount

## Clark (fix tutorial code) - unknown!
## Keith - Parks I guess but no proof!
## Todd- the system password file (Todd)
##  Todd is Todd A. Brandys http://markmail.org/thread/mkq6by6r2sspnixm#query:+page:1+mid:mkq6by6r2sspnixm+state:results


# Stefan Simkovics: http://www.postgresql.org/message-id/199901180007.TAA22295@candle.pha.pa.us
# Heiko Lehmann: http://www.postgresql.org/message-id/Pine.LNX.4.21.0202221131420.13849-100000@lukas.fh-lausitz.de
# Anand:  http://www.postgresql.org/message-id/3606A390.4C492BCF@bytekinc.com
# Maurizio Cauci: http://www.postgresql.org/message-id/001b01c0bf6f$bcf19d40$7394fea9@maurizio

## Paul ?


	for (split /\n/ => $namelist) {
		next if ! /\w/;
		die "Invalid line: $_\n" if ! /^([A-Z][\w \?']+?)\s+:\s+([A-Z][\wé\.\-\' ]+?)(\s*:.+)?$/;
		my ($short,$long,$extra) = ($1,$2,$3||'');
		my $count = 0;
		$extra =~ s/^\s*:\s*//;
		if ($extra) {
			$extra = qr{$extra};
			$count += $data =~ s{($extra[\w\d\.\(\) ]+?\([\w ,]*)\Q$short\E([,\)])}{$1$long$2}g;
		}
		else {
			$count += $data =~ s{(\W)\Q$short\E([,\)])}{$1$long$2}g;
			## Special case for Vadim &amp; Erich
			$count += $data =~ s{\(\Q$short\E &amp;}{($long &amp;}g;
			$count += $data =~ s{&amp; \Q$short\E\)}{(&amp; $long)}g;
		}
		$namesmatch{$short} += $count;
		$names += $count;
	}
	## Gregs:
	for my $string ("8601 format", "always use pager", "conforming", "nonstandard ports") {
		$names += $data =~ s/\Q$string\E\s+\(Greg\)/$string (Greg Sabino Mullane)/;
	}
	for my $string ("for large values)", "unnecessarily") {
		$names += $data =~ s/\Q$string\E\s+\(Greg([,\)])/$string (Greg Stark$1/;
	}

	## Fix all PostgreSQL to Postgres?! ;)

	## Important things to link to
	## Fails: $data =~ s{(pgcrypto)}{<a href="http://www.postgresql.org/docs/current/static/pgcrypto.html">$1</a>}g;

	while ($data =~ m{[\(,]([A-Z]\w+)[,\)]}g) {
		my $name = $1;
		next if $name =~ /^SQL|WARN|ERROR|MVCC|OID|NUL|ZONE|EPOCH|GEQO|WAL|WIN|Window|Alpha|Apple|BC|PITR|TIME|BUFFER|GBK|UHC/;
		next if $name =~ /^TM|PL|SSL|XID|V0|ANALYZE|CTE|CV|LRU|MAX|ORM|SJIS|CN|CSV|Czech|JOHAB|ISM|Also|BLOB/;
		next if $name =~ /^Taiwan|Mips|However|Japan|Ukrain|Venezuela/;
		next if $name eq 'MauMau' or $name eq 'Fiji' or $name eq 'ViSolve';
		next if $name eq 'Rumko' or $name eq 'Higepon';
		$fail{$name}++;
		$totalfail++;
	}

    my $fullversion = $version;

    if ($fullversion =~ /^\d+$/) {
        $fullversion = "$version.0";
    }
    my $eol = $version_is_eol{$version} ? qq{ <span class="eol"><a href="$EOLURL">(end of life)</a></span>} : '';
    print "<h2>Postgres version $fullversion$eol</h2>\n";
	print $data;

}

for my $short (sort keys %namesmatch) {
	next if $namesmatch{$short};
	print STDOUT "NO MATCH FOR SHORTNAME $short!\n";
	exit;
}

for (sort keys %fail) {
	print STDOUT "$_: $fail{$_}\n";
}
warn "Total name misses: $totalfail\n";


print STDOUT "Names changed: $names\n";

print "</body></html>\n";
select $oldselect;
close $fh;
print "Total pages loaded: $total\n";
print "Rewrote $bigpage\n";

sub fetch_page {

	my $page = shift or die "Need a page!\n";

	if (! -d $cachedir) {
		mkdir $cachedir, 0700;
	}

	(my $safename = $page) =~ s{/}{_}g;
	my $file = "$cachedir/$safename";

    my $skipcache = 0;
    if ($opt{nocache} or ($page =~ /release\.html/ and $opt{noindexcache})) {
        $skipcache = 1;
    }

	if (-e $file and ! $skipcache) {
        $verbose and print "Using cached file $file\n";
		open my $fh, '<', $file or die qq{Could not open "$file": $!\n};
		my $data; { local $/; $data = <$fh>; }
		close $fh;
		return $data;
	}

    $verbose and print "Fetching file $file\n";

	my $req = HTTP::Request->new(GET => $page);
	my $res = $ua->request($req);

	$res->is_success
		or die "FAILED to fetch $page: " . $res->status_line . "\n";

	open my $fh, '>', $file or die qq{Could not write "$file": $!\n};
	my $data = $res->content;
	print {$fh} $data;
	close $fh;
	return $data;

} ## end of fetch_page
