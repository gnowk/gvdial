#!/usr/bin/perl -w

use strict;
use Getopt::Long;
use LWP::UserAgent; 
use User::pwent;

################################################
# CONSTANTS
################################################
my $LOGIN_URL = 'https://www.google.com/accounts/ServiceLoginAuth?service=grandcentral';
my $VOICE_URL = 'https://www.google.com/voice/m';
my $CALL_URL  = 'https://www.google.com/voice/call/connect/';

my $pw = getpw($>);
my $HOME = $pw->dir;  # don't use $ENV{HOME}, since it doesn't get updated when su is used without -

my $COOKIES   = "$HOME/.gvdial-cookies";

################################################
# ARGUMENTS
################################################
my ($verbose, $rcfile);
GetOptions(
    'verbose' => \$verbose,
    "conf:s" => \$rcfile,
);

$rcfile ||= "$HOME/.gvdialrc";

################################################
# RC FILE
################################################
my %rc;
open(my $infile, $rcfile) || die "error opening $rcfile: $!";
while (<$infile>)
{  
    chomp;        
    s/\s+//g;
    my ($k, $v) = $_ =~ /([^=]+)=(.+)/; # can't use split, since some values can have '='
    $rc{lc($k)} = $v;
}
close($infile);

my %params = (
    'out_num'  => $ARGV[0],
    'from_num' => $ARGV[1] || $rc{from_num},
    'user'     => $rc{user},
    'pass'     => $rc{pass}, 
    'rnr_se'   => $rc{rnr_se}, 
);

################################################

usage() unless ($params{from_num} && $params{out_num} && -r $rcfile);

my ($ua, $resp, $cookies);

sub usage
{
    my ($script) = ($0 =~ /([^\/]+)$/);
    my $str = <<END;

Usage: $script [--conf config_file] [--verbose] out_num [from_num]

    --conf      specify path of the config file (default ~/.gvdialrc)
    --verbose   enable verbose output
    out_num     number to call
    from_num    number to ring back (optional if specified in the config file)

    sample config file
    ------------------
    user=user\@google.com
    pass=password
    from_num=17475551212

END

    die $str;
}

sub login
{
    print "logging in...\n" if $verbose;

    $ua->cookie_jar->clear();
    $resp = $ua->post($LOGIN_URL, [
        'Email'  => $params{user},
        'Passwd' => $params{pass}
    ]);
    $cookies = $ua->cookie_jar->as_string; 

    ### these cookies should now be set: SID (/), GAUSR (/accounts), LSID (/accounts) and CAL (/calendar)

    if ($resp->is_error)
    {
        warn "error connecting to the login url:\n" . 
            "code=" . $resp->code . "\n" .
            "header=" . $resp->headers->as_string . "\n" .
            "content=" . $resp->headers->as_string . "\n" if $verbose;
        exit 1;
    }

    ### non protocol errors can either be a redirect (3xx) or a success (2xx)
    if ($cookies !~ /SID=/)
    {
        warn "bad login or password\n" if $verbose;
        exit 1;
    }

    ### always fetch the voice url after login, accomplished by calling fetch_rnr_se
    my $rnr_se = fetch_rnr_se(); # gv cookie should now be set
    if (!$rnr_se)
    {
        warn "unable to fetch rnr_se\n" if $verbose;
        exit 1;
    }

    ### write out rnr_se to rcfile
    if (!$params{rnr_se})
    {
        $params{rnr_se} = $rnr_se;

        print "writing rnr_se out to rcfile\n" if $verbose;
        open(my $outfile, ">>$rcfile");
        print $outfile "rnr_se=$params{rnr_se}\n";
        close($outfile); 
    }
}

sub fetch_rnr_se
{
    print "fetching rnr_se\n" if $verbose;

    $resp = $ua->get($VOICE_URL);

    if (!$resp->is_success)
    {
        warn "error retrieving voice url\n" if $verbose;
        exit 1;
    }

    $resp->content =~ /name="_rnr_se" value="([^"]+)"/;
    return $1;
}

sub call
{
    my ($out, $from, $do_login) = @_;

    $do_login = 1 unless $params{rnr_se};

    login() if $do_login;

    ### TRANSLATE WORD LIKE NUMBERS
    if ($out =~ /[a-z]/i)
    {
        $out =  uc($out);
        $out =~ tr/ABCDEFGHIJKLMNOPQRSTUVWXYZ/22233344455566677778889999/;
    }

    print "calling $out from $from\n" if $verbose;

    $resp = $ua->post($CALL_URL,
        [
            '_rnr_se'          => $params{rnr_se},
            'forwardingNumber' => $from,
            'outgoingNumber'   => $out,
            'remember'         => 0,
            'subscriberNumber' => 'undefined',
        ],
        #'referer' => $VOICE_URL,
    );

    if ($resp->is_success && $resp->content =~ /"ok":true/)
    {
        exit 0; # success
    }

    # give it another go after login
    if (!$do_login)
    {
        print "retrying after logging in\n" if $verbose;
        call($out, $from, 1);
    }

    warn "call error: " . $resp->code . "\n" .
            $resp->headers->as_string . "\n" .
            $resp->content . "\n" if $verbose;
    exit 1;
}

#################################################################

$ua = LWP::UserAgent->new; 
$ua->cookie_jar({file => $COOKIES, autosave => 1, ignore_discard => 1}); 
$cookies = $ua->cookie_jar->as_string; 

### CALL
call($params{out_num}, $params{from_num}, ($cookies =~ /gv=/) ? 0 : 1);
