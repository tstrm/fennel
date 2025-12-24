#!perl

use strict;
use warnings;
use open ':std', ':encoding(UTF-8)';

use Win32::Console; 
my $objConsole = Win32::Console->new;
$objConsole->Title('Fennel Portfolio');

use LWP::UserAgent;
use JSON;
use Data::Dumper;

# Configuration
my $API_BASE = "https://api.fennel.com";
my $PAT_TOKEN = '';
# $ENV{'DEBUG'} = 1;

if (-e 'fennel.conf')
{
	open my $fhConf, '<', 'fennel.conf';
	
	my $strConf = '';
	
	while (<$fhConf>)
	{
		$strConf .= $_;
	}
	
	close $fhConf;
	
	if ($strConf =~ /PAT_TOKEN=(.*?)$/)
	{
		$PAT_TOKEN = $1;
	}
}

if ($PAT_TOKEN eq '')
{
	print "Please visit https://dash.fennel.com/ and generate a new Personal Access Token. Enter it below to continue.\n";
	print "Personal Access Token (PAT): ";
	
	my $strInput = <STDIN>;
	
	chomp($strInput);
	
	$PAT_TOKEN = $strInput;
	
	open my $fhConf, '>', 'fennel.conf';
	
	print $fhConf "PAT_TOKEN=$strInput\n";

	close $fhConf;
}


# Initialize HTTP client
my $ua = LWP::UserAgent->new(
    timeout => 30,
    agent => 'Fennel-Perl-Client/1.0',
);

# Set up headers with authentication
my %headers = (
    'Authorization' => "Bearer $PAT_TOKEN",
    'Content-Type' => 'application/json',
    'Accept' => 'application/json',
);

sub api_request {
    my ($method, $endpoint, $data) = @_;
    
    my $url = "$API_BASE$endpoint";
    print "DEBUG: Making $method request to: $url\n" if $ENV{'DEBUG'};
    
    my $request;
    
    if ($method eq 'GET') {
        $request = HTTP::Request->new(GET => $url);
    } elsif ($method eq 'POST') {
        $request = HTTP::Request->new(POST => $url);
        if ($data) {
            my $json_data = encode_json($data);
            print "DEBUG: Request body: $json_data\n" if $ENV{'DEBUG'};
            $request->content($json_data);
        }
    }
    
    # Add headers
    foreach my $key (keys %headers) {
        $request->header($key => $headers{$key});
    }
    
    my $response = $ua->request($request);
    
    print "DEBUG: Response status: " . $response->status_line . "\n" if $ENV{'DEBUG'};
    print "DEBUG: Response body: " . $response->content . "\n" if $ENV{'DEBUG'};
    
    if ($response->is_success) {
        return decode_json($response->content);
    } else {
        die "API Error: " . $response->status_line . "\n" . $response->content . "\n";
    }
}

sub get_account_info {
    print "Fetching account information...\n";
    my $result = api_request('GET', '/accounts/info');
    return $result;
}

sub get_portfolio_positions {
    my ($account_id) = @_;
    print "Fetching positions for account: $account_id\n" if $ENV{'DEBUG'};
    # Note: This is a POST request with account_id in the body
    my $positions = api_request('POST', '/portfolio/positions', { account_id => $account_id });
    return $positions;
}

sub get_portfolio_summary {
    my ($account_id) = @_;
    print "Fetching portfolio summary for account: $account_id\n" if $ENV{'DEBUG'};
    # Note: This is a POST request with account_id in the body
    my $summary = api_request('POST', '/portfolio/summary', { account_id => $account_id });
    return $summary;
}

sub format_currency {
    my ($amount) = @_;
    return sprintf("\$%.2f", $amount || 0);
}

sub format_percentage {
    my ($value) = @_;
    return sprintf("%.2f%%", ($value || 0) * 100);
}

sub get_account_type_name {
    my ($type_code) = @_;
    return 'N/A' unless defined $type_code;
    # From OpenAPI spec: CASH (0), IRA_TRADITIONAL (1), IRA_ROTH (2)
    my %types = (
        0 => 'Cash Account',
        1 => 'Traditional IRA',
        2 => 'Roth IRA',
    );
    return $types{$type_code} || "Unknown ($type_code)";
}

# Main execution
print "=" x 70 . "\n";
print "Fennel Holdings Report\n";
print "=" x 70 . "\n\n";

# Get all accounts
my $accounts_data = get_account_info();

# Extract accounts array
my $accounts = $accounts_data->{accounts};

unless (ref($accounts) eq 'ARRAY' && @$accounts > 0) {
    print "No accounts found.\n";
    exit 0;
}

print "Found " . scalar(@$accounts) . " account(s)\n\n";

# Process each account
foreach my $account (@$accounts) {
    my $account_id = $account->{id};
    my $account_name = $account->{name} || 'Unknown Account';
    my $account_type = get_account_type_name($account->{account_type});
    
    unless ($account_id) {
        print "Warning: Account without ID found, skipping...\n";
        next;
    }
    
    print "\n" . "=" x 70 . "\n";
    print "Account: $account_name\n";
    print "Type: $account_type\n";
    print "Account ID: $account_id\n";
    print "=" x 70 . "\n";
    
    # Get portfolio summary
    eval {
        my $summary = get_portfolio_summary($account_id);
        
        if ($summary) {
            print "\nPortfolio Summary:\n";
            print "-" x 70 . "\n";
            
            # API returns camelCase field names
            my $portfolio_value = $summary->{portfolioValue} || $summary->{portfolio_value} || 0;
            my $cash_available = $summary->{cashAvailable} || $summary->{cash_available} || 0;
            my $buying_power = $summary->{buyingPower} || $summary->{buying_power} || 0;
            
            print "  Portfolio Value:  " . format_currency($portfolio_value) . "\n";
            print "  Cash Available:   " . format_currency($cash_available) . "\n";
            print "  Buying Power:     " . format_currency($buying_power) . "\n";
        }
    };
    if ($@) {
        print "\nCould not fetch portfolio summary: $@" if $ENV{'DEBUG'};
    }
    
    # Get positions
    eval {
        my $positions_data = get_portfolio_positions($account_id);
        
        # Extract positions array from response
        my $positions = $positions_data->{positions};
        
        if (ref($positions) eq 'ARRAY' && @$positions > 0) {
            print "\nHoldings:\n";
            print "-" x 70 . "\n";
            print sprintf("  %-10s %12s %15s\n", 
                         "Symbol", "Shares", "Market Value");
            print "  " . "-" x 68 . "\n";
            
            my $total_value = 0;
            
            foreach my $position (@$positions) {
                my $symbol = $position->{symbol} || 'N/A';
                my $shares = $position->{shares} || 0;
                my $value = $position->{value} || 0;
                
                $total_value += $value;
                
                print sprintf("  %-10s %12.4f %15s\n",
                             $symbol,
                             $shares,
                             format_currency($value));
            }
            
            print "  " . "-" x 68 . "\n";
            print sprintf("  %-10s %12s %15s\n",
                         "TOTAL",
                         "",
                         format_currency($total_value));
            
        } elsif (ref($positions) eq 'ARRAY') {
            print "\nNo positions found in this account.\n";
        } else {
            print "\nUnexpected response format for positions.\n" if $ENV{'DEBUG'};
        }
    };
    if ($@) {
        print "\nError fetching positions: $@";
    }
}

print "\n" . "=" x 70 . "\n";
print "Report completed\n";
print "=" x 70 . "\n";