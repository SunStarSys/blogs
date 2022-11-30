#!/usr/local/bin/perl -T -I/x1/cms/build/lib
use utf8;
use strict;
use warnings;
use base 'sealed';
use Text::Balanced ();
use Apache2::RequestRec;
use Apache2::RequestUtil;
use Apache2::RequestIO;
use Apache2::SubRequest;
use HTML::Escape qw/escape_html/;
use HTML::Parser;
use APR::Request::Apache2;
use APR::Request::Param;
use APR::Request qw/encode/;

use Dotiac::DTL qw/Template *TEMPLATE_DIRS/;
use Dotiac::DTL::Addon::markup;
use SunStarSys::Util qw/read_text_file/;
use SunStarSys::SVNUtil;
use File::Basename;
use List::Util qw/sum/;

my Apache2::RequestRec $r = shift;
my APR::Request::Apache2 $apreq_class = "APR::Request::Apache2";
my APR::Request $apreq = $apreq_class->handle($r);

local our $USERNAME = $r->user;
local our $PASSWORD = ($r->get_basic_auth_pw)[1] if $r->user;

sub parser :Sealed {
  my @text;
  my (undef, $dirname, undef, $paths) = (@_, {});
  my HTML::Parser $p = "HTML::Parser";
  $p = $p->new(
    api_version => 3,
    handlers => {
      text => [\@text, '@{text}'],
    }
  );

  for my $pffxg ($_[0]) {
    while ($pffxg =~ m{^([^:]+):([^:]+):(.+)$}mg) {
      my ($file, $line, $match) = ($1, $2, $3);
      s!\x1b\[[\d;]*m!!g, s!\x1b\[[Km]!!g for $file, $line;
      my $count = 0;
      $match =~ s{(.*?)(?:\x1b\[01;31m(.+?)\x1b\[[Km]|$)}{
        my ($pre, $m) = ($1, $2 // "");
        ++$count if $m;
        my ($first, $last) = ("") x 2;
        $last = escape_html($1) if $pre =~ /([\s<\/]+)$/;
        s!\x1b\[[\d;]*m!!g, s!\x1b\[[Km]!!g, s!\{[\{%][^[\}%]+[\}%]\}!!g for $pre, $m;
        my @words;
        $p->parse($pre), $p->eof;
        push @words, split /\s+/, shift @text while @text;
        if ($m) {
          if (@words < 5) {
            unshift @words , "" until @words > 5;
          }
          else {
            @words = ("...", @words[-4 .. -1]);
          }
          $pre = join " ", grep {length} @words[-5 .. -1];
        } else {
          my $extra = @words > 5 ? "..." : undef;
          $pre = join " ", grep {defined} @words[0 .. 4], $extra if length $pre;
        }
        @words = ();
        $p->parse($m), $p->eof;
        push @words, split /\s+/, shift @text while @text;
        $m = qq(<span class="text-danger">) . join(" ", grep {defined} @words[0 .. 4]) . q(</span>);
        $pre . $last . $m
      }ge;
      push @{$$paths{$file}}, {count => $count, match => $match};
    }
  }
};

sub run_shell_command {
    my ($cmd, $args, @filenames) = @_;
    $args = [ @$args ];
    local %ENV = (
        PATH => "/usr/local/bin:/usr/bin",
        HOME => "/x1/home/joe",
        LANG => "en_US.UTF-8",
    );
    no warnings 'uninitialized';
    for (@filenames, @$args) {
      s/[^[:print:]]+//g;
      s/'/'\\''/g;
      "'$_'" =~ /^(.*)$/ms and $_ = $1
        or die "Can't detaint '$_'\n";
    }
    unshift @filenames, "--" if grep /^-/, @filenames;
    my @rv = qx($cmd @$args @filenames 2>&1);
    utf8::decode($_) for @rv;
    return wantarray ? @rv : join "", @rv;
}

sub breadcrumbs {
    my @path = split m!/!, shift, -1;
    my $tail = pop @path;
    my @rv;
    my $relpath = "../" x @path;
    push @path, $tail if length $tail;
    my $regex  = @_ ? encode(shift) : "";
    my $lang = @_ ? shift : "en";
    my $markdown = shift;
    $tail = pop @path;
    for (@path) {
        $relpath =~ s!\.?\./$!!;
        $relpath ||= './';
        push @rv, qq(<a href="$relpath?regex=$regex;lang=$lang;markdown=$markdown">) . (escape_html("\u$_") || "Home") . q(</a>);
      }
    return join "&nbsp;&raquo;&nbsp;", @rv, escape_html("\u$tail") || "Home";
}

my $markdown  = $apreq->args("markdown") ? "Markdown" : "";
my $lang     = encode($apreq->args("lang") || ".en");
my $re       = $apreq->args("regex") || return 400;
my $host = $r->headers_in->{host};

utf8::decode($re);

my $dirname;

if ($markdown) {
  $dirname = (</x1/cms/wcbuild/*/$host/trunk/content>)[0] . $r->path_info;
}
else {
  $dirname = "/x1/httpd/websites/$host/content" . $r->path_info;
}

my $d = $dirname;
for ($d) {
  s/'/'\\''/g;
  "'$_'" =~ /^(.*)$/ms and $_ = $1
    or die "Can't detaint '$_'\n";
}

 $re =~ s/\s+/|/g unless index($re, "|") >= 0 or index($re, '"') >= 0 or index($re, "\\") >= 0;
my $wflag = ($re =~ s/(?:"|\\[Q])([^"]+?)(?:"|\\[E])/\\Q$1\\E/g) ? "" : "-w";


my $pffxg = run_shell_command "cd $d && timeout 5 pffxg.sh" => [qw/--no-exclusions --no-cache --html --markdown --/, qw/-P -e/], $re;

if ($?) {
  $? == 124 and sleep 60;
  return 400;
}

parser $pffxg, $dirname, undef, \ my %matches;

my @matches;
my %title_cache;

while (my ($k, $v) = each %matches) {
  my $link = $r->path_info . $k;
  $link =~ s/\.md(?:text)?/.html/ if $markdown;
  if ($markdown) {
    eval {
      local $ENV{SOURCE_BASE} = $dirname;
      SunStarSys::SVNUtil->svn_can_read("$dirname$k");
    };
    next if $@;
  }
  else {
    my $subr = $r->lookup_file("$dirname$k");
    index($subr->status, "4") == 0 and next;
  }
  read_text_file "$dirname$k", \ my %data, $markdown ? 0 : undef;
  my ($title) = $data{headers}{title} // $data{content} =~ m/<h1>(.*?)<\/h1>/;
  my $total = sum map $_->{count}, @$v;
  push @matches, [$data{mtime}, $total, qq(<a href="$link">$title</a>), [map $_->{match}, @$v]]
    unless $title_cache{$title}++;
}

@matches = grep {shift(@$_),shift(@$_)} sort {$b->[1] <=> $a->[1] || $b->[0] <=> $a->[0]} @matches;

my %title = (
  ".en" => "Search Results for $markdown ",
  ".es" => "resultados de búsqued para \l$markdown ",
  ".de" => "Suchergebnisse für $markdown ",
  ".fr" => "Résultats de recherche pour \l$markdown ",
);

local @TEMPLATE_DIRS = map /(.*)/, </x1/cms/wcbuild/*/$host/trunk/templates>;
$r->print(Template("search.html")->render({
  path        => $r->path_info ne "/" ? $r->path_info . "placeholder" : "",
  title       => $title{$lang},
  markdown    => !!$markdown,
  matches     => \@matches,
  lang        => $lang,
  regex       => $re,
  breadcrumbs => breadcrumbs($r->path_info, $re, $lang, $markdown),
}));

return 0;
