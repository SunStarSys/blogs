#!/usr/local/bin/perl -T -I/x1/cms/build/lib
use Apache2::RequestRec;
use Apache2::RequestUtil;
use Apache2::RequestIO;
use APR::Request::Apache2;
use Dotiac::DTL qw/Template *TEMPLATE_DIRS/;
use Dotiac::DTL::Addon::markup;

use strict;
use warnings;

my $DOMAIN = q/sunstarsys.com/;
my $to          = q/sales@sunstarsys.com/;
my $date       = gmtime;

my $r = Apache2::RequestUtil->request;

sub render {
    my $template = shift;
    my $r = shift;
    my $body      = APR::Request::Apache2->handle($r)->body // {};
    my %args      = (%$body, @_);
    local our @TEMPLATE_DIRS = qw(/x1/cms/wcbuild/public/www.sunstarsys.com/trunk/templates);
    $r->content_type("text/html; charset='utf-8'");
    $r->print(Template($template)->render(\%args));
    exit 0;
}

if ($r->method eq "POST") {
    my $body = APR::Request::Apache2->handle($r)->body;
    my ($name, $email, $subject, $content, $site, $hosting, $plang) = @{$body}{qw/name email subject content site hosting plang/};
    s/\r//g for $name, $email, $subject, $content, $site, $hosting, $plang;
    s/\n//g for $name, $email, $subject, $hosting, $site, $plang;

    my ($cn, $srs_sender) = ($name, $email);

    for ($cn, $subject) {
        if (s/([^^A-Za-z0-9\-_.,!~*' ])/sprintf "=%02X", ord $1/ge) {
            tr/ /_/;
            $_ = "=?utf-8?Q?$_?=";
        }
    }

    s/^(.*)\@(.*)$/SRS0=999=99=$2=$1/, y/A-Za-z0-9._=-//dc for $srs_sender;
	$srs_sender =~ /(.*)/;
	length $1 or die "BAD EMAIL: $email";
    %ENV = ();
	open my $sendmail, "|-", "/usr/sbin/sendmail", qw/-t -oi -odq -f/, "$1\@$DOMAIN";
   	print $sendmail <<EOT;
To: $to
From: $cn <$srs_sender\@$DOMAIN>
Reply-To: $cn <$email>
Subject: $subject
Date: $date +0000
Content-Type: text/plain; charset="utf-8"

$content

WEBSITE: $site
HOSTING: $hosting
LANGUAGE: $plang
EOT

   	close $sendmail or die "sendmail failed: " . ($! || $? >> 8) . "\n";
    render "enquiry_post.html", $r,
        content => "## Thank You!\n\nOur Sales Team will get back to you shortly.\n",
        headers => { title => "CMS Sales Enquiry" };
}

render "enquiry_get.html", $r;
